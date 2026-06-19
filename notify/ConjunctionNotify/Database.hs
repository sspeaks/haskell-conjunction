{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | PostgreSQL access for @conjunction-notify@.
--
-- Reads the already-screened conjunctions (no SGP4 re-propagation: the TEME
-- state at TCA is read straight from the @conjunctions@ table, exactly as the
-- web client uses @conj.a.teme@) and owns a small de-duplication table so each
-- conjunction notifies at most once per watch label. The connection handling
-- mirrors "ConjunctionScreen.Database".
module ConjunctionNotify.Database
  ( withDatabase
  , runMigrations
  , loadStdMagMap
  , readWindowConjunctions
  , alreadyNotified
  , recordNotified
  ) where

import Brightness (StdMag, resolveStdMag)
import Conjunction.Visibility
  ( StoredConjunction (..)
  , StoredObject (..)
  )
import ConjunctionNotify.Config (Config (..), trimSecret)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , close
  , connectPostgreSQL
  , execute
  , execute_
  , query
  , query_
  )
import Database.PostgreSQL.Simple.FromRow (FromRow (fromRow), field)
import Linear.V3 (V3 (V3))

withDatabase :: Config -> (Connection -> IO a) -> IO a
withDatabase config action = do
  conninfo <- connectionInfo config
  bracket (connectPostgreSQL conninfo) close action

connectionInfo :: Config -> IO ByteString
connectionInfo Config {..} =
  case (cfgDatabaseUrlFile, cfgDatabaseUrl) of
    (Just path, _) -> BS8.pack . trimSecret <$> readFile path
    (Nothing, Just url) -> pure (BS8.pack url)
    (Nothing, Nothing) ->
      pure $
        BS8.pack $
          "host="
            <> cfgDatabaseHost
            <> " dbname="
            <> cfgDatabaseName
            <> " user="
            <> cfgDatabaseUser

-- | Create the de-duplication table if it does not already exist. The table is
-- standalone and inert: removing the feature later leaves it orphaned but
-- harmless.
runMigrations :: Connection -> IO ()
runMigrations conn = do
  _ <-
    execute_
      conn
      "CREATE TABLE IF NOT EXISTS conjunction_notifications (\
      \ id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\
      \ conjunction_id BIGINT NOT NULL,\
      \ watch TEXT NOT NULL,\
      \ sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),\
      \ CONSTRAINT conjunction_notifications_conj_watch_key UNIQUE (conjunction_id, watch)\
      \)"
  pure ()

-- | Build the standard-magnitude map the visibility math uses, derived exactly
-- as @Api.Database.listSatellites@ does (so server and browser magnitudes
-- agree). Objects absent from the map fall back to the predictor's default.
loadStdMagMap :: Connection -> IO (Map Int StdMag)
loadStdMagMap conn = do
  rows <-
    query_
      conn
      "SELECT lgp.norad_cat_id, lgp.object_type, ob.rcs_m2, ob.rcs_size\
      \ FROM leo_gp_current lgp\
      \ LEFT JOIN object_brightness ob ON ob.norad_cat_id = lgp.norad_cat_id\
      \ WHERE lgp.active = true AND lgp.tle_line1 IS NOT NULL AND lgp.tle_line2 IS NOT NULL" ::
      IO [(Int64, Maybe Text, Maybe Double, Maybe Text)]
  pure $
    Map.fromList
      [ (fromIntegral noradId, stdMag)
      | (noradId, objectType, rcsM2, rcsSize) <- rows
      , Just stdMag <- [resolveStdMag (fromIntegral noradId) objectType rcsM2 rcsSize]
      ]

-- | Conjunctions of the latest successful screening run whose time of closest
-- approach falls within @[windowStart, windowEnd]@, oldest first. Matches the
-- web client's @[now, now + windowHours]@ filter over the current run.
readWindowConjunctions :: Connection -> UTCTime -> UTCTime -> IO [StoredConjunction]
readWindowConjunctions conn windowStart windowEnd =
  map getWindowConjunction
    <$> query
      conn
      "SELECT conjunction_id, tca, miss_distance_km,\
      \ norad_cat_id_a, object_name_a, a_teme_x_km, a_teme_y_km, a_teme_z_km,\
      \ norad_cat_id_b, object_name_b, b_teme_x_km, b_teme_y_km, b_teme_z_km\
      \ FROM conjunctions\
      \ WHERE run_id = (SELECT max(run_id) FROM conjunction_runs WHERE status = 'success')\
      \ AND tca >= ? AND tca <= ?\
      \ ORDER BY tca ASC"
      (windowStart, windowEnd)

-- | True when this conjunction has already been notified under the watch label.
alreadyNotified :: Connection -> String -> Int64 -> IO Bool
alreadyNotified conn watch conjunctionId = do
  rows <-
    query
      conn
      "SELECT EXISTS (SELECT 1 FROM conjunction_notifications WHERE conjunction_id = ? AND watch = ?)"
      (conjunctionId, watch)
  case rows of
    (Only exists : _) -> pure exists
    [] -> pure False

-- | Record that a conjunction has been notified under the watch label.
-- Idempotent via the unique constraint.
recordNotified :: Connection -> String -> Int64 -> IO ()
recordNotified conn watch conjunctionId = do
  _ <-
    execute
      conn
      "INSERT INTO conjunction_notifications (conjunction_id, watch) VALUES (?, ?)\
      \ ON CONFLICT (conjunction_id, watch) DO NOTHING"
      (conjunctionId, watch)
  pure ()

-- | @FromRow@ wrapper so the visibility types stay free of a @postgresql-simple@
-- dependency (no orphan instance).
newtype WindowConjunction = WindowConjunction {getWindowConjunction :: StoredConjunction}

instance FromRow WindowConjunction where
  fromRow = do
    conjunctionId <- field
    tca <- field
    missDistanceKm <- field
    aNoradId <- field
    aName <- field
    aTemeX <- field
    aTemeY <- field
    aTemeZ <- field
    bNoradId <- field
    bName <- field
    bTemeX <- field
    bTemeY <- field
    bTemeZ <- field
    pure $
      WindowConjunction
        StoredConjunction
          { scId = conjunctionId
          , scTca = tca
          , scMissDistanceKm = missDistanceKm
          , scObjectA = StoredObject aNoradId aName (V3 aTemeX aTemeY aTemeZ)
          , scObjectB = StoredObject bNoradId bName (V3 bTemeX bTemeY bTemeZ)
          }

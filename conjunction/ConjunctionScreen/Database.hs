{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module ConjunctionScreen.Database
  ( withDatabase
  , runMigrations
  , readCatalog
  , hasComputedFor
  , insertRun
  , completeRun
  , insertEvents
  ) where

import ConjunctionScreen.Config (Config (..), trimSecret)
import Conjunction.Types
  ( ConjunctionEvent (..)
  , GeoPoint (..)
  , ObjectState (..)
  )
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import Data.Foldable (traverse_)
import Data.Int (Int64)
import qualified Data.Text as T
import Data.Time (Day)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , Query
  , close
  , connectPostgreSQL
  , execute
  , executeMany
  , execute_
  , query
  , query_
  )
import Database.PostgreSQL.Simple.ToField (toField)
import Database.PostgreSQL.Simple.ToRow (ToRow (toRow))
import SGP4 (TLE (..), Vec3 (..))

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

runMigrations :: Connection -> IO ()
runMigrations conn = do
  _ <- execute_ conn createConjunctionRuns
  _ <- execute_ conn createConjunctions
  traverse_ (execute_ conn) indexes
  _ <- execute_ conn dropOldConjunctionsPairUnique
  _ <- execute_ conn addConjunctionsRunPairTcaUnique
  pure ()

-- | Read every active catalog object that carries a usable TLE.
--
-- Objects that share an identical orbital state — the same mean motion,
-- eccentricity, inclination, RAAN, argument of perigee, and mean anomaly — are
-- collapsed to a single representative (the lowest NORAD id). Space-Track
-- catalogs the modules of an assembled structure and its docked visitors
-- separately (for example the ISS carries nine catalog entries: six modules plus
-- whatever Soyuz/Dragon/Progress is berthed), and copies one element set across
-- all of them. Screening them individually reports the structure conjuncting
-- with itself and reports every genuine close approach near it once per member.
-- Collapsing to one representative removes both artifacts while leaving the full
-- catalog untouched in the database.
readCatalog :: Connection -> IO [(Int, Maybe String, TLE)]
readCatalog conn = do
  rows <-
    query_
      conn
      "SELECT norad_cat_id, object_name, tle_line1, tle_line2 FROM (\
      \ SELECT DISTINCT ON\
      \ (mean_motion, eccentricity, inclination_deg, raan_deg, arg_of_pericenter_deg, mean_anomaly_deg)\
      \ norad_cat_id, object_name, tle_line1, tle_line2\
      \ FROM leo_gp_current\
      \ WHERE active = true AND tle_line1 IS NOT NULL AND tle_line2 IS NOT NULL\
      \ ORDER BY mean_motion, eccentricity, inclination_deg, raan_deg,\
      \ arg_of_pericenter_deg, mean_anomaly_deg, norad_cat_id ASC\
      \ ) collapsed\
      \ ORDER BY norad_cat_id ASC" ::
      IO [(Int, Maybe T.Text, T.Text, T.Text)]
  pure
    [ (nid, fmap T.unpack name, TLE (T.unpack line1) (T.unpack line2))
    | (nid, name, line1, line2) <- rows
    , not (T.null line1)
    , not (T.null line2)
    ]

-- | True when a successful screening run already exists for the given UTC date.
--
-- The date is supplied by the caller (derived from the window start) rather than
-- read from the server so the comparison is independent of the database
-- session time zone.
hasComputedFor :: Connection -> Day -> IO Bool
hasComputedFor conn screenDate = do
  tableRows <-
    ( query_
        conn
        "SELECT to_regclass('public.conjunction_runs')::text" ::
        IO [Only (Maybe String)]
      )
  case tableRows of
    [Only Nothing] -> pure False
    [Only (Just _)] -> successExists
    _ -> fail "failed to check conjunction_runs table presence"
 where
  successExists = do
    rows <-
      query
        conn
        "SELECT EXISTS (\
        \ SELECT 1 FROM conjunction_runs\
        \ WHERE status = 'success' AND screen_date = ?\
        \)"
        (Only screenDate)
    case rows of
      [Only exists] -> pure exists
      _ -> fail "failed to check for an existing screening run"

insertRun :: Connection -> Day -> String -> Double -> Double -> Double -> Double -> IO Int64
insertRun conn screenDate algorithm windowHours stepSeconds thresholdKm coarseThresholdKm = do
  rows <-
    query
      conn
      "INSERT INTO conjunction_runs\
      \ (screen_date, algorithm, status, window_hours, step_seconds, threshold_km, coarse_threshold_km)\
      \ VALUES (?, ?, 'running', ?, ?, ?, ?) RETURNING run_id"
      (screenDate, algorithm, windowHours, stepSeconds, thresholdKm, coarseThresholdKm)
  case rows of
    [Only runId] -> pure runId
    _ -> fail "failed to create conjunction run"

completeRun :: Connection -> Int64 -> String -> Int -> Int -> Maybe String -> IO ()
completeRun conn runId status objectCount conjunctionCount errorMessage = do
  _ <-
    execute
      conn
      "UPDATE conjunction_runs\
      \ SET finished_at = now(), status = ?, object_count = ?, conjunction_count = ?, error_message = ?\
      \ WHERE run_id = ?"
      (status, objectCount, conjunctionCount, errorMessage, runId)
  pure ()

insertEvents :: Connection -> Int64 -> Day -> [ConjunctionEvent] -> IO Int64
insertEvents _ _ _ [] = pure 0
insertEvents conn runId screenDate events =
  executeMany conn insertConjunction (map (DbEvent runId screenDate) events)

data DbEvent = DbEvent !Int64 !Day !ConjunctionEvent

instance ToRow DbEvent where
  toRow (DbEvent runId screenDate event) =
    [ toField runId
    , toField screenDate
    , toField (osNoradId objectA)
    , toField (osNoradId objectB)
    , toField (osName objectA)
    , toField (osName objectB)
    , toField (ceTca event)
    , toField (ceMissDistanceKm event)
    , toField (ceRelativeSpeedKms event)
    , toField (vecX (osPosTeme objectA))
    , toField (vecY (osPosTeme objectA))
    , toField (vecZ (osPosTeme objectA))
    , toField (vecX (osVelTeme objectA))
    , toField (vecY (osVelTeme objectA))
    , toField (vecZ (osVelTeme objectA))
    , toField (gpLatDeg (osGeo objectA))
    , toField (gpLonDeg (osGeo objectA))
    , toField (gpAltKm (osGeo objectA))
    , toField (vecX (osPosTeme objectB))
    , toField (vecY (osPosTeme objectB))
    , toField (vecZ (osPosTeme objectB))
    , toField (vecX (osVelTeme objectB))
    , toField (vecY (osVelTeme objectB))
    , toField (vecZ (osVelTeme objectB))
    , toField (gpLatDeg (osGeo objectB))
    , toField (gpLonDeg (osGeo objectB))
    , toField (gpAltKm (osGeo objectB))
    , toField (gpLatDeg (ceMidpoint event))
    , toField (gpLonDeg (ceMidpoint event))
    , toField (gpAltKm (ceMidpoint event))
    ]
   where
    objectA = ceObjectA event
    objectB = ceObjectB event

insertConjunction :: Query
insertConjunction =
  "INSERT INTO conjunctions (\
  \ run_id, screen_date, norad_cat_id_a, norad_cat_id_b, object_name_a, object_name_b,\
  \ tca, miss_distance_km, relative_speed_kms,\
  \ a_teme_x_km, a_teme_y_km, a_teme_z_km, a_vel_x_kms, a_vel_y_kms, a_vel_z_kms,\
  \ a_lat_deg, a_lon_deg, a_alt_km,\
  \ b_teme_x_km, b_teme_y_km, b_teme_z_km, b_vel_x_kms, b_vel_y_kms, b_vel_z_kms,\
  \ b_lat_deg, b_lon_deg, b_alt_km,\
  \ mid_lat_deg, mid_lon_deg, mid_alt_km\
  \) VALUES (\
  \ ?, ?, ?, ?, ?, ?,\
  \ ?, ?, ?,\
  \ ?, ?, ?, ?, ?, ?,\
  \ ?, ?, ?,\
  \ ?, ?, ?, ?, ?, ?,\
  \ ?, ?, ?,\
  \ ?, ?, ?\
  \) ON CONFLICT (run_id, norad_cat_id_a, norad_cat_id_b, tca) DO NOTHING"

createConjunctionRuns :: Query
createConjunctionRuns =
  "CREATE TABLE IF NOT EXISTS conjunction_runs (\
  \ run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\
  \ screen_date DATE NOT NULL,\
  \ algorithm TEXT NOT NULL,\
  \ started_at TIMESTAMPTZ NOT NULL DEFAULT now(),\
  \ finished_at TIMESTAMPTZ,\
  \ status TEXT NOT NULL CHECK (status IN ('running', 'success', 'failed')),\
  \ window_hours DOUBLE PRECISION NOT NULL,\
  \ step_seconds DOUBLE PRECISION NOT NULL,\
  \ threshold_km DOUBLE PRECISION NOT NULL,\
  \ coarse_threshold_km DOUBLE PRECISION NOT NULL,\
  \ object_count INTEGER,\
  \ conjunction_count INTEGER,\
  \ error_message TEXT\
  \)"

createConjunctions :: Query
createConjunctions =
  "CREATE TABLE IF NOT EXISTS conjunctions (\
  \ conjunction_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\
  \ run_id BIGINT NOT NULL REFERENCES conjunction_runs(run_id),\
  \ screen_date DATE NOT NULL,\
  \ norad_cat_id_a BIGINT NOT NULL,\
  \ norad_cat_id_b BIGINT NOT NULL,\
  \ object_name_a TEXT,\
  \ object_name_b TEXT,\
  \ tca TIMESTAMPTZ NOT NULL,\
  \ miss_distance_km DOUBLE PRECISION NOT NULL,\
  \ relative_speed_kms DOUBLE PRECISION NOT NULL,\
  \ a_teme_x_km DOUBLE PRECISION NOT NULL,\
  \ a_teme_y_km DOUBLE PRECISION NOT NULL,\
  \ a_teme_z_km DOUBLE PRECISION NOT NULL,\
  \ a_vel_x_kms DOUBLE PRECISION NOT NULL,\
  \ a_vel_y_kms DOUBLE PRECISION NOT NULL,\
  \ a_vel_z_kms DOUBLE PRECISION NOT NULL,\
  \ a_lat_deg DOUBLE PRECISION NOT NULL,\
  \ a_lon_deg DOUBLE PRECISION NOT NULL,\
  \ a_alt_km DOUBLE PRECISION NOT NULL,\
  \ b_teme_x_km DOUBLE PRECISION NOT NULL,\
  \ b_teme_y_km DOUBLE PRECISION NOT NULL,\
  \ b_teme_z_km DOUBLE PRECISION NOT NULL,\
  \ b_vel_x_kms DOUBLE PRECISION NOT NULL,\
  \ b_vel_y_kms DOUBLE PRECISION NOT NULL,\
  \ b_vel_z_kms DOUBLE PRECISION NOT NULL,\
  \ b_lat_deg DOUBLE PRECISION NOT NULL,\
  \ b_lon_deg DOUBLE PRECISION NOT NULL,\
  \ b_alt_km DOUBLE PRECISION NOT NULL,\
  \ mid_lat_deg DOUBLE PRECISION NOT NULL,\
  \ mid_lon_deg DOUBLE PRECISION NOT NULL,\
  \ mid_alt_km DOUBLE PRECISION NOT NULL,\
  \ created_at TIMESTAMPTZ NOT NULL DEFAULT now(),\
  \ CONSTRAINT conjunctions_run_pair_tca_key UNIQUE (run_id, norad_cat_id_a, norad_cat_id_b, tca)\
  \)"

dropOldConjunctionsPairUnique :: Query
dropOldConjunctionsPairUnique =
  "ALTER TABLE conjunctions DROP CONSTRAINT IF EXISTS conjunctions_run_id_norad_cat_id_a_norad_cat_id_b_key"

addConjunctionsRunPairTcaUnique :: Query
addConjunctionsRunPairTcaUnique =
  "DO $$\
  \ BEGIN\
  \   IF NOT EXISTS (\
  \     SELECT 1\
  \     FROM pg_constraint\
  \     WHERE conrelid = 'conjunctions'::regclass\
  \       AND conname = 'conjunctions_run_pair_tca_key'\
  \   ) THEN\
  \     ALTER TABLE conjunctions\
  \       ADD CONSTRAINT conjunctions_run_pair_tca_key\
  \       UNIQUE (run_id, norad_cat_id_a, norad_cat_id_b, tca);\
  \   END IF;\
  \ END\
  \ $$;"

indexes :: [Query]
indexes =
  [ "CREATE INDEX IF NOT EXISTS idx_conjunctions_screen_date ON conjunctions (screen_date)"
  , "CREATE INDEX IF NOT EXISTS idx_conjunctions_run ON conjunctions (run_id)"
  , "CREATE INDEX IF NOT EXISTS idx_conjunctions_norad_a ON conjunctions (norad_cat_id_a)"
  , "CREATE INDEX IF NOT EXISTS idx_conjunctions_norad_b ON conjunctions (norad_cat_id_b)"
  , "CREATE INDEX IF NOT EXISTS idx_conjunctions_miss ON conjunctions (miss_distance_km)"
  , "CREATE INDEX IF NOT EXISTS idx_conjunction_runs_screen_date ON conjunction_runs (screen_date DESC)"
  ]

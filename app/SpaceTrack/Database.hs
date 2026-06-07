{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module SpaceTrack.Database
  ( completeRun
  , deactivateMissing
  , insertRun
  , runMigrations
  , upsertGpRecord
  , withDatabase
  ) where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , Query
  , close
  , connectPostgreSQL
  , execute
  , execute_
  , query
  )
import Database.PostgreSQL.Simple.ToField (Action, ToField (toField))
import Database.PostgreSQL.Simple.ToRow (ToRow (toRow))
import SpaceTrack.Config (Config (..), trimSecret)
import SpaceTrack.Types (GpRecord (..), JsonValue (..))

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
  _ <- execute_ conn createIngestionRuns
  _ <- execute_ conn createCurrentTable
  traverse_ (execute_ conn) indexes

insertRun :: Connection -> String -> IO Int64
insertRun conn queryUrl = do
  rows <-
    query
      conn
      "INSERT INTO ingestion_runs (query_url, status) VALUES (?, 'running') RETURNING run_id"
      (Only queryUrl)
  case rows of
    [Only runId] -> pure runId
    _ -> fail "failed to create ingestion run"

completeRun ::
  Connection ->
  Int64 ->
  String ->
  Int ->
  Int64 ->
  Int64 ->
  Maybe String ->
  IO ()
completeRun conn runId status fetched changed deactivated errorMessage =
  do
    _ <-
      execute
        conn
        "UPDATE ingestion_runs SET finished_at = now(), status = ?, records_fetched = ?, records_changed = ?, records_deactivated = ?, error_message = ? WHERE run_id = ?"
        (status, fetched, changed, deactivated, errorMessage, runId)
    pure ()

upsertGpRecord :: Connection -> Int64 -> GpRecord -> IO Int64
upsertGpRecord conn runId record =
  execute conn upsertCurrent (DbGpRecord runId record)

deactivateMissing :: Connection -> Int64 -> IO Int64
deactivateMissing conn runId =
  execute
    conn
    "UPDATE leo_gp_current SET active = false, inactive_reason = 'absent from successful refresh', updated_at = now() WHERE active = true AND last_seen_run_id IS DISTINCT FROM ?"
    (Only runId)

data DbGpRecord = DbGpRecord
  { dbRunId :: !Int64
  , dbRecord :: !GpRecord
  }

instance ToRow DbGpRecord where
  toRow DbGpRecord {dbRunId, dbRecord = GpRecord {..}} =
    [ toField gpNoradCatId
    , toField gpGpId
    , toField gpObjectName
    , toField gpObjectId
    , toField gpObjectType
    , toField gpClassificationType
    , toField gpEpoch
    , toField gpCreationDate
    , toField gpMeanMotion
    , toField gpEccentricity
    , toField gpInclinationDeg
    , toField gpRaanDeg
    , toField gpArgOfPericenterDeg
    , toField gpMeanAnomalyDeg
    , toField gpBstar
    , toField gpSemimajorAxisKm
    , toField gpPeriodMin
    , toField gpApoapsisKm
    , toField gpPeriapsisKm
    , toField gpDecayDate
    , toField gpTleLine0
    , toField gpTleLine1
    , toField gpTleLine2
    , jsonField gpRawJson
    , toField dbRunId
    ]

jsonField :: JsonValue -> Action
jsonField (JsonValue value) = toField (LBS.toStrict value)

upsertCurrent :: Query
upsertCurrent =
  "INSERT INTO leo_gp_current (\
  \ norad_cat_id, gp_id, object_name, object_id, object_type, classification_type,\
  \ epoch, creation_date, mean_motion, eccentricity, inclination_deg, raan_deg,\
  \ arg_of_pericenter_deg, mean_anomaly_deg, bstar, semimajor_axis_km, period_min,\
  \ apoapsis_km, periapsis_km, decay_date, tle_line0, tle_line1, tle_line2,\
  \ raw_gp_json, active, inactive_reason, last_seen_run_id, updated_at\
  \) VALUES (\
  \ ?, ?, ?, ?, ?, ?,\
  \ ?, ?, ?, ?, ?, ?,\
  \ ?, ?, ?, ?, ?,\
  \ ?, ?, ?, ?, ?, ?,\
  \ ?::jsonb, true, NULL, ?, now()\
  \) ON CONFLICT (norad_cat_id) DO UPDATE SET\
  \ gp_id = EXCLUDED.gp_id,\
  \ object_name = EXCLUDED.object_name,\
  \ object_id = EXCLUDED.object_id,\
  \ object_type = EXCLUDED.object_type,\
  \ classification_type = EXCLUDED.classification_type,\
  \ epoch = EXCLUDED.epoch,\
  \ creation_date = EXCLUDED.creation_date,\
  \ mean_motion = EXCLUDED.mean_motion,\
  \ eccentricity = EXCLUDED.eccentricity,\
  \ inclination_deg = EXCLUDED.inclination_deg,\
  \ raan_deg = EXCLUDED.raan_deg,\
  \ arg_of_pericenter_deg = EXCLUDED.arg_of_pericenter_deg,\
  \ mean_anomaly_deg = EXCLUDED.mean_anomaly_deg,\
  \ bstar = EXCLUDED.bstar,\
  \ semimajor_axis_km = EXCLUDED.semimajor_axis_km,\
  \ period_min = EXCLUDED.period_min,\
  \ apoapsis_km = EXCLUDED.apoapsis_km,\
  \ periapsis_km = EXCLUDED.periapsis_km,\
  \ decay_date = EXCLUDED.decay_date,\
  \ tle_line0 = EXCLUDED.tle_line0,\
  \ tle_line1 = EXCLUDED.tle_line1,\
  \ tle_line2 = EXCLUDED.tle_line2,\
  \ raw_gp_json = EXCLUDED.raw_gp_json,\
  \ active = true,\
  \ inactive_reason = NULL,\
  \ last_seen_run_id = EXCLUDED.last_seen_run_id,\
  \ updated_at = now()\
  \ WHERE EXCLUDED.periapsis_km < 2000.0\
  \ AND EXCLUDED.decay_date IS NULL\
  \ AND EXCLUDED.epoch >= leo_gp_current.epoch"

createIngestionRuns :: Query
createIngestionRuns =
  "CREATE TABLE IF NOT EXISTS ingestion_runs (\
  \ run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\
  \ source TEXT NOT NULL DEFAULT 'spacetrack',\
  \ query_url TEXT NOT NULL,\
  \ started_at TIMESTAMPTZ NOT NULL DEFAULT now(),\
  \ finished_at TIMESTAMPTZ,\
  \ status TEXT NOT NULL CHECK (status IN ('running', 'success', 'partial', 'failed')),\
  \ records_fetched INTEGER,\
  \ records_changed BIGINT,\
  \ records_deactivated BIGINT,\
  \ error_message TEXT\
  \)"

createCurrentTable :: Query
createCurrentTable =
  "CREATE TABLE IF NOT EXISTS leo_gp_current (\
  \ norad_cat_id BIGINT PRIMARY KEY,\
  \ gp_id BIGINT,\
  \ object_name TEXT,\
  \ object_id VARCHAR(15),\
  \ object_type VARCHAR(12),\
  \ classification_type CHAR(1) DEFAULT 'U',\
  \ epoch TIMESTAMPTZ NOT NULL,\
  \ creation_date TIMESTAMPTZ,\
  \ mean_motion DOUBLE PRECISION NOT NULL CHECK (mean_motion > 0),\
  \ eccentricity DOUBLE PRECISION NOT NULL CHECK (eccentricity >= 0 AND eccentricity < 1),\
  \ inclination_deg DOUBLE PRECISION NOT NULL CHECK (inclination_deg >= 0 AND inclination_deg <= 180),\
  \ raan_deg DOUBLE PRECISION,\
  \ arg_of_pericenter_deg DOUBLE PRECISION,\
  \ mean_anomaly_deg DOUBLE PRECISION,\
  \ bstar DOUBLE PRECISION,\
  \ semimajor_axis_km DOUBLE PRECISION,\
  \ period_min DOUBLE PRECISION,\
  \ apoapsis_km DOUBLE PRECISION,\
  \ periapsis_km DOUBLE PRECISION NOT NULL CHECK (periapsis_km < 2000.0),\
  \ decay_date DATE,\
  \ tle_line0 TEXT,\
  \ tle_line1 TEXT,\
  \ tle_line2 TEXT,\
  \ raw_gp_json JSONB NOT NULL,\
  \ active BOOLEAN NOT NULL DEFAULT true,\
  \ inactive_reason TEXT,\
  \ source TEXT NOT NULL DEFAULT 'spacetrack',\
  \ first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),\
  \ last_seen_run_id BIGINT REFERENCES ingestion_runs(run_id),\
  \ updated_at TIMESTAMPTZ NOT NULL DEFAULT now()\
  \)"

indexes :: [Query]
indexes =
  [ "CREATE INDEX IF NOT EXISTS idx_leo_gp_epoch_desc ON leo_gp_current (epoch DESC)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_creation_desc ON leo_gp_current (creation_date DESC)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_periapsis ON leo_gp_current (periapsis_km)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_apoapsis ON leo_gp_current (apoapsis_km)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_inclination ON leo_gp_current (inclination_deg)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_object_type ON leo_gp_current (object_type)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_active ON leo_gp_current (active)"
  , "CREATE INDEX IF NOT EXISTS idx_leo_gp_raw_json_gin ON leo_gp_current USING GIN (raw_gp_json)"
  , "CREATE INDEX IF NOT EXISTS idx_ingestion_runs_started ON ingestion_runs (started_at DESC)"
  ]

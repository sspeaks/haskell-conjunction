{-# LANGUAGE OverloadedStrings #-}

-- | PostgreSQL queries backing the @conjunction-api@ endpoints.
--
-- All functions are read-only. The column order of every @SELECT@ matches the
-- corresponding 'FromRow' instance in "Api.Types".
module Api.Database
  ( openConnection
  , listSatellites
  , listConjunctions
  , getConjunction
  , listRuns
  ) where

import Api.Config (Config, connectionString)
import Api.Types (ConjunctionRow, RunRow, SatelliteRow)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Time (Day)
import Database.PostgreSQL.Simple
  ( Connection
  , Only (Only)
  , Query
  , connectPostgreSQL
  , query
  , query_
  )

-- | Open a single PostgreSQL connection from the resolved configuration.
openConnection :: Config -> IO Connection
openConnection cfg = connectionString cfg >>= connectPostgreSQL

-- | Every active catalog object that carries a usable TLE, plus the parsed
-- orbital elements used by the analytics views.
listSatellites :: Connection -> IO [SatelliteRow]
listSatellites conn =
  query_
    conn
    "SELECT lgp.norad_cat_id, lgp.object_name, lgp.object_type, lgp.tle_line1, lgp.tle_line2,\
    \ lgp.inclination_deg, lgp.raan_deg, lgp.eccentricity, lgp.mean_motion, lgp.period_min,\
    \ lgp.apoapsis_km, lgp.periapsis_km, lgp.semimajor_axis_km, ob.rcs_m2, ob.rcs_size\
    \ FROM leo_gp_current lgp\
    \ LEFT JOIN object_brightness ob ON ob.norad_cat_id = lgp.norad_cat_id\
    \ WHERE lgp.active = true AND lgp.tle_line1 IS NOT NULL AND lgp.tle_line2 IS NOT NULL\
    \ ORDER BY lgp.norad_cat_id ASC"

-- | The column list shared by every conjunction query.
selectConjunctions :: Query
selectConjunctions =
  "SELECT conjunction_id, screen_date, run_id, norad_cat_id_a, norad_cat_id_b,\
  \ object_name_a, object_name_b, tca, miss_distance_km, relative_speed_kms,\
  \ a_teme_x_km, a_teme_y_km, a_teme_z_km, a_vel_x_kms, a_vel_y_kms, a_vel_z_kms,\
  \ a_lat_deg, a_lon_deg, a_alt_km,\
  \ b_teme_x_km, b_teme_y_km, b_teme_z_km, b_vel_x_kms, b_vel_y_kms, b_vel_z_kms,\
  \ b_lat_deg, b_lon_deg, b_alt_km,\
  \ mid_lat_deg, mid_lon_deg, mid_alt_km\
  \ FROM conjunctions"

-- | Conjunctions of the latest successful screening run, ordered by miss
-- distance (closest first), capped at @limit@. When a @screen_date@ is given,
-- scopes to the latest successful run for that date instead. Scoping to a single
-- run keeps each physical conjunction from appearing once per stored run.
listConjunctions :: Connection -> Maybe Day -> Int -> IO [ConjunctionRow]
listConjunctions conn Nothing lim =
  query
    conn
    ( selectConjunctions
        <> " WHERE run_id = (SELECT max(run_id) FROM conjunction_runs WHERE status = 'success')\
           \ ORDER BY miss_distance_km ASC LIMIT ?"
    )
    (Only lim)
listConjunctions conn (Just day) lim =
  query
    conn
    ( selectConjunctions
        <> " WHERE run_id = (SELECT max(run_id) FROM conjunction_runs WHERE status = 'success' AND screen_date = ?)\
           \ ORDER BY miss_distance_km ASC LIMIT ?"
    )
    (day, lim)

-- | A single conjunction by its primary key.
getConjunction :: Connection -> Int64 -> IO (Maybe ConjunctionRow)
getConjunction conn cid =
  listToMaybe
    <$> query conn (selectConjunctions <> " WHERE conjunction_id = ?") (Only cid)

-- | The most recent screening runs (newest first).
listRuns :: Connection -> Int -> IO [RunRow]
listRuns conn lim =
  query
    conn
    "SELECT run_id, screen_date, algorithm, started_at, finished_at, status,\
    \ window_hours, step_seconds, threshold_km, object_count, conjunction_count\
    \ FROM conjunction_runs\
    \ ORDER BY screen_date DESC, run_id DESC LIMIT ?"
    (Only lim)

{-# LANGUAGE OverloadedStrings #-}

-- | Wire types for the @conjunction-api@ server.
--
-- Each type has a 'FromRow' instance (to read PostgreSQL rows) and a 'ToJSON'
-- instance (the JSON shape sent to the CesiumJS frontend). Conjunction rows are
-- nested into @a@/@b@/@midpoint@ objects for a cleaner client model.
module Api.Types
  ( SatelliteRow (..)
  , ConjunctionRow (..)
  , RunRow (..)
  ) where

import Brightness (resolveStdMag)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (Day, UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)

-- --------------------------------------------------------------------------- --
-- Satellite catalog row (from @leo_gp_current@)                               --
-- --------------------------------------------------------------------------- --

data SatelliteRow = SatelliteRow
  { satNoradId :: !Int64
  , satName :: !(Maybe Text)
  , satObjectType :: !(Maybe Text)
  , satTleLine1 :: !Text
  , satTleLine2 :: !Text
  , satInclinationDeg :: !Double
  , satRaanDeg :: !(Maybe Double)
  , satEccentricity :: !Double
  , satMeanMotion :: !Double
  , satPeriodMin :: !(Maybe Double)
  , satApoapsisKm :: !(Maybe Double)
  , satPeriapsisKm :: !Double
  , satSemimajorAxisKm :: !(Maybe Double)
  , satRcsM2 :: !(Maybe Double)
  , satRcsSize :: !(Maybe Text)
  , satStdMag :: !(Maybe Double)
  }

instance FromRow SatelliteRow where
  fromRow = do
    satNoradId' <- field
    satName' <- field
    satObjectType' <- field
    satTleLine1' <- field
    satTleLine2' <- field
    satInclinationDeg' <- field
    satRaanDeg' <- field
    satEccentricity' <- field
    satMeanMotion' <- field
    satPeriodMin' <- field
    satApoapsisKm' <- field
    satPeriapsisKm' <- field
    satSemimajorAxisKm' <- field
    satRcsM2' <- field
    satRcsSize' <- field
    let satStdMag' = resolveStdMag (fromIntegral satNoradId') satObjectType' satRcsM2' satRcsSize'
    pure
      SatelliteRow
        { satNoradId = satNoradId'
        , satName = satName'
        , satObjectType = satObjectType'
        , satTleLine1 = satTleLine1'
        , satTleLine2 = satTleLine2'
        , satInclinationDeg = satInclinationDeg'
        , satRaanDeg = satRaanDeg'
        , satEccentricity = satEccentricity'
        , satMeanMotion = satMeanMotion'
        , satPeriodMin = satPeriodMin'
        , satApoapsisKm = satApoapsisKm'
        , satPeriapsisKm = satPeriapsisKm'
        , satSemimajorAxisKm = satSemimajorAxisKm'
        , satRcsM2 = satRcsM2'
        , satRcsSize = satRcsSize'
        , satStdMag = satStdMag'
        }

instance ToJSON SatelliteRow where
  toJSON s =
    object
      [ "noradId" .= satNoradId s
      , "name" .= satName s
      , "objectType" .= satObjectType s
      , "tle1" .= satTleLine1 s
      , "tle2" .= satTleLine2 s
      , "inclinationDeg" .= satInclinationDeg s
      , "raanDeg" .= satRaanDeg s
      , "eccentricity" .= satEccentricity s
      , "meanMotion" .= satMeanMotion s
      , "periodMin" .= satPeriodMin s
      , "apoapsisKm" .= satApoapsisKm s
      , "periapsisKm" .= satPeriapsisKm s
      , "semimajorAxisKm" .= satSemimajorAxisKm s
      , "rcsM2" .= satRcsM2 s
      , "rcsSize" .= satRcsSize s
      , "stdMag" .= satStdMag s
      ]

-- --------------------------------------------------------------------------- --
-- Conjunction event row (from @conjunctions@)                                 --
-- --------------------------------------------------------------------------- --

-- | Field order matches the @SELECT@ in "Api.Database" and the table DDL.
data ConjunctionRow = ConjunctionRow
  { cjId :: !Int64
  , cjScreenDate :: !Day
  , cjRunId :: !Int64
  , cjNoradA :: !Int64
  , cjNoradB :: !Int64
  , cjNameA :: !(Maybe Text)
  , cjNameB :: !(Maybe Text)
  , cjTca :: !UTCTime
  , cjMissKm :: !Double
  , cjRelSpeedKms :: !Double
  , cjATemeX :: !Double
  , cjATemeY :: !Double
  , cjATemeZ :: !Double
  , cjAVelX :: !Double
  , cjAVelY :: !Double
  , cjAVelZ :: !Double
  , cjALat :: !Double
  , cjALon :: !Double
  , cjAAlt :: !Double
  , cjBTemeX :: !Double
  , cjBTemeY :: !Double
  , cjBTemeZ :: !Double
  , cjBVelX :: !Double
  , cjBVelY :: !Double
  , cjBVelZ :: !Double
  , cjBLat :: !Double
  , cjBLon :: !Double
  , cjBAlt :: !Double
  , cjMidLat :: !Double
  , cjMidLon :: !Double
  , cjMidAlt :: !Double
  }

instance FromRow ConjunctionRow where
  fromRow =
    ConjunctionRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field -- norad_cat_id_b
      <*> field
      <*> field -- object_name_b
      <*> field -- tca
      <*> field
      <*> field -- relative_speed_kms
      <*> field
      <*> field
      <*> field -- a_teme_{x,y,z}
      <*> field
      <*> field
      <*> field -- a_vel_{x,y,z}
      <*> field
      <*> field
      <*> field -- a_{lat,lon,alt}
      <*> field
      <*> field
      <*> field -- b_teme_{x,y,z}
      <*> field
      <*> field
      <*> field -- b_vel_{x,y,z}
      <*> field
      <*> field
      <*> field -- b_{lat,lon,alt}
      <*> field
      <*> field
      <*> field -- mid_{lat,lon,alt}

-- | A single object's state at TCA as a nested JSON object.
objectStateJson
  :: Int64
  -> Maybe Text
  -> Double
  -> Double
  -> Double
  -> Double
  -> Double
  -> Double
  -> Double
  -> Double
  -> Double
  -> Value
objectStateJson nid name tx ty tz vx vy vz lat lon alt =
  object
    [ "noradId" .= nid
    , "name" .= name
    , "teme" .= object ["x" .= tx, "y" .= ty, "z" .= tz]
    , "vel" .= object ["x" .= vx, "y" .= vy, "z" .= vz]
    , "geo" .= object ["lat" .= lat, "lon" .= lon, "altKm" .= alt]
    ]

instance ToJSON ConjunctionRow where
  toJSON c =
    object
      [ "id" .= cjId c
      , "screenDate" .= cjScreenDate c
      , "runId" .= cjRunId c
      , "tca" .= cjTca c
      , "missDistanceKm" .= cjMissKm c
      , "relativeSpeedKms" .= cjRelSpeedKms c
      , "a"
          .= objectStateJson
            (cjNoradA c)
            (cjNameA c)
            (cjATemeX c)
            (cjATemeY c)
            (cjATemeZ c)
            (cjAVelX c)
            (cjAVelY c)
            (cjAVelZ c)
            (cjALat c)
            (cjALon c)
            (cjAAlt c)
      , "b"
          .= objectStateJson
            (cjNoradB c)
            (cjNameB c)
            (cjBTemeX c)
            (cjBTemeY c)
            (cjBTemeZ c)
            (cjBVelX c)
            (cjBVelY c)
            (cjBVelZ c)
            (cjBLat c)
            (cjBLon c)
            (cjBAlt c)
      , "midpoint" .= object ["lat" .= cjMidLat c, "lon" .= cjMidLon c, "altKm" .= cjMidAlt c]
      ]

-- --------------------------------------------------------------------------- --
-- Screening-run row (from @conjunction_runs@)                                 --
-- --------------------------------------------------------------------------- --

data RunRow = RunRow
  { rnRunId :: !Int64
  , rnScreenDate :: !Day
  , rnAlgorithm :: !Text
  , rnStartedAt :: !UTCTime
  , rnFinishedAt :: !(Maybe UTCTime)
  , rnStatus :: !Text
  , rnWindowHours :: !Double
  , rnStepSeconds :: !Double
  , rnThresholdKm :: !Double
  , rnObjectCount :: !(Maybe Int)
  , rnConjunctionCount :: !(Maybe Int)
  }

instance FromRow RunRow where
  fromRow =
    RunRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

instance ToJSON RunRow where
  toJSON r =
    object
      [ "runId" .= rnRunId r
      , "screenDate" .= rnScreenDate r
      , "algorithm" .= rnAlgorithm r
      , "startedAt" .= rnStartedAt r
      , "finishedAt" .= rnFinishedAt r
      , "status" .= rnStatus r
      , "windowHours" .= rnWindowHours r
      , "stepSeconds" .= rnStepSeconds r
      , "thresholdKm" .= rnThresholdKm r
      , "objectCount" .= rnObjectCount r
      , "conjunctionCount" .= rnConjunctionCount r
      ]

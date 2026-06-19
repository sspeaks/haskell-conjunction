-- | Core types shared by the conjunction-screening algorithms.
--
-- These types are propagator- and database-agnostic. The raw CM-COMBO screen
-- ('Conjunction.CMCombo') and the optimized spatial-hash screen
-- ('Conjunction.Grid') both consume the same catalog and configuration and
-- emit the same 'ConjunctionEvent' values, which lets the two algorithms be
-- validated against one another.
module Conjunction.Types
  ( ScreenConfig (..)
  , defaultScreenConfig
  , CatalogObject (..)
  , GeoPoint (..)
  , ObjectState (..)
  , ConjunctionEvent (..)
  ) where

import Data.Time (UTCTime)
import SGP4 (Satellite, Vec3)

-- | Parameters that fully determine a screening run.
--
-- The same configuration drives both algorithms, guaranteeing they sample the
-- same absolute-UTC time grid, share a candidate gate, and refine candidates
-- identically.
data ScreenConfig = ScreenConfig
  { scStart :: !UTCTime
  -- ^ Absolute UTC start of the screening window.
  , scWindowHours :: !Double
  -- ^ Screening horizon length in hours.
  , scStepSeconds :: !Double
  -- ^ Coarse sampling step in seconds.
  , scThresholdKm :: !Double
  -- ^ Final reported miss-distance threshold in kilometers.
  , scCoarseThresholdKm :: !(Maybe Double)
  -- ^ Candidate gate in kilometers. 'Nothing' derives it from the step and
  -- maximum relative velocity so no sub-threshold approach is skipped between
  -- samples.
  , scRelVelMaxKms :: !Double
  -- ^ Maximum relative velocity used to derive the coarse threshold.
  , scRefineStepSeconds :: !Double
  -- ^ Fine step used when refining a candidate's time of closest approach.
  , scTileHours :: !(Maybe Double)
  -- ^ Optional length, in hours, of the time tile screened at once. The window
  -- is processed in consecutive tiles of this many hours so only one tile's
  -- propagation table is resident at a time, bounding peak memory on large
  -- catalogs. 'Nothing' screens the whole window in a single tile (the original
  -- behavior). Tiling never changes the detected conjunctions: every coarse step
  -- is still screened exactly once and the global per-pair minimum is retained.
  , scMinRelativeSpeedKms :: !Double
  -- ^ Relative-speed floor in kilometers per second. Events whose relative speed
  -- at the time of closest approach is below this value are suppressed as
  -- co-orbital/co-located proximities, which share an orbit and so have no single
  -- physically meaningful time of closest approach. A floor of @0.0@ disables the
  -- filter (an exact no-op, since relative speed is always non-negative).
  }
  deriving (Eq, Show)

-- | A 24-hour, 60-second screen reporting approaches within 5 km.
--
-- The coarse threshold is derived, and the maximum relative velocity defaults
-- to a head-on low-Earth-orbit encounter (~2 * 7.8 km/s).
defaultScreenConfig :: UTCTime -> ScreenConfig
defaultScreenConfig start =
  ScreenConfig
    { scStart = start
    , scWindowHours = 24.0
    , scStepSeconds = 60.0
    , scThresholdKm = 5.0
    , scCoarseThresholdKm = Nothing
    , scRelVelMaxKms = 15.6
    , scRefineStepSeconds = 1.0
    , scTileHours = Nothing
    , scMinRelativeSpeedKms = 0.0
    }

-- | A catalog entry to be screened.
--
-- The satellite is an initialized SGP4 record; the name is carried through to
-- the emitted events for reporting.
data CatalogObject = CatalogObject
  { coNoradId :: !Int
  , coName :: !(Maybe String)
  , coSatellite :: !Satellite
  }

-- | A WGS84 geodetic point in degrees and kilometers.
data GeoPoint = GeoPoint
  { gpLatDeg :: !Double
  , gpLonDeg :: !Double
  , gpAltKm :: !Double
  }
  deriving (Eq, Show)

-- | One object's state at the time of closest approach.
data ObjectState = ObjectState
  { osNoradId :: !Int
  , osName :: !(Maybe String)
  , osPosTeme :: !Vec3
  -- ^ TEME position in kilometers.
  , osVelTeme :: !Vec3
  -- ^ TEME velocity in kilometers per second.
  , osGeo :: !GeoPoint
  -- ^ WGS84 geodetic position at the time of closest approach.
  }
  deriving (Eq, Show)

-- | A detected close approach between two cataloged objects.
--
-- Objects are stored in canonical order: 'osNoradId' of 'ceObjectA' is strictly
-- less than that of 'ceObjectB'.
data ConjunctionEvent = ConjunctionEvent
  { ceTca :: !UTCTime
  , ceMissDistanceKm :: !Double
  , ceRelativeSpeedKms :: !Double
  , ceObjectA :: !ObjectState
  , ceObjectB :: !ObjectState
  , ceMidpoint :: !GeoPoint
  -- ^ WGS84 geodetic position of the midpoint between the two objects at the
  -- time of closest approach.
  }
  deriving (Eq, Show)

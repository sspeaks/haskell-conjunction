-- | Time utilities for SGP4 workflows.
--
-- The public SGP4 propagator consumes minutes since the TLE epoch. This module
-- bridges ordinary Haskell 'UTCTime' values to that representation through a
-- split Julian Date, preserving the precision of Vallado's @jdsatepoch@ and
-- @jdsatepochF@ fields.
module SGP4.Time
  ( SplitJD (..)
  , splitJD
  , fromSingleJD
  , toSingleJD
  , diffDays
  , j2000
  , mjdEpoch
  , utcToSplitJD
  , splitJDToUTC
  , toMJD
  , fromMJD
  , JulianCenturies (..)
  , toJ2000Centuries
  , GMST (..)
  , gmst
  , mod2pi
  , MinutesSinceEpoch (..)
  , satelliteEpochSJD
  , utcToTsince
  , tsinceToUTC
  ) where

import Data.Time.Calendar (Day (ModifiedJulianDay), toModifiedJulianDay)
import Data.Time.Clock
  ( UTCTime (UTCTime)
  , diffTimeToPicoseconds
  , picosecondsToDiffTime
  )
import SGP4.TLE (satelliteEpoch)
import SGP4.Types (Satellite)

-- | Precision Julian Date represented as whole-day and fractional-day parts.
--
-- Keeping the parts split avoids losing sub-millisecond precision when working
-- with Julian dates near J2000.
data SplitJD = SplitJD
  { sjdWhole :: !Double
  , sjdFrac :: !Double
  }
  deriving (Eq, Show, Read)

splitJD :: Double -> Double -> SplitJD
splitJD whole frac =
  let offset = floor frac :: Integer
   in SplitJD (whole + fromIntegral offset) (frac - fromIntegral offset)

fromSingleJD :: Double -> SplitJD
fromSingleJD = splitJD 0.0

toSingleJD :: SplitJD -> Double
toSingleJD (SplitJD whole frac) = whole + frac

diffDays :: SplitJD -> SplitJD -> Double
diffDays (SplitJD wholeA fracA) (SplitJD wholeB fracB) =
  (wholeA - wholeB) + (fracA - fracB)

j2000 :: SplitJD
j2000 = SplitJD 2451545.0 0.0

mjdEpoch :: SplitJD
mjdEpoch = SplitJD 2400000.5 0.0

utcToSplitJD :: UTCTime -> SplitJD
utcToSplitJD (UTCTime day dayTime) =
  let mjd = fromIntegral (toModifiedJulianDay day)
      jd = mjd + 2400000.5
      frac = fromIntegral (diffTimeToPicoseconds dayTime) / picosecondsPerDayDouble
   in splitJD jd frac

splitJDToUTC :: SplitJD -> UTCTime
splitJDToUTC jd =
  let mjd = toMJD jd
      dayNumber = floor mjd :: Integer
      fracDay = mjd - fromIntegral dayNumber
      rawPicoseconds = round (fracDay * picosecondsPerDayDouble)
      (extraDays, dayPicoseconds) = rawPicoseconds `divMod` picosecondsPerDay
   in UTCTime
        (ModifiedJulianDay (dayNumber + extraDays))
        (picosecondsToDiffTime dayPicoseconds)

toMJD :: SplitJD -> Double
toMJD jd = diffDays jd mjdEpoch

fromMJD :: Double -> SplitJD
fromMJD = splitJD 2400000.5

-- | Julian centuries since J2000.0.
newtype JulianCenturies = JulianCenturies {getJulianCenturies :: Double}
  deriving (Eq, Ord, Show, Read)

toJ2000Centuries :: SplitJD -> JulianCenturies
toJ2000Centuries jd =
  JulianCenturies (diffDays jd j2000 / 36525.0)

-- | Greenwich Mean Sidereal Time in radians, normalized to @[0, 2*pi)@.
newtype GMST = GMST {getGMST :: Double}
  deriving (Eq, Ord, Show, Read)

-- | Vallado/IAU-1982 GMST.
--
-- This Tier 1 utility treats the input Julian date as UT1. Passing UTC directly
-- is common for TLE workflows, but introduces a fixed-frame longitude error
-- proportional to DUT1.
gmst :: SplitJD -> GMST
gmst jd =
  let JulianCenturies t = toJ2000Centuries jd
      thetaSeconds =
        67310.54841
          + (876600.0 * 3600.0 + 8640184.812866) * t
          + 0.093104 * t * t
          - 6.2e-6 * t * t * t
      thetaRadians = thetaSeconds * (pi / 180.0 / 240.0)
   in GMST (mod2pi thetaRadians)

mod2pi :: Double -> Double
mod2pi value =
  let tau = 2.0 * pi
      reduced = value - tau * fromIntegral (floor (value / tau) :: Integer)
   in if reduced < 0.0 then reduced + tau else reduced

-- | Minutes elapsed from the TLE epoch, the time unit expected by SGP4.
newtype MinutesSinceEpoch = MinutesSinceEpoch {getMinutes :: Double}
  deriving (Eq, Ord, Show, Read)

satelliteEpochSJD :: Satellite -> IO SplitJD
satelliteEpochSJD satellite = do
  (whole, frac) <- satelliteEpoch satellite
  pure (splitJD whole frac)

utcToTsince :: Satellite -> UTCTime -> IO MinutesSinceEpoch
utcToTsince satellite utc = do
  epoch <- satelliteEpochSJD satellite
  let target = utcToSplitJD utc
  pure (MinutesSinceEpoch (diffDays target epoch * 1440.0))

tsinceToUTC :: Satellite -> MinutesSinceEpoch -> IO UTCTime
tsinceToUTC satellite (MinutesSinceEpoch minutes) = do
  SplitJD whole frac <- satelliteEpochSJD satellite
  pure (splitJDToUTC (splitJD whole (frac + minutes / 1440.0)))

picosecondsPerDay :: Integer
picosecondsPerDay = 86400 * 1000000000000

picosecondsPerDayDouble :: Double
picosecondsPerDayDouble = fromIntegral picosecondsPerDay

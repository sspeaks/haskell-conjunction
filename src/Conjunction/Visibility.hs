{-# LANGUAGE RecordWildCards #-}

-- | Server-side port of the browser's conjunction visibility math.
--
-- This module mirrors the conjunction path of @web/src/cesium/visibility.ts@
-- and the low-precision Sun model in @web/src/cesium/solar.ts@ so the
-- @conjunction-notify@ executable makes the same naked-eye-visibility decision
-- the web "Visible conjunctions" list makes for a given observer location.
--
-- It deliberately reuses the library's GMST, TEME->ECEF, geodetic, and
-- topocentric transforms (the Haskell equivalents of satellite.js @gstime@,
-- @eciToEcf@, @geodeticToEcf@, and @ecfToLookAngles@) so frames, sidereal time,
-- and look angles agree with the browser. The only new astronomy is the
-- low-precision Vallado/Meeus Sun model ported from @solar.ts@.
module Conjunction.Visibility
  ( VisibilityParams (..)
  , defaultVisibilityParams
  , StoredObject (..)
  , StoredConjunction (..)
  , VisibleConjunction (..)
  , sunPositionTemeKm
  , sunElevationRad
  , isInEarthShadow
  , phaseAngleRad
  , apparentMagnitude
  , conjunctionVisibility
  ) where

import Brightness (StdMag)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Linear.Metric (dot, norm)
import Linear.V3 (V3 (V3))
import Linear.Vector (negated, (^-^), (^/))
import SGP4.Coordinate
  ( ECEFPosition (ECEFPosition)
  , ECEFVelocity (ECEFVelocity)
  , GeodeticPosition
  , Kilometers (getKilometers)
  , Radians (getRadians)
  , TEMEPosition (TEMEPosition)
  , TopocentricObservation (topoAzimuth, topoElevation, topoRange)
  )
import SGP4.Frames (geodeticToEcef, temeToEcef, topocentricObservation)
import SGP4.Time (JulianCenturies (JulianCenturies), gmst, toJ2000Centuries, utcToSplitJD)

-- | Thresholds defining "naked-eye visible" for an observer. Defaults match the
-- web store (@web/src/state/store.ts@) and @VisibilityOptions@
-- (@web/src/api/types.ts@) so server and browser agree.
data VisibilityParams = VisibilityParams
  { vpWindowHours :: !Double
  -- ^ Look-ahead horizon in hours (used by callers to bound the @tca@ query).
  , vpMinElevationDeg :: !Double
  -- ^ Minimum peak elevation above the horizon, in degrees.
  , vpSunMaxElevationDeg :: !Double
  -- ^ Observer is "dark" when the Sun is below this elevation, in degrees.
  , vpMagnitudeCutoff :: !Double
  -- ^ Faintest apparent magnitude still considered worth reporting.
  }
  deriving (Eq, Show)

-- | Defaults identical to the web visibility store.
defaultVisibilityParams :: VisibilityParams
defaultVisibilityParams =
  VisibilityParams
    { vpWindowHours = 24.0
    , vpMinElevationDeg = 10.0
    , vpSunMaxElevationDeg = -6.0
    , vpMagnitudeCutoff = 6.5
    }

-- | One object of a stored conjunction, with its TEME position at TCA in km.
data StoredObject = StoredObject
  { soNoradId :: !Int
  , soName :: !(Maybe Text)
  , soTeme :: !(V3 Double)
  }
  deriving (Eq, Show)

-- | A persisted conjunction as needed for the visibility decision. The TEME
-- positions are read directly from the @conjunctions@ table at TCA, exactly as
-- the browser uses @conj.a.teme@; no SGP4 re-propagation is required.
data StoredConjunction = StoredConjunction
  { scId :: !Int64
  , scTca :: !UTCTime
  , scMissDistanceKm :: !Double
  , scObjectA :: !StoredObject
  , scObjectB :: !StoredObject
  }
  deriving (Eq, Show)

-- | The result of a positive visibility evaluation, mirroring the web
-- @VisibleConjunction@ plus the higher object's azimuth for the alert message.
data VisibleConjunction = VisibleConjunction
  { vcId :: !Int64
  , vcTca :: !UTCTime
  , vcANoradId :: !Int
  , vcBNoradId :: !Int
  , vcAName :: !(Maybe Text)
  , vcBName :: !(Maybe Text)
  , vcMissDistanceKm :: !Double
  , vcPeakElevationDeg :: !Double
  , vcPeakAzimuthDeg :: !Double
  , vcPeakMagnitude :: !Double
  }
  deriving (Eq, Show)

earthRadiusKm :: Double
earthRadiusKm = 6371.0

auKm :: Double
auKm = 149597870.7

-- | Fallback standard magnitude, matching the web @sat.stdMag ?? 8.0@.
defaultStdMag :: StdMag
defaultStdMag = 8.0

infinity :: Double
infinity = 1.0 / 0.0

degToRad :: Double -> Double
degToRad d = d * pi / 180.0

radToDeg :: Double -> Double
radToDeg r = r * 180.0 / pi

-- | Normalize to @[0, 360)@ degrees, matching the web @((d % 360) + 360) % 360@.
mod360 :: Double -> Double
mod360 d = d - 360.0 * fromIntegral (floor (d / 360.0) :: Integer)

clampD :: Double -> Double -> Double -> Double
clampD lo hi x = max lo (min hi x)

normalizeV :: V3 Double -> V3 Double
normalizeV v =
  let n = norm v
   in if n > 0.0 then v ^/ n else V3 0.0 0.0 0.0

zeroEcefVelocity :: ECEFVelocity
zeroEcefVelocity = ECEFVelocity (V3 0.0 0.0 0.0)

-- | Low-precision Sun position in TEME (~ECI) kilometers.
--
-- A direct port of @sunEciKm@ (Vallado/Meeus, ~0.01 deg for 1950-2050). The
-- Julian-century term comes from the library time base
-- (@utcToSplitJD@ + @toJ2000Centuries@) so it matches the GMST used elsewhere.
sunPositionTemeKm :: UTCTime -> V3 Double
sunPositionTemeKm t =
  let JulianCenturies tc = toJ2000Centuries (utcToSplitJD t)
      lm = mod360 (280.460 + 36000.771 * tc)
      m = mod360 (357.5291092 + 35999.05034 * tc)
      mRad = degToRad m
      lam = lm + 1.914666471 * sin mRad + 0.019994643 * sin (2.0 * mRad)
      eps = 23.439291 - 0.0130042 * tc
      lamRad = degToRad lam
      epsRad = degToRad eps
      rAu = 1.000140612 - 0.016708617 * cos mRad - 0.000139589 * cos (2.0 * mRad)
   in V3
        (rAu * cos lamRad * auKm)
        (rAu * cos epsRad * sin lamRad * auKm)
        (rAu * sin epsRad * sin lamRad * auKm)

-- | Sun elevation at an observer in radians, positive above the horizon.
-- Port of @sunElevationRad@: rotate the Sun TEME vector to ECEF via GMST and
-- take the topocentric elevation.
sunElevationRad :: UTCTime -> GeodeticPosition -> Double
sunElevationRad t observer =
  let g = gmst (utcToSplitJD t)
      sunEcef = temeToEcef g (TEMEPosition (sunPositionTemeKm t))
      observation = topocentricObservation observer sunEcef zeroEcefVelocity
   in getRadians (topoElevation observation)

-- | True when an ECEF position is inside Earth's cylindrical shadow. Port of
-- the web @isInEarthShadow@ using the raw @linear@ ECEF vectors.
isInEarthShadow :: V3 Double -> V3 Double -> Bool
isInEarthShadow satEcf sunEcf =
  let antiSun = normalizeV (negated sunEcf)
      p = dot satEcf antiSun
   in p > 0.0 && sqrt (max 0.0 (dot satEcf satEcf - p * p)) < earthRadiusKm

-- | Phase angle at the satellite between the Sun and the observer, in radians.
phaseAngleRad :: V3 Double -> V3 Double -> V3 Double -> Double
phaseAngleRad sunEcf satEcf obsEcf =
  let sunDir = normalizeV (sunEcf ^-^ satEcf)
      obsDir = normalizeV (obsEcf ^-^ satEcf)
   in acos (clampD (-1.0) 1.0 (dot sunDir obsDir))

-- | Apparent magnitude from standard magnitude, slant range, and phase angle.
-- Port of the web @apparentMagnitude@.
apparentMagnitude :: StdMag -> Double -> Double -> Double
apparentMagnitude stdMag rangeKm phaseRad =
  let arg = sin phaseRad + (pi - phaseRad) * cos phaseRad
   in if arg <= 0.0
        then infinity
        else stdMag + 5.0 * logBase 10.0 (rangeKm / 1000.0) - 2.5 * logBase 10.0 arg

data ObjEval = ObjEval
  { oeElevationRad :: !Double
  , oeAzimuthRad :: !Double
  , oeSunlit :: !Bool
  , oeMag :: !Double
  }

-- | Evaluate whether a conjunction is naked-eye visible to an observer at TCA.
--
-- A faithful port of the web @conjunctionVisibility@: both objects are
-- evaluated from their stored TEME positions, the observer must be dark, the
-- peak elevation must clear the minimum, and at least one object must be
-- sunlit; the brighter (minimum) magnitude is reported. The only addition is
-- the @vpMagnitudeCutoff@ gate (the panel exposes this cutoff but does not
-- itself filter the conjunction list by it), which keeps notifications to
-- plausibly naked-eye events while remaining a subset of the panel's list.
conjunctionVisibility ::
  VisibilityParams ->
  GeodeticPosition ->
  (Int -> Maybe StdMag) ->
  StoredConjunction ->
  Maybe VisibleConjunction
conjunctionVisibility VisibilityParams {..} observer stdMagOf conj =
  let tca = scTca conj
      g = gmst (utcToSplitJD tca)
      ECEFPosition sunEcef = temeToEcef g (TEMEPosition (sunPositionTemeKm tca))
      ECEFPosition obsEcef = geodeticToEcef observer
      evaluate obj =
        let ECEFPosition satEcef = temeToEcef g (TEMEPosition (soTeme obj))
            observation = topocentricObservation observer (ECEFPosition satEcef) zeroEcefVelocity
            sunlit = not (isInEarthShadow satEcef sunEcef)
            stdMag = fromMaybe defaultStdMag (stdMagOf (soNoradId obj))
            phase = phaseAngleRad sunEcef satEcef obsEcef
            rangeKm = getKilometers (topoRange observation)
         in ObjEval
              { oeElevationRad = getRadians (topoElevation observation)
              , oeAzimuthRad = getRadians (topoAzimuth observation)
              , oeSunlit = sunlit
              , oeMag = if sunlit then apparentMagnitude stdMag rangeKm phase else infinity
              }
      a = evaluate (scObjectA conj)
      b = evaluate (scObjectB conj)
      observerDark = sunElevationRad tca observer < degToRad vpSunMaxElevationDeg
      higher = if oeElevationRad a >= oeElevationRad b then a else b
      peakElevationRad = oeElevationRad higher
      peakMagnitude = min (oeMag a) (oeMag b)
   in if not observerDark
        || peakElevationRad < degToRad vpMinElevationDeg
        || not (oeSunlit a || oeSunlit b)
        || peakMagnitude > vpMagnitudeCutoff
        then Nothing
        else
          Just
            VisibleConjunction
              { vcId = scId conj
              , vcTca = tca
              , vcANoradId = soNoradId (scObjectA conj)
              , vcBNoradId = soNoradId (scObjectB conj)
              , vcAName = soName (scObjectA conj)
              , vcBName = soName (scObjectB conj)
              , vcMissDistanceKm = scMissDistanceKm conj
              , vcPeakElevationDeg = radToDeg peakElevationRad
              , vcPeakAzimuthDeg = mod360 (radToDeg (oeAzimuthRad higher))
              , vcPeakMagnitude = peakMagnitude
              }

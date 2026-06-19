-- | Unit tests for "Conjunction.Visibility", the server-side port of the
-- browser's conjunction visibility math.
--
-- The Sun model, shadow test, and magnitude model are checked against known
-- physical properties. The full 'conjunctionVisibility' decision is exercised
-- with geometry constructed directly from the computed Sun direction: an
-- observer is placed at a chosen great-circle angle from the subsolar point
-- (so its darkness is controlled) and a satellite is placed straight overhead
-- (so its elevation and sunlit state follow from that same angle). This avoids
-- any dependency on a real ephemeris while exercising the real gating logic.
module Main (main) where

import Conjunction.Visibility
  ( StoredConjunction (..)
  , StoredObject (..)
  , VisibleConjunction (..)
  , apparentMagnitude
  , conjunctionVisibility
  , defaultVisibilityParams
  , isInEarthShadow
  , sunElevationRad
  , sunPositionTemeKm
  )
import Data.Time (UTCTime (UTCTime), fromGregorian, secondsToDiffTime)
import Linear.Metric (dot, norm, normalize)
import Linear.V3 (V3 (V3))
import Linear.Vector ((^+^), (^-^), (^*))
import SGP4
  ( ECEFPosition (ECEFPosition)
  , ECEFVelocity (ECEFVelocity)
  , GeodeticPosition
  , TEMEPosition (TEMEPosition, getTEMEPosition)
  , TopocentricObservation (topoElevation)
  , Radians (getRadians)
  , ecefToGeodetic
  , ecefToTeme
  , gmst
  , temeToEcef
  , topocentricObservation
  , utcToSplitJD
  )
import System.Exit (exitFailure)
import Text.Printf (printf)

main :: IO ()
main = do
  runTest "Sun distance is about one astronomical unit" testSunDistance
  runTest "Sun elevation cycles through day and night" testSunElevationCycle
  runTest "anti-solar low orbit is in Earth shadow" testShadowBehindEarth
  runTest "sunward and far-offset points are sunlit" testShadowSunlit
  runTest "apparent magnitude fades with range" testMagnitudeRange
  runTest "apparent magnitude is brightest at full phase" testMagnitudePhase
  runTest "twilight overhead pass is visible" testVisibleScenario
  runTest "daylit observer yields no visibility" testDaytimeScenario
  runTest "fully shadowed pair yields no visibility" testShadowScenario
  runTest "low-elevation pass yields no visibility" testLowElevationScenario
  runTest "too-faint pair yields no visibility" testFaintScenario

-- Constants -----------------------------------------------------------------

auKm :: Double
auKm = 149597870.7

wgs84A :: Double
wgs84A = 6378.137

-- | Reference instant; every Sun-relative scenario is derived from it, so the
-- exact value only needs to be a representative epoch.
refTime :: UTCTime
refTime = UTCTime (fromGregorian 2026 3 20) (secondsToDiffTime (10 * 3600))

-- Sun model -----------------------------------------------------------------

testSunDistance :: IO ()
testSunDistance = do
  let r = norm (sunPositionTemeKm refTime) / auKm
  assertBool
    (printf "Sun distance should be within 2%% of 1 AU, got %.4f AU" r)
    (r > 0.98 && r < 1.02)

-- | Sampling a full day at a fixed observer must show the Sun both above and
-- below the horizon, confirming the elevation sign convention.
testSunElevationCycle :: IO ()
testSunElevationCycle = do
  let observer = observerAt (V3 1.0 0.0 0.0)
      elevations =
        [ sunElevationRad (addSeconds refTime (fromIntegral (h * 3600))) observer
        | h <- [0 .. 23 :: Int]
        ]
  assertBool "Sun should rise above the horizon during the day" (maximum elevations > 0)
  assertBool "Sun should fall below the horizon at night" (minimum elevations < 0)

-- Shadow --------------------------------------------------------------------

testShadowBehindEarth :: IO ()
testShadowBehindEarth = do
  let sun = V3 auKm 0.0 0.0
      sat = V3 (-6771.0) 0.0 0.0
  assertBool "low orbit directly behind Earth must be shadowed" (isInEarthShadow sat sun)

testShadowSunlit :: IO ()
testShadowSunlit = do
  let sun = V3 auKm 0.0 0.0
      sunward = V3 6771.0 0.0 0.0
      farOffset = V3 (-6771.0) 9000.0 0.0
  assertBool "sunward point must be sunlit" (not (isInEarthShadow sunward sun))
  assertBool "point well off the shadow axis must be sunlit" (not (isInEarthShadow farOffset sun))

-- Magnitude -----------------------------------------------------------------

testMagnitudeRange :: IO ()
testMagnitudeRange = do
  let near = apparentMagnitude 4.0 500.0 0.5
      far = apparentMagnitude 4.0 2000.0 0.5
  assertBool
    (printf "farther object should be fainter: near=%.3f far=%.3f" near far)
    (far > near)

testMagnitudePhase :: IO ()
testMagnitudePhase = do
  let full = apparentMagnitude 4.0 1000.0 0.0
      half = apparentMagnitude 4.0 1000.0 (pi / 2.0)
  assertBool
    (printf "full phase should be brighter than half phase: full=%.3f half=%.3f" full half)
    (full < half)

-- conjunctionVisibility decisions -------------------------------------------

testVisibleScenario :: IO ()
testVisibleScenario = do
  let observer = observerAt direction
      direction = dirAtSunAngle refTime 100.0
      sat = overheadTeme refTime direction 400.0
      conj = mkConj refTime sat sat
  assertBool "observer should be dark at the chosen geometry" (sunElevationDeg observer < -6.0)
  assertBool "satellite should be near the zenith" (elevationDeg observer sat > 80.0)
  case conjunctionVisibility defaultVisibilityParams observer brightStdMag conj of
    Nothing -> failTest "expected a visible conjunction for the twilight overhead pass"
    Just vc -> do
      assertBool
        (printf "peak elevation should be high, got %.1f" (vcPeakElevationDeg vc))
        (vcPeakElevationDeg vc > 80.0)
      assertBool
        (printf "peak magnitude should clear the cutoff, got %.2f" (vcPeakMagnitude vc))
        (vcPeakMagnitude vc <= 6.5)
      assertBool
        (printf "peak azimuth should be a valid compass bearing, got %.1f" (vcPeakAzimuthDeg vc))
        (vcPeakAzimuthDeg vc >= 0.0 && vcPeakAzimuthDeg vc < 360.0)

testDaytimeScenario :: IO ()
testDaytimeScenario = do
  let observer = observerAt direction
      direction = dirAtSunAngle refTime 60.0
      sat = overheadTeme refTime direction 400.0
      conj = mkConj refTime sat sat
  assertBool "observer should be in daylight" (sunElevationDeg observer > 6.0)
  assertNothing "daylit observer" (conjunctionVisibility defaultVisibilityParams observer brightStdMag conj)

testShadowScenario :: IO ()
testShadowScenario = do
  let observer = observerAt direction
      direction = dirAtSunAngle refTime 140.0
      sat = overheadTeme refTime direction 400.0
      conj = mkConj refTime sat sat
  assertBool "observer should be dark" (sunElevationDeg observer < -6.0)
  assertBool "satellite should be near the zenith" (elevationDeg observer sat > 80.0)
  assertNothing "fully shadowed pair" (conjunctionVisibility defaultVisibilityParams observer brightStdMag conj)

testLowElevationScenario :: IO ()
testLowElevationScenario = do
  let observer = observerAt direction
      direction = dirAtSunAngle refTime 100.0
      lowDir = rotateToward direction (sunHat refTime) 40.0
      sat = overheadTeme refTime lowDir 400.0
      conj = mkConj refTime sat sat
  assertBool "observer should be dark" (sunElevationDeg observer < -6.0)
  assertBool
    (printf "satellite should sit below the minimum elevation, got %.1f" (elevationDeg observer sat))
    (elevationDeg observer sat < 10.0)
  assertNothing "low-elevation pass" (conjunctionVisibility defaultVisibilityParams observer brightStdMag conj)

testFaintScenario :: IO ()
testFaintScenario = do
  let observer = observerAt direction
      direction = dirAtSunAngle refTime 100.0
      sat = overheadTeme refTime direction 400.0
      conj = mkConj refTime sat sat
  assertBool "observer should be dark" (sunElevationDeg observer < -6.0)
  assertNothing "too-faint pair" (conjunctionVisibility defaultVisibilityParams observer faintStdMag conj)

-- Scene construction --------------------------------------------------------

brightStdMag :: Int -> Maybe Double
brightStdMag nid = if nid == 25544 || nid == 25545 then Just (-1.8) else Nothing

faintStdMag :: Int -> Maybe Double
faintStdMag _ = Just 12.0

mkConj :: UTCTime -> V3 Double -> V3 Double -> StoredConjunction
mkConj t temeA temeB =
  StoredConjunction
    { scId = 1
    , scTca = t
    , scMissDistanceKm = 0.5
    , scObjectA = StoredObject 25544 Nothing temeA
    , scObjectB = StoredObject 25545 Nothing temeB
    }

-- | Unit ECEF direction at the given great-circle angle (degrees) from the
-- subsolar point, in the plane spanned by the Sun direction and a fixed
-- perpendicular. The angle equals @90 - sunElevation@ at that location.
dirAtSunAngle :: UTCTime -> Double -> V3 Double
dirAtSunAngle t thetaDeg =
  let s = sunHat t
      e = perpTo s
      th = degToRad thetaDeg
   in s ^* cos th ^+^ e ^* sin th

-- | Rotate @d@ toward @toward@ by the given angle (degrees) within their plane.
rotateToward :: V3 Double -> V3 Double -> Double -> V3 Double
rotateToward d toward angDeg =
  let e = normalize (toward ^-^ d ^* dot d toward)
      a = degToRad angDeg
   in d ^* cos a ^+^ e ^* sin a

-- | Observer geodetic position on the ellipsoid beneath a unit ECEF direction.
observerAt :: V3 Double -> GeodeticPosition
observerAt d = ecefToGeodetic (ECEFPosition (normalize d ^* wgs84A))

-- | TEME position of a satellite at @altKm@ straight up along @d@ at time @t@.
overheadTeme :: UTCTime -> V3 Double -> Double -> V3 Double
overheadTeme t d altKm =
  let g = gmst (utcToSplitJD t)
      satEcef = ECEFPosition (normalize d ^* (wgs84A + altKm))
   in getTEMEPosition (ecefToTeme g satEcef)

sunHat :: UTCTime -> V3 Double
sunHat t =
  let g = gmst (utcToSplitJD t)
      ECEFPosition s = temeToEcef g (TEMEPosition (sunPositionTemeKm t))
   in normalize s

perpTo :: V3 Double -> V3 Double
perpTo s = normalize (ref ^-^ s ^* dot ref s)
  where
    ref = V3 0.0 0.0 1.0

sunElevationDeg :: GeodeticPosition -> Double
sunElevationDeg observer = radToDeg (sunElevationRad refTime observer)

elevationDeg :: GeodeticPosition -> V3 Double -> Double
elevationDeg observer satTeme =
  let g = gmst (utcToSplitJD refTime)
      satEcef = temeToEcef g (TEMEPosition satTeme)
      observation = topocentricObservation observer satEcef (ECEFVelocity (V3 0.0 0.0 0.0))
   in radToDeg (getRadians (topoElevation observation))

degToRad :: Double -> Double
degToRad d = d * pi / 180.0

radToDeg :: Double -> Double
radToDeg r = r * 180.0 / pi

addSeconds :: UTCTime -> Double -> UTCTime
addSeconds (UTCTime day dt) secs =
  UTCTime day (dt + secondsToDiffTime (round secs))

-- Harness -------------------------------------------------------------------

runTest :: String -> IO () -> IO ()
runTest name action = do
  action
  putStrLn ("ok - " <> name)

assertBool :: String -> Bool -> IO ()
assertBool _ True = pure ()
assertBool message False = failTest message

assertNothing :: String -> Maybe a -> IO ()
assertNothing _ Nothing = pure ()
assertNothing label (Just _) = failTest (label <> ": expected no visible conjunction")

failTest :: String -> IO a
failTest message = do
  putStrLn ("FAIL - " <> message)
  exitFailure

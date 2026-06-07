{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (evaluate)
import Control.Monad (forM, forM_, unless)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), addUTCTime)
import Linear.V3 (V3 (V3))
import SGP4
  ( Satellite
  , Sgp4Error
  , StateVector (..)
  , TLE (..)
  , Vec3 (..)
  , initializeFromTLE
  , propagate
  , propagateTLE
  , propagateTLEMany
  , satelliteNumber
  , sgp4ErrorCode
  )
import SGP4.Coordinate
  ( ECEFPosition (ECEFPosition)
  , ECEFVelocity (ECEFVelocity)
  , ENUVector (ENUVector)
  , GeodeticPosition (GeodeticPosition)
  , Kilometers (Km)
  , KilometersPerSecond (KmS)
  , Radians (Radians)
  , TEMEPosition (TEMEPosition)
  , TEMEState (TEMEState)
  , TEMEVelocity (TEMEVelocity)
  , TopocentricObservation (TopocentricObservation)
  , mkTEMEPosition
  , mkTEMEVelocity
  , toRadians
  , Degrees (Degrees)
  )
import SGP4.Frames
  ( earthAngularVelocity
  , ecefStateToTeme
  , ecefToGeodetic
  , ecefToTeme
  , ecefToEnu
  , geodeticToEcef
  , temeStateToEcef
  , temeToEcef
  , temeVelocityToEcef
  , topocentricObservation
  , wgs84A
  , wgs84B
  )
import SGP4.Time
  ( GMST (GMST)
  , MinutesSinceEpoch (MinutesSinceEpoch)
  , SplitJD (SplitJD)
  , gmst
  , j2000
  , satelliteEpochSJD
  , splitJDToUTC
  , toSingleJD
  , utcToSplitJD
  , utcToTsince
  )
import SpaceTrack.Json (decodeGpRecords)
import SpaceTrack.Types (GpRecord (..), JsonValue (..))
import Text.Printf (printf)

main :: IO ()
main = do
  runTest "satellite number and 00005 vectors" testSat00005
  runTest "08195 deep-space vector" testSat08195
  runTest "09998 backward propagation" testSat09998
  runTest "33334 reports initialization error" testSat33334Error
  runTest "33333 reports semi-latus rectum error" testSat33333Error
  runTest "28872 reports decay" testSat28872Decay
  runTest "propagateTLE is repeatable" testPropagateTLERepeatable
  runTest "propagateTLE is call-order independent" testPropagateTLEOrderIndependent
  runTest "propagateTLEMany matches individual propagation" testPropagateTLEMany
  runTest "propagateTLE matches IO API" testPropagateTLEMatchesIO
  runTest "propagateTLE is consistent across parallel calls" testPropagateTLEParallel
  runTest "Julian date anchors" testJulianDateAnchors
  runTest "00005 epoch converts to tsince" testTsinceConversion
  runTest "GMST at J2000" testGmstJ2000
  runTest "TEME/ECEF frame transforms" testFrameTransforms
  runTest "WGS84 geodetic/ECEF transforms" testGeodeticTransforms
  runTest "topocentric ENU observation" testTopocentricObservation
  runTest "Space-Track GP JSON decoder" testGpJsonDecoder

runTest :: String -> IO () -> IO ()
runTest name action = do
  action
  putStrLn ("ok - " <> name)

testSat00005 :: IO ()
testSat00005 = do
  sat <- initSatellite tle00005
  satnum <- satelliteNumber sat
  assertEqual "satnum" "00005" satnum
  state0 <- expectState =<< propagate sat 0.0
  assertState 1e-6 "00005 t=0" expected00005T0 state0
  state360 <- expectState =<< propagate sat 360.0
  assertState 1e-6 "00005 t=360" expected00005T360 state360

testSat08195 :: IO ()
testSat08195 = do
  sat <- initSatellite tle08195
  actual <- expectState =<< propagate sat 1440.0
  assertState 1e-4 "08195 t=1440" expected08195T1440 actual

testSat09998 :: IO ()
testSat09998 = do
  sat <- initSatellite tle09998
  actual <- expectState =<< propagate sat (-1440.0)
  assertState 1e-6 "09998 t=-1440" expected09998TMinus1440 actual

testSat33334Error :: IO ()
testSat33334Error = do
  expectInitErrorCode "33334 initialization" 3 =<< initializeFromTLE tle33334

testSat33333Error :: IO ()
testSat33333Error = do
  sat <- initSatellite tle33333
  expectErrorCode "33333 t=25" 4 =<< propagate sat 25.0

testSat28872Decay :: IO ()
testSat28872Decay = do
  sat <- initSatellite tle28872
  results <- forM [0, 5 .. 60] (propagate sat)
  unless (any (hasErrorCode 6) results) $
    failTest "28872 should report decay error 6 by 60 minutes"

testPropagateTLERepeatable :: IO ()
testPropagateTLERepeatable = do
  let results = replicate 20 (propagateTLE tle00005 360.0)
  assertAllEqual "repeat 00005 t=360" results

testPropagateTLEOrderIndependent :: IO ()
testPropagateTLEOrderIndependent = do
  let before = propagateTLE tle00005 0.0
  _ <- evaluate (propagateTLE tle00005 360.0)
  let after = propagateTLE tle00005 0.0
  assertEqual "00005 t=0 before/after t=360" before after

testPropagateTLEMany :: IO ()
testPropagateTLEMany = do
  let normalTimes = [0.0, 360.0, 720.0, 1440.0]
  assertEqual
    "00005 batch"
    (sequenceA (map (propagateTLE tle00005) normalTimes))
    (propagateTLEMany tle00005 normalTimes)
  let errorTimes = [0.0, 25.0, 50.0]
  assertEqual
    "33333 batch with error"
    (sequenceA (map (propagateTLE tle33333) errorTimes))
    (propagateTLEMany tle33333 errorTimes)

testPropagateTLEMatchesIO :: IO ()
testPropagateTLEMatchesIO = do
  sat <- initSatellite tle00005
  explicit <- propagate sat 360.0
  assertEqual "00005 pure vs IO" explicit (propagateTLE tle00005 360.0)
  initError <- initializeFromTLE tle33334
  case (initError, propagateTLE tle33334 0.0) of
    (Left expected, Left actual) -> assertEqual "33334 pure init error vs IO init error" expected actual
    _ -> failTest "33334 should fail during both IO initialization and pure propagation"

testPropagateTLEParallel :: IO ()
testPropagateTLEParallel = do
  let times = concat (replicate 8 [0.0, 360.0, 720.0, 1440.0])
      expected = map (propagateTLE tle00005) times
  actual <- parallelMap (propagateTLE tle00005) times
  assertEqual "parallel 00005 propagation" expected actual

testGpJsonDecoder :: IO ()
testGpJsonDecoder = do
  records <- decodeGpRecords sampleGpJson
  case records of
    [record] -> do
      assertEqual "norad cat id" 25544 (gpNoradCatId record)
      assertEqual "object name" (Just "ISS (ZARYA)") (gpObjectName record)
      assertEqual "periapsis" 415.0 (gpPeriapsisKm record)
      assertEqual "decay date" Nothing (gpDecayDate record)
      unless (not (LBS8.null (unJsonValue (gpRawJson record)))) $
        failTest "raw JSON should be retained"
    _ -> failTest "expected one decoded GP record"

testJulianDateAnchors :: IO ()
testJulianDateAnchors = do
  assertSplitJD 1e-12 "Unix epoch" (SplitJD 2440587.5 0.0) (utcToSplitJD (UTCTime (fromGregorian 1970 1 1) 0))
  assertSplitJD 1e-12 "GPS epoch" (SplitJD 2444244.5 0.0) (utcToSplitJD (UTCTime (fromGregorian 1980 1 6) 0))
  assertSplitJD 1e-12 "J2000" (SplitJD 2451544.5 0.5) (utcToSplitJD (UTCTime (fromGregorian 2000 1 1) 43200))

testTsinceConversion :: IO ()
testTsinceConversion = do
  sat <- initSatellite tle00005
  epoch <- satelliteEpochSJD sat
  assertSplitJD 1e-8 "00005 epoch" (SplitJD 2451722.5 0.78495062) epoch
  let epochUTC = splitJDToUTC epoch
  MinutesSinceEpoch zero <- utcToTsince sat epochUTC
  assertClose 1e-6 "00005 epoch tsince" 0.0 zero
  MinutesSinceEpoch plus360 <- utcToTsince sat (addUTCTime (360.0 * 60.0) epochUTC)
  assertClose 1e-6 "00005 epoch + 360 min tsince" 360.0 plus360

testGmstJ2000 :: IO ()
testGmstJ2000 = do
  let GMST actual = gmst j2000
  assertClose 1e-10 "GMST J2000 radians" 4.894961212823756 actual

testFrameTransforms :: IO ()
testFrameTransforms = do
  let sidereal = GMST 1.234
      position = mkTEMEPosition (Km 7000.0) (Km (-1200.0)) (Km 1300.0)
      velocity = mkTEMEVelocity (KmS 1.0) (KmS 7.2) (KmS (-0.4))
      ECEFPosition ecefPosition = temeToEcef sidereal position
      TEMEPosition roundTripPosition = ecefToTeme sidereal (ECEFPosition ecefPosition)
  assertV3 1e-9 "TEME/ECEF position roundtrip" (let TEMEPosition v = position in v) roundTripPosition
  let ecefState =
        temeStateToEcef sidereal (TEMEState position velocity (MinutesSinceEpoch 42.0))
      TEMEState (TEMEPosition statePosition) (TEMEVelocity stateVelocity) (MinutesSinceEpoch tsince) =
        uncurry (ecefStateToTeme sidereal (MinutesSinceEpoch 42.0)) ecefState
  assertV3 1e-9 "TEME/ECEF state position roundtrip" (let TEMEPosition v = position in v) statePosition
  assertV3 1e-9 "TEME/ECEF state velocity roundtrip" (let TEMEVelocity v = velocity in v) stateVelocity
  assertClose 1e-12 "TEME/ECEF state tsince roundtrip" 42.0 tsince
  let ECEFVelocity (V3 vx vy vz) =
        temeVelocityToEcef
          (GMST 0.0)
          (mkTEMEPosition (Km wgs84A) (Km 0.0) (Km 0.0))
          (mkTEMEVelocity (KmS 0.0) (KmS 7.5) (KmS 0.0))
  assertClose 1e-12 "ECEF velocity correction x" 0.0 vx
  assertClose 1e-12 "ECEF velocity correction y" (7.5 - earthAngularVelocity * wgs84A) vy
  assertClose 1e-12 "ECEF velocity correction z" 0.0 vz

testGeodeticTransforms :: IO ()
testGeodeticTransforms = do
  let equator = GeodeticPosition (Radians 0.0) (Radians 0.0) (Km 0.0)
      ECEFPosition (V3 ex ey ez) = geodeticToEcef equator
  assertClose 1e-12 "WGS84 equator x" wgs84A ex
  assertClose 1e-12 "WGS84 equator y" 0.0 ey
  assertClose 1e-12 "WGS84 equator z" 0.0 ez
  let northPole = GeodeticPosition (Radians (pi / 2.0)) (Radians 0.0) (Km 0.0)
      ECEFPosition (V3 nx ny nz) = geodeticToEcef northPole
  assertClose 1e-9 "WGS84 north pole x" 0.0 nx
  assertClose 1e-9 "WGS84 north pole y" 0.0 ny
  assertClose 1e-9 "WGS84 north pole z" wgs84B nz
  let boulder =
        GeodeticPosition
          (toRadians (Degrees 40.0150))
          (toRadians (Degrees (-105.2705)))
          (Km 1.655)
      GeodeticPosition (Radians lat) (Radians lon) (Km alt) = ecefToGeodetic (geodeticToEcef boulder)
      GeodeticPosition (Radians expectedLat) (Radians expectedLon) (Km expectedAlt) = boulder
  assertClose 1e-10 "geodetic roundtrip latitude" expectedLat lat
  assertClose 1e-10 "geodetic roundtrip longitude" expectedLon lon
  assertClose 1e-8 "geodetic roundtrip altitude" expectedAlt alt

testTopocentricObservation :: IO ()
testTopocentricObservation = do
  let observer = GeodeticPosition (Radians 0.0) (Radians 0.0) (Km 0.0)
      target = ECEFPosition (V3 (wgs84A + 100.0) 0.0 0.0)
      velocity = ECEFVelocity (V3 0.0 0.0 0.0)
      ENUVector (V3 east north up) = ecefToEnu observer target
  assertClose 1e-12 "ENU east" 0.0 east
  assertClose 1e-12 "ENU north" 0.0 north
  assertClose 1e-12 "ENU up" 100.0 up
  let TopocentricObservation (Km range) (KmS rangeRate) (Radians azimuth) (Radians elevation) =
        topocentricObservation observer target velocity
  assertClose 1e-12 "topocentric range" 100.0 range
  assertClose 1e-12 "topocentric range rate" 0.0 rangeRate
  assertClose 1e-12 "topocentric azimuth" 0.0 azimuth
  assertClose 1e-12 "topocentric elevation" (pi / 2.0) elevation

initSatellite :: TLE -> IO Satellite
initSatellite tle = do
  result <- initializeFromTLE tle
  case result of
    Left err -> failTest ("initialization failed: " <> show err)
    Right sat -> pure sat

expectState :: Either Sgp4Error StateVector -> IO StateVector
expectState (Right actual) = pure actual
expectState (Left err) = failTest ("expected state, got error: " <> show err)

expectErrorCode :: String -> Int -> Either Sgp4Error StateVector -> IO ()
expectErrorCode _ expected (Left err)
  | sgp4ErrorCode err == expected = pure ()
expectErrorCode label expected result =
  failTest (label <> ": expected error code " <> show expected <> ", got " <> show result)

expectInitErrorCode :: String -> Int -> Either Sgp4Error Satellite -> IO ()
expectInitErrorCode _ expected (Left err)
  | sgp4ErrorCode err == expected = pure ()
expectInitErrorCode label expected result =
  failTest (label <> ": expected initialization error code " <> show expected <> ", got " <> either show (const "success") result)

hasErrorCode :: Int -> Either Sgp4Error StateVector -> Bool
hasErrorCode expected (Left err) = sgp4ErrorCode err == expected
hasErrorCode _ (Right _) = False

assertState :: Double -> String -> StateVector -> StateVector -> IO ()
assertState tolerance label expected actual = do
  assertVec tolerance (label <> " position") (svPosition expected) (svPosition actual)
  assertVec tolerance (label <> " velocity") (svVelocity expected) (svVelocity actual)

assertVec :: Double -> String -> Vec3 -> Vec3 -> IO ()
assertVec tolerance label (Vec3 ex ey ez) (Vec3 ax ay az) = do
  assertClose tolerance (label <> ".x") ex ax
  assertClose tolerance (label <> ".y") ey ay
  assertClose tolerance (label <> ".z") ez az

assertV3 :: Double -> String -> V3 Double -> V3 Double -> IO ()
assertV3 tolerance label (V3 ex ey ez) (V3 ax ay az) = do
  assertClose tolerance (label <> ".x") ex ax
  assertClose tolerance (label <> ".y") ey ay
  assertClose tolerance (label <> ".z") ez az

assertSplitJD :: Double -> String -> SplitJD -> SplitJD -> IO ()
assertSplitJD tolerance label expected actual =
  assertClose tolerance label (toSingleJD expected) (toSingleJD actual)

assertClose :: Double -> String -> Double -> Double -> IO ()
assertClose tolerance label expected actual =
  unless (abs (expected - actual) <= tolerance) $
    failTest (printf "%s: expected %.12f, got %.12f" label expected actual)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> ": expected " <> show expected <> ", got " <> show actual)

assertAllEqual :: (Eq a, Show a) => String -> [a] -> IO ()
assertAllEqual _ [] = pure ()
assertAllEqual label (expected : actuals) =
  forM_ actuals $ \actual -> assertEqual label expected actual

parallelMap :: (a -> b) -> [a] -> IO [b]
parallelMap f inputs = do
  vars <- forM inputs $ \input -> do
    var <- newEmptyMVar
    _ <- forkIO $ evaluate (f input) >>= putMVar var
    pure var
  mapM takeMVar vars

failTest :: String -> IO a
failTest = ioError . userError

stateVector :: Double -> Vec3 -> Vec3 -> StateVector
stateVector tsince position velocity = StateVector position velocity tsince

expected00005T0 :: StateVector
expected00005T0 =
  stateVector
    0.0
    (Vec3 7022.46529266 (-1400.08296755) 0.03995155)
    (Vec3 1.893841015 6.405893759 4.534807250)

expected00005T360 :: StateVector
expected00005T360 =
  stateVector
    360.0
    (Vec3 (-7154.03120202) (-3783.17682504) (-3536.19412294))
    (Vec3 4.741887409 (-4.151817765) (-2.093935425))

expected08195T1440 :: StateVector
expected08195T1440 =
  stateVector
    1440.0
    (Vec3 2890.80638268 (-15446.43952300) 948.77010176)
    (Vec3 2.654407490 (-2.909344895) 4.486437362)

expected09998TMinus1440 :: StateVector
expected09998TMinus1440 =
  stateVector
    (-1440.0)
    (Vec3 (-11362.18265118) (-35117.55867813) (-5413.62537994))
    (Vec3 3.137861261 (-1.011678260) 0.267510059)

sampleGpJson :: LBS8.ByteString
sampleGpJson =
  LBS8.pack
    "[\
    \{\"NORAD_CAT_ID\":\"25544\",\
    \\"GP_ID\":\"123456789\",\
    \\"OBJECT_NAME\":\"ISS (ZARYA)\",\
    \\"OBJECT_ID\":\"1998-067A\",\
    \\"OBJECT_TYPE\":\"PAYLOAD\",\
    \\"CLASSIFICATION_TYPE\":\"U\",\
    \\"EPOCH\":\"2026-06-06T20:52:03.052128\",\
    \\"CREATION_DATE\":\"2026-06-06T22:00:00\",\
    \\"MEAN_MOTION\":\"15.49642340\",\
    \\"ECCENTRICITY\":\"0.00069776\",\
    \\"INCLINATION\":\"51.6338\",\
    \\"RA_OF_ASC_NODE\":\"351.1688\",\
    \\"ARG_OF_PERICENTER\":\"142.0049\",\
    \\"MEAN_ANOMALY\":\"218.1433\",\
    \\"BSTAR\":\"0.00017236766\",\
    \\"SEMIMAJOR_AXIS\":\"6793.000\",\
    \\"PERIOD\":\"92.930\",\
    \\"APOAPSIS\":\"421.000\",\
    \\"PERIAPSIS\":\"415.000\",\
    \\"DECAY_DATE\":null,\
    \\"TLE_LINE0\":\"ISS (ZARYA)\",\
    \\"TLE_LINE1\":\"1 25544U 98067A   26157.86947977  .00009276  00000+0  17237-3 0  9990\",\
    \\"TLE_LINE2\":\"2 25544  51.6338 351.1688 0006978 142.0049 218.1433 15.49642340570150\"}\
    \]"

tle00005 :: TLE
tle00005 =
  TLE
    "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
    "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667"

tle08195 :: TLE
tle08195 =
  TLE
    "1 08195U 75081A   06176.33215444  .00000099  00000-0  11873-3 0   813"
    "2 08195  64.1586 279.0717 6877146 264.7651  20.2257  2.00491383225656"

tle09998 :: TLE
tle09998 =
  TLE
    "1 09998U 74033F   05148.79417928 -.00000112  00000-0  00000+0 0  4480"
    "2 09998   9.4958 313.1750 0270971 327.5225  30.8097  1.16186785 45878"

tle28872 :: TLE
tle28872 =
  TLE
    "1 28872U 05037B   05333.02012661  .25992681  00000-0  24476-3 0  1534"
    "2 28872  96.4736 157.9986 0303955 244.0492 110.6523 16.46015938 10708"

tle33333 :: TLE
tle33333 =
  TLE
    "1 33333U 05037B   05333.02012661  .25992681  00000-0  24476-3 0  1534"
    "2 33333  96.4736 157.9986 9950000 244.0492 110.6523  4.00004038 10708"

tle33334 :: TLE
tle33334 =
  TLE
    "1 33334U 78066F   06174.85818871  .00000620  00000-0  10000-3 0  6809"
    "2 33334  68.4714 236.1303 5602877 123.7484 302.5767  0.00001000 67521"

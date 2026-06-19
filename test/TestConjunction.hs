{-# LANGUAGE OverloadedStrings #-}

-- | Validation tests for the conjunction-screening algorithms.
--
-- The central property is that the raw all-pairs CM-COMBO screen and the
-- optimized spatial-hash screen produce identical events. Fixtures are built
-- from the canonical ISS test TLE (shared epoch) so propagation is well behaved:
-- duplicates give a guaranteed zero-distance conjunction, a one-column
-- mean-anomaly nudge gives a sub-5 km near miss, and a raised mean motion gives
-- a band-separated object that must never conjunct with the ISS cluster.
module Main (main) where

import Conjunction.Catalog (initCatalog)
import Conjunction.Run
  ( ValidationResult (..)
  , compareRuns
  , screenOptimized
  , screenRaw
  , screenValidate
  )
import Conjunction.Screen (coarseThresholdKm)
import Conjunction.Types
  ( CatalogObject
  , ConjunctionEvent (..)
  , ObjectState (..)
  , ScreenConfig (..)
  , defaultScreenConfig
  )
import Control.Monad (unless)
import Data.List (find, minimumBy, sort)
import Data.Ord (comparing)
import Data.Time (UTCTime (UTCTime), diffUTCTime, fromGregorian)
import SGP4 (TLE (..))
import System.Exit (exitFailure)
import Text.Printf (printf)

main :: IO ()
main = do
  runTest "coarse threshold derivation" testCoarseThreshold
  runTest "raw and optimized agree on fixture" testRawOptimizedAgree
  runTest "duplicate objects conjunct at zero distance" testDuplicateConjunction
  runTest "mean-anomaly nudge is a sub-5km near miss" testNearMiss
  runTest "band-separated objects do not conjunct" testSeparatedNoConjunction
  runTest "expected event set is exactly produced" testExactEventSet
  runTest "tiled screen matches whole-window screen" testTilingMatchesWhole
  runTest "empty and singleton catalogs yield no events" testDegenerateCatalogs
  runTest "real close approach regression is reported" testRealCloseApproachRegression
  runTest "multiple approaches per pair are reported" testMultipleApproachesPerPair
  runTest "co-orbital pairs are suppressed under the relative-speed floor" testCoorbitalSuppressed
  runTest "genuine crossing survives the relative-speed floor" testGenuineCrossingNotSuppressed
  runTest "co-orbital suppression is independent of window start" testSuppressionWindowIndependent

-- Fixtures ------------------------------------------------------------------

issLine1 :: String
issLine1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927"

-- | Canonical ISS line 2 (mean motion 15.72 rev/day, near-circular LEO).
issLine2 :: String
issLine2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537"

-- | ISS line 2 with mean anomaly nudged +0.02 deg (column 49): ~2.4 km offset.
issLine2Nudged :: String
issLine2Nudged = "2 25544  51.6416 247.4627 0006703 130.5360 325.0488 15.72125391563537"

-- | ISS line 2 with mean motion lowered to 12.5 rev/day: ~1465 km altitude.
issLine2Higher :: String
issLine2Higher = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 12.50000000563537"

issTle :: TLE
issTle = TLE issLine1 issLine2

issNudgedTle :: TLE
issNudgedTle = TLE issLine1 issLine2Nudged

issHigherTle :: TLE
issHigherTle = TLE issLine1 issLine2Higher

realCloseLine1A :: String
realCloseLine1A = "1 54352U 22151CX  26168.42577862  .00097518  00000-0  31591-2 0  9995"

realCloseLine2A :: String
realCloseLine2A = "2 54352  99.0277 336.2112 0045531 221.4394 138.3386 15.30609204120506"

realCloseLine1B :: String
realCloseLine1B = "1 58171U 23166X   26168.11187061 -.00003087  00000-0 -92239-4 0  9997"

realCloseLine2B :: String
realCloseLine2B = "2 58171  53.1587 117.6340 0001884  48.5853 311.5309 15.30163613148407"

realCloseEntries :: [(Int, Maybe String, TLE)]
realCloseEntries =
  [ (54352, Just "CZ-6A DEB", TLE realCloseLine1A realCloseLine2A)
  , (58171, Just "STARLINK-30752", TLE realCloseLine1B realCloseLine2B)
  ]

realCloseConfig :: ScreenConfig
realCloseConfig =
  (defaultScreenConfig (UTCTime (fromGregorian 2026 6 18) 0))
    { scStepSeconds = 10
    }

-- | Same orbit as the ISS fixture except for a 5-degree inclination offset.
-- The larger offset keeps the two node crossings as separate coarse-gate runs.
issLine2Inclined :: String
issLine2Inclined = "2 25544  56.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537"

multiApproachEntries :: [(Int, Maybe String, TLE)]
multiApproachEntries =
  [ (25544, Just "ISS-A", issTle)
  , (25545, Just "ISS-INCLINED", TLE issLine1 issLine2Inclined)
  ]

multiApproachConfig :: ScreenConfig
multiApproachConfig =
  (defaultScreenConfig (UTCTime (fromGregorian 2008 9 20) (12 * 3600)))
    { scWindowHours = 1.6
    , scStepSeconds = 10
    }

-- | NORAD ids chosen so the ISS cluster (1xx) and the raised orbit (2xx) sort
-- into clearly separate groups.
fixtureEntries :: [(Int, Maybe String, TLE)]
fixtureEntries =
  [ (100, Just "ISS-A", issTle)
  , (101, Just "ISS-B", issTle)
  , (102, Just "ISS-C", issNudgedTle)
  , (200, Just "HIGH-A", issHigherTle)
  , (201, Just "HIGH-B", issHigherTle)
  ]

fixtureConfig :: ScreenConfig
fixtureConfig =
  (defaultScreenConfig (UTCTime (fromGregorian 2008 9 21) 0))
    { scWindowHours = 0.5
    }

loadFixture :: IO [CatalogObject]
loadFixture = do
  (objects, errors) <- initCatalog fixtureEntries
  unless (null errors) $
    failTest ("fixture TLEs failed to initialize: " <> show errors)
  pure objects

loadCatalog :: String -> [(Int, Maybe String, TLE)] -> IO [CatalogObject]
loadCatalog label entries = do
  (objects, errors) <- initCatalog entries
  unless (null errors) $
    failTest (label <> " TLEs failed to initialize: " <> show errors)
  pure objects

-- Tests ---------------------------------------------------------------------

testCoarseThreshold :: IO ()
testCoarseThreshold =
  assertClose 1e-9 "derived coarse threshold" 473.0 (coarseThresholdKm fixtureConfig)

testRawOptimizedAgree :: IO ()
testRawOptimizedAgree = do
  objects <- loadFixture
  result <- screenValidate fixtureConfig objects
  unless (vrAgree result) $
    failTest
      ( "raw and optimized disagree: onlyRaw="
          <> show (vrOnlyRaw result)
          <> " onlyOptimized="
          <> show (vrOnlyOptimized result)
          <> " maxMissDiffKm="
          <> show (vrMaxMissDiffKm result)
      )
  assertClose 1e-9 "max miss-distance difference" 0.0 (vrMaxMissDiffKm result)

testDuplicateConjunction :: IO ()
testDuplicateConjunction = do
  objects <- loadFixture
  events <- screenOptimized fixtureConfig objects
  event <- expectEvent events (100, 101)
  assertClose 1e-6 "duplicate miss distance" 0.0 (ceMissDistanceKm event)
  assertClose 1e-6 "duplicate relative speed" 0.0 (ceRelativeSpeedKms event)

testNearMiss :: IO ()
testNearMiss = do
  objects <- loadFixture
  events <- screenOptimized fixtureConfig objects
  event <- expectEvent events (100, 102)
  assertBool
    ("near-miss distance should be within (0, 5) km, got " <> show (ceMissDistanceKm event))
    (ceMissDistanceKm event > 0.1 && ceMissDistanceKm event < 5.0)

testSeparatedNoConjunction :: IO ()
testSeparatedNoConjunction = do
  objects <- loadFixture
  events <- screenOptimized fixtureConfig objects
  let crossPairs =
        [ pairKey event
        | event <- events
        , let (a, b) = pairKey event
        , (a < 200) /= (b < 200)
        ]
  unless (null crossPairs) $
    failTest ("ISS cluster should not conjunct with raised orbit: " <> show crossPairs)

testExactEventSet :: IO ()
testExactEventSet = do
  objects <- loadFixture
  events <- screenOptimized fixtureConfig objects
  let actual = sort (map pairKey events)
      expected = [(100, 101), (100, 102), (101, 102), (200, 201)]
  unless (actual == expected) $
    failTest ("expected event pairs " <> show expected <> " but got " <> show actual)

-- | Screening the window in small tiles must yield exactly the same events
-- (pairs, miss distances, and times of closest approach) as screening the whole
-- window at once. This guards the time-tiling memory optimization against
-- changing any detected conjunction.
testTilingMatchesWhole :: IO ()
testTilingMatchesWhole = do
  objects <- loadFixture
  whole <- screenOptimized fixtureConfig objects
  tiled <- screenOptimized fixtureConfig {scTileHours = Just 0.05} objects
  let summarize = sort . map eventSummary
  unless (summarize whole == summarize tiled) $
    failTest
      ( "tiled screen differs from whole-window screen: whole="
          <> show (summarize whole)
          <> " tiled="
          <> show (summarize tiled)
      )

eventSummary :: ConjunctionEvent -> ((Int, Int), Double, UTCTime)
eventSummary event = (pairKey event, ceMissDistanceKm event, ceTca event)

testDegenerateCatalogs :: IO ()
testDegenerateCatalogs = do
  emptyEvents <- screenOptimized fixtureConfig []
  unless (null emptyEvents) (failTest "empty catalog should yield no events")
  (singleton, _) <- initCatalog (take 1 fixtureEntries)
  singletonRaw <- screenRaw fixtureConfig singleton
  singletonOptimized <- screenOptimized fixtureConfig singleton
  unless (null singletonRaw && null singletonOptimized) $
    failTest "singleton catalog should yield no events"
  let validation = compareRuns singletonRaw singletonOptimized
  unless (vrAgree validation) (failTest "singleton runs should trivially agree")

testRealCloseApproachRegression :: IO ()
testRealCloseApproachRegression = do
  objects <- loadCatalog "real close approach" realCloseEntries
  rawEvents <- screenRaw realCloseConfig objects
  optimizedEvents <- screenOptimized realCloseConfig objects
  let rawPairEvents = eventsForPair rawEvents (54352, 58171)
      optimizedPairEvents = eventsForPair optimizedEvents (54352, 58171)
  assertBool "raw screen should report the real close approach" (not (null rawPairEvents))
  assertBool "optimized screen should report the real close approach" (not (null optimizedPairEvents))
  let closest = minimumBy (comparing ceMissDistanceKm) optimizedPairEvents
      expectedTca = UTCTime (fromGregorian 2026 6 18) (55 * 60 + 5)
      tcaErrorSeconds = abs (realToFrac (diffUTCTime (ceTca closest) expectedTca) :: Double)
  assertBool
    ("real close approach miss distance should be < 0.2 km, got " <> show (ceMissDistanceKm closest))
    (ceMissDistanceKm closest < 0.2)
  assertBool
    ("real close approach TCA should be within 60 seconds of 2026-06-18 00:55:05, got " <> show (ceTca closest))
    (tcaErrorSeconds <= 60)
  result <- screenValidate realCloseConfig objects
  assertValidationAgree "real close approach" result

testMultipleApproachesPerPair :: IO ()
testMultipleApproachesPerPair = do
  objects <- loadCatalog "multi-approach" multiApproachEntries
  rawEvents <- screenRaw multiApproachConfig objects
  optimizedEvents <- screenOptimized multiApproachConfig objects
  let rawPairEvents = eventsForPair rawEvents (25544, 25545)
      optimizedPairEvents = eventsForPair optimizedEvents (25544, 25545)
      sortedTcas = sort (map ceTca optimizedPairEvents)
      tcaGapsSeconds =
        [ realToFrac (diffUTCTime later earlier) :: Double
        | (earlier, later) <- zip sortedTcas (drop 1 sortedTcas)
        ]
  assertBool
    ("raw screen should report at least two approaches, got " <> show (length rawPairEvents))
    (length rawPairEvents >= 2)
  assertBool
    ("optimized screen should report at least two approaches, got " <> show (length optimizedPairEvents))
    (length optimizedPairEvents >= 2)
  assertBool
    ("all optimized approaches should be under 5 km, got " <> show (map ceMissDistanceKm optimizedPairEvents))
    (all ((< 5.0) . ceMissDistanceKm) optimizedPairEvents)
  assertBool
    ("approach TCAs should be distinct, got " <> show sortedTcas)
    (not (null tcaGapsSeconds) && all (> 60) tcaGapsSeconds)
  result <- screenValidate multiApproachConfig objects
  assertValidationAgree "multi-approach" result

-- | Co-orbital / co-located pairs (near-zero relative speed) are dropped once
-- the relative-speed floor is enabled. Every pair in the ISS fixture cluster
-- shares an orbit, so with the floor active no event survives, and the raw and
-- optimized screens still agree on the (empty) result. This guards against the
-- window-start-pinned "midnight TCA" artifact, which only afflicts these
-- persistently-close pairs.
testCoorbitalSuppressed :: IO ()
testCoorbitalSuppressed = do
  objects <- loadFixture
  result <- screenValidate (fixtureConfig {scMinRelativeSpeedKms = 0.1}) objects
  assertValidationAgree "co-orbital suppression" result
  unless (null (vrOptimized result) && null (vrRaw result)) $
    failTest
      ( "co-orbital pairs should be suppressed under the relative-speed floor, got optimized="
          <> show (map pairKey (vrOptimized result))
          <> " raw="
          <> show (map pairKey (vrRaw result))
      )

-- | A genuine crossing-orbit conjunction (well above the floor) is retained when
-- the floor is enabled, guarding against over-suppression of real approaches.
testGenuineCrossingNotSuppressed :: IO ()
testGenuineCrossingNotSuppressed = do
  objects <- loadCatalog "real close approach" realCloseEntries
  events <- screenOptimized (realCloseConfig {scMinRelativeSpeedKms = 0.1}) objects
  let pairEvents = eventsForPair events (54352, 58171)
  assertBool
    "genuine crossing conjunction should survive the relative-speed floor"
    (not (null pairEvents))
  assertBool
    ( "genuine crossing relative speed should exceed the floor, got "
        <> show (map ceRelativeSpeedKms pairEvents)
    )
    (all ((>= 0.1) . ceRelativeSpeedKms) pairEvents)

-- | With the floor enabled, the co-orbital cluster yields no events regardless
-- of where the screening window starts. Screening the same geometry over more
-- than two orbits at both the midnight boundary and a +6h start shows the
-- reported approaches no longer track the window start (the root-cause artifact).
testSuppressionWindowIndependent :: IO ()
testSuppressionWindowIndependent = do
  objects <- loadFixture
  let baseCfg = fixtureConfig {scWindowHours = 3.5, scMinRelativeSpeedKms = 0.1}
      midnightCfg = baseCfg {scStart = UTCTime (fromGregorian 2008 9 21) 0}
      shiftedCfg = baseCfg {scStart = UTCTime (fromGregorian 2008 9 21) (6 * 3600)}
  midnightEvents <- screenOptimized midnightCfg objects
  shiftedEvents <- screenOptimized shiftedCfg objects
  unless (null midnightEvents) $
    failTest
      ( "co-orbital events should be suppressed at the midnight window start, got "
          <> show (map eventSummary midnightEvents)
      )
  unless (null shiftedEvents) $
    failTest
      ( "co-orbital events should be suppressed at the +6h window start, got "
          <> show (map eventSummary shiftedEvents)
      )

-- Helpers -------------------------------------------------------------------

pairKey :: ConjunctionEvent -> (Int, Int)
pairKey event = (osNoradId (ceObjectA event), osNoradId (ceObjectB event))

eventsForPair :: [ConjunctionEvent] -> (Int, Int) -> [ConjunctionEvent]
eventsForPair events key = filter ((== key) . pairKey) events

expectEvent :: [ConjunctionEvent] -> (Int, Int) -> IO ConjunctionEvent
expectEvent events key =
  case find ((== key) . pairKey) events of
    Just event -> pure event
    Nothing -> failTest ("expected an event for pair " <> show key)

assertValidationAgree :: String -> ValidationResult -> IO ()
assertValidationAgree label result =
  unless (vrAgree result) $
    failTest
      ( label
          <> " raw and optimized disagree: onlyRaw="
          <> show (vrOnlyRaw result)
          <> " onlyOptimized="
          <> show (vrOnlyOptimized result)
          <> " maxMissDiffKm="
          <> show (vrMaxMissDiffKm result)
      )

runTest :: String -> IO () -> IO ()
runTest name action = do
  action
  putStrLn ("ok - " <> name)

assertBool :: String -> Bool -> IO ()
assertBool _ True = pure ()
assertBool message False = failTest message

assertClose :: Double -> String -> Double -> Double -> IO ()
assertClose tolerance label expected actual =
  unless (abs (expected - actual) <= tolerance) $
    failTest (printf "%s: expected %.9f, got %.9f" label expected actual)

failTest :: String -> IO a
failTest message = do
  putStrLn ("FAIL - " <> message)
  exitFailure

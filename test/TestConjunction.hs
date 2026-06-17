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
import Data.List (find, sort)
import Data.Time (UTCTime (UTCTime), fromGregorian)
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

-- Helpers -------------------------------------------------------------------

pairKey :: ConjunctionEvent -> (Int, Int)
pairKey event = (osNoradId (ceObjectA event), osNoradId (ceObjectB event))

expectEvent :: [ConjunctionEvent] -> (Int, Int) -> IO ConjunctionEvent
expectEvent events key =
  case find ((== key) . pairKey) events of
    Just event -> pure event
    Nothing -> failTest ("expected an event for pair " <> show key)

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

{-# LANGUAGE BangPatterns #-}

module Main (main) where

import Control.Monad (foldM, when)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isPrefixOf)
import SGP4
  ( Satellite
  , Sgp4Error
  , StateVector (..)
  , TLE (..)
  , Vec3 (..)
  , initializeFromTLE
  , propagateMany
  )
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import System.Exit (die)
import Text.Printf (printf)
import Text.Read (readMaybe)

defaultIterations :: Int
defaultIterations = 10000

defaultWorkloadPath :: FilePath
defaultWorkloadPath = "bench/workload.tsv"

data WorkItem = WorkItem !String !TLE

data Workload = Workload
  { workloadTimes :: ![Double]
  , workloadItems :: ![WorkItem]
  }

data InitializedItem = InitializedItem !String !Satellite

data BenchmarkMode
  = EndToEnd
  | PropagationOnly

main :: IO ()
main = do
  (iterations, workloadPath, mode) <- parseArgs
  workload <- either die pure . parseWorkload =<< readFile workloadPath
  _ <- runBenchmark mode 1 workload
  start <- getCPUTime
  checksum <- runBenchmark mode iterations workload
  end <- getCPUTime
  let elapsedSeconds = fromIntegral (end - start) / 1.0e12
  printReport mode iterations workload checksum elapsedSeconds

parseArgs :: IO (Int, FilePath, BenchmarkMode)
parseArgs = do
  args <- getArgs
  case args of
    [] -> pure (defaultIterations, defaultWorkloadPath, EndToEnd)
    [rawIterations] -> (,,EndToEnd) <$> parseIterations rawIterations <*> pure defaultWorkloadPath
    [rawIterations, workloadPath] -> (,,EndToEnd) <$> parseIterations rawIterations <*> pure workloadPath
    [rawIterations, workloadPath, rawMode] -> do
      iterations <- parseIterations rawIterations
      mode <- parseMode rawMode
      pure (iterations, workloadPath, mode)
    _ -> die "usage: sgp4-hs-bench [iterations] [workload-path] [end-to-end|propagation-only]"

parseIterations :: String -> IO Int
parseIterations raw =
  case readMaybe raw of
    Just iterations | iterations > 0 -> pure iterations
    _ -> die ("invalid positive iteration count: " <> raw)

parseMode :: String -> IO BenchmarkMode
parseMode "end-to-end" = pure EndToEnd
parseMode "propagation-only" = pure PropagationOnly
parseMode raw = die ("invalid benchmark mode: " <> raw)

parseWorkload :: String -> Either String Workload
parseWorkload content = do
  times <- parseTimesLine content
  items <- traverse parseWorkItem itemLines
  when (null times) (Left "workload has no propagation times")
  when (null items) (Left "workload has no TLE rows")
  pure (Workload times items)
 where
  itemLines =
    [ stripped
    | line <- lines content
    , let stripped = trim line
    , not (null stripped)
    , not ("#" `isPrefixOf` stripped)
    ]

parseTimesLine :: String -> Either String [Double]
parseTimesLine content =
  case [stripped | line <- lines content, let stripped = trim line, "# times_minutes" `isPrefixOf` stripped] of
    [] -> Left "workload is missing '# times_minutes ...' header"
    [line] ->
      case words line of
        "#" : "times_minutes" : rawTimes -> traverse (parseDouble "time") rawTimes
        _ -> Left ("invalid times header: " <> line)
    _ -> Left "workload has multiple times headers"

parseWorkItem :: String -> Either String WorkItem
parseWorkItem line =
  case splitTabs line of
    [name, line1, line2]
      | null name -> Left "workload row has an empty satellite name"
      | otherwise -> pure (WorkItem name (TLE line1 line2))
    _ -> Left ("invalid workload row, expected name<TAB>line1<TAB>line2: " <> line)

parseDouble :: String -> String -> Either String Double
parseDouble label raw =
  case readMaybe raw of
    Just value -> pure value
    Nothing -> Left ("invalid " <> label <> ": " <> raw)

splitTabs :: String -> [String]
splitTabs "" = [""]
splitTabs input =
  case break (== '\t') input of
    (field, '\t' : rest) -> field : splitTabs rest
    (field, _) -> [field]

trim :: String -> String
trim = dropWhile isSpace . dropWhileEnd isSpace

runBenchmark :: BenchmarkMode -> Int -> Workload -> IO Double
runBenchmark EndToEnd iterations workload =
  runIterations iterations (runEndToEndOnce workload)
runBenchmark PropagationOnly iterations workload@(Workload times _) = do
  initializedItems <- initializeWorkload workload
  runIterations iterations (runPropagationOnlyOnce times initializedItems)

runIterations :: Int -> IO Double -> IO Double
runIterations iterations action = go iterations 0.0
 where
  go !remaining !acc
    | remaining <= 0 = pure acc
    | otherwise = do
        checksum <- action
        go (remaining - 1) (acc + checksum)

runEndToEndOnce :: Workload -> IO Double
runEndToEndOnce (Workload times items) = foldM runItem 0.0 items
 where
  runItem !acc (WorkItem name tle) = do
    initialized <- initializeFromTLE tle
    satellite <- expectInitialized name initialized
    accumulateStates name acc times =<< propagateMany satellite times

initializeWorkload :: Workload -> IO [InitializedItem]
initializeWorkload (Workload _ items) = traverse initializeItem items
 where
  initializeItem (WorkItem name tle) = do
    initialized <- initializeFromTLE tle
    satellite <- expectInitialized name initialized
    pure (InitializedItem name satellite)

runPropagationOnlyOnce :: [Double] -> [InitializedItem] -> IO Double
runPropagationOnlyOnce times = foldM runItem 0.0
 where
  runItem !acc (InitializedItem name satellite) =
    accumulateStates name acc times =<< propagateMany satellite times

accumulateStates :: String -> Double -> [Double] -> [Either Sgp4Error StateVector] -> IO Double
accumulateStates name = go
 where
  go !acc [] [] = pure acc
  go !acc (tsince : tsinceRest) (result : resultRest) = do
    state <- expectState name tsince result
    go (acc + stateChecksum state) tsinceRest resultRest
  go _ _ _ = failBenchmark ("propagation result count mismatch for " <> name)

expectInitialized :: String -> Either Sgp4Error Satellite -> IO Satellite
expectInitialized _ (Right satellite) = pure satellite
expectInitialized name (Left err) =
  failBenchmark ("failed to initialize " <> name <> ": " <> show err)

expectState :: String -> Double -> Either Sgp4Error StateVector -> IO StateVector
expectState _ _ (Right state) = pure state
expectState name tsince (Left err) =
  failBenchmark ("failed to propagate " <> name <> " at " <> show tsince <> " minutes: " <> show err)

failBenchmark :: String -> IO a
failBenchmark = ioError . userError

stateChecksum :: StateVector -> Double
stateChecksum (StateVector (Vec3 rx ry rz) (Vec3 vx vy vz) tsince) =
  rx * 1.0e-3
    + ry * 2.0e-3
    + rz * 3.0e-3
    + vx * 5.0e-2
    + vy * 7.0e-2
    + vz * 11.0e-2
    + tsince * 1.0e-6

modeName :: BenchmarkMode -> String
modeName EndToEnd = "end-to-end"
modeName PropagationOnly = "propagation-only"

printReport :: BenchmarkMode -> Int -> Workload -> Double -> Double -> IO ()
printReport mode iterations workload checksum elapsedSeconds = do
  let itemCount = length (workloadItems workload)
      timeCount = length (workloadTimes workload)
      stateVectors = iterations * itemCount * timeCount
      nsPerIteration = elapsedSeconds * 1.0e9 / fromIntegral iterations
      nsPerStateVector = elapsedSeconds * 1.0e9 / fromIntegral stateVectors
  printf "benchmark=%s\n" ("haskell-wrapper-" <> modeName mode)
  printf "iterations=%d\n" iterations
  printf "tle_count=%d\n" itemCount
  printf "times_per_tle=%d\n" timeCount
  printf "state_vectors=%d\n" stateVectors
  printf "checksum=%.12f\n" checksum
  printf "cpu_seconds=%.9f\n" elapsedSeconds
  printf "ns_per_iteration=%.3f\n" nsPerIteration
  printf "ns_per_state_vector=%.3f\n" nsPerStateVector

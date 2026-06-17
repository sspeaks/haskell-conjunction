{-# LANGUAGE OverloadedStrings #-}

module ConjunctionScreen.App (main) where

import ConjunctionScreen.Config
  ( Config (..)
  , ScreenMode (..)
  , parseConfig
  )
import ConjunctionScreen.Database
  ( completeRun
  , hasComputedFor
  , insertEvents
  , insertRun
  , readCatalog
  , runMigrations
  , withDatabase
  )
import Conjunction.Catalog (initCatalog)
import Conjunction.Run
  ( ValidationResult (..)
  , screenOptimized
  , screenRaw
  , screenValidate
  )
import Conjunction.Screen (coarseThresholdKm)
import Conjunction.Types
  ( CatalogObject
  , ConjunctionEvent
  , ScreenConfig (..)
  )
import Control.Exception (SomeException, throwIO, try)
import Data.Time (Day, UTCTime, getCurrentTime, utctDay)
import Database.PostgreSQL.Simple (Connection, withTransaction)
import SGP4 (Sgp4Error)
import System.Exit (exitFailure)

main :: IO ()
main = do
  config <- parseConfig
  now <- getCurrentTime
  let screenCfg = buildScreenConfig config now
      screenDate = utctDay now
  skip <- shouldSkip config screenDate
  if skip
    then putStrLn "skipping; conjunctions already computed today"
    else withDatabase config $ \conn -> do
      runMigrations conn
      catalog <- readCatalog conn
      (objects, initErrors) <- initCatalog catalog
      reportInit (length catalog) (length objects) initErrors
      case cfgMode config of
        ModeValidate -> runValidate config screenCfg objects
        ModeOptimized -> runStore conn config screenCfg objects "optimized" screenOptimized
        ModeRaw -> runStore conn config screenCfg objects "raw" screenRaw

buildScreenConfig :: Config -> UTCTime -> ScreenConfig
buildScreenConfig config now =
  ScreenConfig
    { scStart = now
    , scWindowHours = cfgWindowHours config
    , scStepSeconds = cfgStepSeconds config
    , scThresholdKm = cfgThresholdKm config
    , scCoarseThresholdKm = cfgCoarseThresholdKm config
    , scRelVelMaxKms = cfgRelVelMaxKms config
    , scRefineStepSeconds = cfgRefineStepSeconds config
    }

shouldSkip :: Config -> Day -> IO Bool
shouldSkip config screenDate
  | not (cfgSkipIfComputedToday config) = pure False
  | otherwise = withDatabase config (\conn -> hasComputedFor conn screenDate)

reportInit :: Int -> Int -> [(Int, Sgp4Error)] -> IO ()
reportInit catalogCount objectCount initErrors =
  putStrLn $
    "catalog rows "
      <> show catalogCount
      <> ", initialized "
      <> show objectCount
      <> ", initialization errors "
      <> show (length initErrors)

runStore ::
  Connection ->
  Config ->
  ScreenConfig ->
  [CatalogObject] ->
  String ->
  (ScreenConfig -> [CatalogObject] -> IO [ConjunctionEvent]) ->
  IO ()
runStore conn _ screenCfg objects algorithm screen = do
  let screenDate = utctDay (scStart screenCfg)
      coarse = coarseThresholdKm screenCfg
      objectCount = length objects
  runId <-
    insertRun
      conn
      screenDate
      algorithm
      (scWindowHours screenCfg)
      (scStepSeconds screenCfg)
      (scThresholdKm screenCfg)
      coarse
  result <-
    try $ do
      events <- screen screenCfg objects
      let conjunctionCount = length events
      _ <- withTransaction conn (insertEvents conn runId screenDate events)
      completeRun conn runId "success" objectCount conjunctionCount Nothing
      pure conjunctionCount
  case result of
    Left err -> do
      completeRun conn runId "failed" objectCount 0 (Just (show (err :: SomeException)))
      throwIO err
    Right conjunctionCount ->
      putStrLn (summary algorithm objectCount conjunctionCount)

summary :: String -> Int -> Int -> String
summary algorithm objectCount conjunctionCount =
  "conjunction screen ("
    <> algorithm
    <> ") over "
    <> show objectCount
    <> " objects found "
    <> show conjunctionCount
    <> " conjunctions"

runValidate :: Config -> ScreenConfig -> [CatalogObject] -> IO ()
runValidate config screenCfg objects = do
  let subset = take (cfgValidateLimit config) objects
  putStrLn ("validating raw vs optimized on " <> show (length subset) <> " objects")
  result <- screenValidate screenCfg subset
  putStrLn ("raw conjunctions: " <> show (length (vrRaw result)))
  putStrLn ("optimized conjunctions: " <> show (length (vrOptimized result)))
  putStrLn ("only raw: " <> show (vrOnlyRaw result))
  putStrLn ("only optimized: " <> show (vrOnlyOptimized result))
  putStrLn ("max miss-distance difference (km): " <> show (vrMaxMissDiffKm result))
  if vrAgree result
    then putStrLn "validation passed: raw and optimized agree"
    else do
      putStrLn "validation FAILED: algorithms disagree"
      exitFailure

{-# LANGUAGE OverloadedStrings #-}

module SpaceTrack.App (main) where

import Control.Exception (Exception, SomeException, throwIO, try)
import Data.Int (Int64)
import Database.PostgreSQL.Simple (withTransaction)
import SpaceTrack.Client (fetchCurrentLeoGp)
import SpaceTrack.Config (Config (..), parseConfig)
import SpaceTrack.Database
  ( completeRun
  , deactivateMissing
  , hasSuccessfulRunToday
  , insertRun
  , runMigrations
  , upsertGpRecord
  , withDatabase
  )
import SpaceTrack.Types (GpRecord)

data IngestError
  = EmptyCatalog
  deriving (Eq, Show)

instance Exception IngestError

main :: IO ()
main = do
  config <- parseConfig
  shouldSkip <- shouldSkipIngest config
  if shouldSkip
    then putStrLn "skipping ingest; successful run already recorded today"
    else do
      records <- fetchCurrentLeoGp config
      validateCatalog records
      if cfgDryRun config
        then putStrLn ("validated " <> show (length records) <> " Space-Track GP records")
        else persistCatalog config records

shouldSkipIngest :: Config -> IO Bool
shouldSkipIngest config
  | cfgDryRun config = pure False
  | not (cfgSkipIfSuccessfulToday config) = pure False
  | otherwise =
      withDatabase config hasSuccessfulRunToday

validateCatalog :: [GpRecord] -> IO ()
validateCatalog [] = throwIO EmptyCatalog
validateCatalog _ = pure ()

persistCatalog :: Config -> [GpRecord] -> IO ()
persistCatalog config records =
  withDatabase config $ \conn -> do
    runMigrations conn
    runId <- insertRun conn (cfgQueryUrl config)
    result <-
      try $
        withTransaction conn $ do
          changed <- sum <$> traverse (upsertGpRecord conn runId) records
          deactivated <- deactivateMissing conn runId
          completeRun conn runId "success" (length records) changed deactivated Nothing
          pure (changed, deactivated)
    case result of
      Left err -> do
        completeRun conn runId "failed" (length records) 0 0 (Just (show (err :: SomeException)))
        throwIO err
      Right (changed, deactivated) ->
        putStrLn (summary runId records changed deactivated)

summary :: Int64 -> [GpRecord] -> Int64 -> Int64 -> String
summary runId records changed deactivated =
  "ingest run "
    <> show runId
    <> " processed "
    <> show (length records)
    <> " records, changed "
    <> show changed
    <> " rows, deactivated "
    <> show deactivated
    <> " rows"

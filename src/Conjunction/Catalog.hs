-- | Building an in-memory catalog and the shared absolute-UTC time grid.
module Conjunction.Catalog
  ( initCatalog
  , timeGrid
  , gridStepCount
  ) where

import Conjunction.Types (CatalogObject (..), ScreenConfig (..))
import Data.Time (UTCTime, addUTCTime)
import SGP4 (Sgp4Error, TLE, initializeFromTLE)

-- | Initialize SGP4 records for every catalog entry.
--
-- Returns the successfully initialized objects together with the identifiers
-- and errors of any entries whose elements SGP4 rejected. Failed objects are
-- simply excluded from screening.
initCatalog :: [(Int, Maybe String, TLE)] -> IO ([CatalogObject], [(Int, Sgp4Error)])
initCatalog entries = do
  results <- mapM initOne entries
  pure ([o | Right o <- results], [e | Left e <- results])
 where
  initOne (nid, name, tle) = do
    result <- initializeFromTLE tle
    pure $ case result of
      Left err -> Left (nid, err)
      Right satellite -> Right (CatalogObject nid name satellite)

-- | Number of sampling steps that span the screening window.
--
-- The grid has @gridStepCount cfg + 1@ points covering @[0, window]@ inclusive.
gridStepCount :: ScreenConfig -> Int
gridStepCount cfg = floor (scWindowHours cfg * 3600.0 / scStepSeconds cfg)

-- | Absolute UTC sample times spanning the screening window.
timeGrid :: ScreenConfig -> [UTCTime]
timeGrid cfg =
  [ addUTCTime (realToFrac (fromIntegral k * scStepSeconds cfg)) (scStart cfg)
  | k <- [0 .. gridStepCount cfg]
  ]

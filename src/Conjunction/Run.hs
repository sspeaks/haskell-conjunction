-- | Top-level screening entry points and raw-vs-optimized validation.
module Conjunction.Run
  ( screenRaw
  , screenOptimized
  , ValidationResult (..)
  , screenValidate
  , compareRuns
  ) where

import qualified Conjunction.CMCombo as CMCombo
import qualified Conjunction.Grid as Grid
import Conjunction.Screen (screenWith)
import Conjunction.Types
  ( CatalogObject
  , ConjunctionEvent (..)
  , ObjectState (..)
  , ScreenConfig
  )
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)

type EventKey = (Int, Int, UTCTime)

-- | Screen with the raw all-pairs CM-COMBO algorithm.
screenRaw :: ScreenConfig -> [CatalogObject] -> IO [ConjunctionEvent]
screenRaw = screenWith CMCombo.candidates

-- | Screen with the optimized spatial-hash algorithm (production path).
screenOptimized :: ScreenConfig -> [CatalogObject] -> IO [ConjunctionEvent]
screenOptimized = screenWith Grid.candidates

-- | Outcome of running both algorithms over the same catalog.
data ValidationResult = ValidationResult
  { vrRaw :: ![ConjunctionEvent]
  , vrOptimized :: ![ConjunctionEvent]
  , vrAgree :: !Bool
  -- ^ True when both algorithms detect the same pair/TCAs with matching miss
  -- distances.
  , vrOnlyRaw :: ![EventKey]
  -- ^ NORAD id pair/TCAs detected only by the raw algorithm.
  , vrOnlyOptimized :: ![EventKey]
  -- ^ NORAD id pair/TCAs detected only by the optimized algorithm.
  , vrMaxMissDiffKm :: !Double
  -- ^ Largest miss-distance disagreement across shared pair/TCAs.
  }
  deriving (Eq, Show)

-- | Run both algorithms and compare their results.
screenValidate :: ScreenConfig -> [CatalogObject] -> IO ValidationResult
screenValidate cfg objs = do
  rawEvents <- screenRaw cfg objs
  optimizedEvents <- screenOptimized cfg objs
  pure (compareRuns rawEvents optimizedEvents)

-- | Compare two event lists by pair/TCA membership and miss distance.
compareRuns :: [ConjunctionEvent] -> [ConjunctionEvent] -> ValidationResult
compareRuns rawEvents optimizedEvents =
  ValidationResult
    { vrRaw = rawEvents
    , vrOptimized = optimizedEvents
    , vrAgree = null onlyRaw && null onlyOptimized && maxMissDiff <= missTolerance
    , vrOnlyRaw = onlyRaw
    , vrOnlyOptimized = onlyOptimized
    , vrMaxMissDiffKm = maxMissDiff
    }
 where
  rawMap = eventMap rawEvents
  optimizedMap = eventMap optimizedEvents
  onlyRaw = sort (Map.keys (Map.difference rawMap optimizedMap))
  onlyOptimized = sort (Map.keys (Map.difference optimizedMap rawMap))
  shared = Map.intersectionWith (\a b -> abs (a - b)) rawMap optimizedMap
  maxMissDiff = if Map.null shared then 0.0 else maximum (Map.elems shared)
  missTolerance = 1.0e-6

eventMap :: [ConjunctionEvent] -> Map.Map EventKey Double
eventMap = Map.fromList . map entry
 where
  entry event =
    ( ( osNoradId (ceObjectA event)
      , osNoradId (ceObjectB event)
      , ceTca event
      )
    , ceMissDistanceKm event
    )

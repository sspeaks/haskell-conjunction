-- | Optimized candidate generation: spatial hashing plus a radial-band cull.
--
-- At each time step the present objects are bucketed into a uniform spatial hash
-- whose cell size equals the coarse threshold. Any two objects within the coarse
-- threshold necessarily fall in adjacent cells, so scanning the 3x3x3
-- neighborhood is candidate-complete. A conservative ephemeris radial-band check
-- (the orbital-characteristic prefilter) rejects pairs whose altitude bands
-- cannot come within the coarse threshold over the window. Both refinements are
-- candidate-complete, so this screen emits exactly the same within-coarse
-- samples as the raw all-pairs screen while running in @O(N * T)@.
module Conjunction.Grid
  ( candidates
  ) where

import Conjunction.Screen (Prepared (..), coarseThresholdKm)
import Conjunction.Types (ScreenConfig)
import Data.Array ((!))
import qualified Data.Map.Strict as Map
import Linear.Metric (norm)
import Linear.V3 (V3 (V3))
import Linear.Vector ((^-^))

-- | Per-step within-coarse sampled separations as @(pair, distance, step)@.
--
-- Each time step builds its own spatial hash and emits candidates
-- independently; the per-step lists are returned unconcatenated so the screen
-- can reduce them in bounded parallel chunks.
candidates :: ScreenConfig -> Prepared -> [[((Int, Int), Double, Int)]]
candidates cfg prep =
  [ stepCandidates prep coarse (prepColumns prep ! k) k
  | k <- [0 .. prepSteps prep - 1]
  ]
 where
  coarse = coarseThresholdKm cfg

-- | Spatial-hash candidate generation for a single time step.
stepCandidates ::
  Prepared -> Double -> [(Int, V3 Double)] -> Int -> [((Int, Int), Double, Int)]
stepCandidates prep coarse column k =
  [ ((i, j), dist, k)
  | (i, pI) <- column
  , (j, pJ) <- neighbors cells coarse pI
  , i < j
  , bandOverlap prep coarse i j
  , let dist = norm (pI ^-^ pJ)
  , dist <= coarse
  ]
 where
  cells = buildCells coarse column

type Cell = (Int, Int, Int)

cellOf :: Double -> V3 Double -> Cell
cellOf coarse (V3 x y z) =
  (floor (x / coarse), floor (y / coarse), floor (z / coarse))

buildCells :: Double -> [(Int, V3 Double)] -> Map.Map Cell [(Int, V3 Double)]
buildCells coarse = foldr insertEntry Map.empty
 where
  insertEntry entry@(_, pos) = Map.insertWith (++) (cellOf coarse pos) [entry]

neighbors :: Map.Map Cell [(Int, V3 Double)] -> Double -> V3 Double -> [(Int, V3 Double)]
neighbors cells coarse pos =
  [ entry
  | let (cx, cy, cz) = cellOf coarse pos
  , dx <- [-1, 0, 1]
  , dy <- [-1, 0, 1]
  , dz <- [-1, 0, 1]
  , entry <- Map.findWithDefault [] (cx + dx, cy + dy, cz + dz) cells
  ]

-- | Conservative radial-band overlap test.
--
-- Two objects whose radial bands are farther apart than the coarse threshold
-- can never be within it in three dimensions, so rejecting them removes nothing
-- the raw screen would have kept.
bandOverlap :: Prepared -> Double -> Int -> Int -> Bool
bandOverlap prep coarse i j =
  case (prepRadial prep ! i, prepRadial prep ! j) of
    (Just (lo1, hi1), Just (lo2, hi2)) ->
      not (lo1 - hi2 > coarse || lo2 - hi1 > coarse)
    _ -> False

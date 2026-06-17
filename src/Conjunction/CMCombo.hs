-- | Raw CM-COMBO candidate generation (Healy 1995).
--
-- No prefilter and no spatial structure: at every time step, every present pair
-- is tested with a Cartesian coordinate sieve (cheap per-axis rejects before the
-- full distance). This is @O(N^2 * T)@ and serves as the validation oracle for
-- the optimized screen; it is not intended for full-catalog production runs.
module Conjunction.CMCombo
  ( candidates
  ) where

import Conjunction.Parallel (parConcatSteps)
import Conjunction.Screen
  ( Prepared (..)
  , coarseThresholdKm
  , v3X
  , v3Y
  , v3Z
  )
import Conjunction.Types (ScreenConfig)
import Data.Array ((!))
import Linear.Metric (norm)
import Linear.V3 (V3)
import Linear.Vector ((^-^))

-- | All within-coarse sampled separations as @(pair, distance, step)@.
--
-- Each time step's all-pairs screen is an independent task; the per-step lists
-- are evaluated in parallel, mirroring Healy's distribution of the pairwise
-- comparisons across processors.
candidates :: ScreenConfig -> Prepared -> [((Int, Int), Double, Int)]
candidates cfg prep =
  parConcatSteps
    [ stepCandidates coarse (prepColumns prep ! k) k
    | k <- [0 .. prepSteps prep - 1]
    ]
 where
  coarse = coarseThresholdKm cfg

-- | All-pairs Cartesian sieve for a single time step's present objects.
stepCandidates :: Double -> [(Int, V3 Double)] -> Int -> [((Int, Int), Double, Int)]
stepCandidates coarse column k =
  [ ((i, j), dist, k)
  | ((i, pI), rest) <- selfTails column
  , (j, pJ) <- rest
  , abs (v3X pI - v3X pJ) <= coarse
  , abs (v3Y pI - v3Y pJ) <= coarse
  , abs (v3Z pI - v3Z pJ) <= coarse
  , let dist = norm (pI ^-^ pJ)
  , dist <= coarse
  ]

-- | Each element paired with the elements that follow it.
--
-- Columns are stored in ascending object-index order, so the partner always has
-- the larger index and pairs are generated once in canonical order.
selfTails :: [a] -> [(a, [a])]
selfTails [] = []
selfTails (x : xs) = (x, xs) : selfTails xs

-- | Parallelism helpers for the conjunction screen.
--
-- Healy's CM-COMBO is fundamentally a parallel algorithm: the all-pairs distance
-- comparisons are distributed across processors. These helpers provide the
-- modern equivalents — order-preserving parallel IO for the propagation and
-- refinement phases, and a deterministic parallel strategy for the pure
-- per-time-step pairwise screen. All helpers preserve results exactly, so
-- parallelism never changes the detected conjunctions.
module Conjunction.Parallel
  ( parMapIO
  , parConcatSteps
  ) where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (mapConcurrently)
import Control.DeepSeq (NFData)
import Control.Parallel.Strategies (parList, rdeepseq, withStrategy)

-- | Order-preserving parallel @mapM@ bounded to the capability count.
--
-- The input is split into one contiguous chunk per capability; the chunks run
-- concurrently while each chunk is processed sequentially. Results are returned
-- in input order, so the output is identical to @mapM@. Falls back to plain
-- @mapM@ on a single capability.
parMapIO :: (a -> IO b) -> [a] -> IO [b]
parMapIO f xs = do
  capabilities <- getNumCapabilities
  if capabilities <= 1
    then mapM f xs
    else concat <$> mapConcurrently (mapM f) (chunkInto capabilities xs)

-- | Split a list into at most @n@ contiguous, order-preserving chunks.
chunkInto :: Int -> [a] -> [[a]]
chunkInto n xs
  | n <= 1 = [xs]
  | otherwise = go xs
 where
  size = max 1 ((length xs + n - 1) `div` n)
  go [] = []
  go ys = let (chunk, rest) = splitAt size ys in chunk : go rest

-- | Evaluate a list of per-step result lists in parallel, then concatenate.
--
-- Each inner list is forced to normal form by a spark; this is the pure,
-- deterministic counterpart of distributing the per-time-step pairwise screens
-- across processors.
parConcatSteps :: (NFData b) => [[b]] -> [b]
parConcatSteps = concat . withStrategy (parList rdeepseq)

-- | Parallelism helpers for the conjunction screen.
--
-- Healy's CM-COMBO is fundamentally a parallel algorithm: the all-pairs distance
-- comparisons are distributed across processors. These helpers provide the
-- modern equivalent — order-preserving parallel IO that bounds the number of
-- in-flight chunks to the capability count, used for the propagation and
-- refinement phases and for the chunked candidate reduction. They preserve
-- results exactly, so parallelism never changes the detected conjunctions.
module Conjunction.Parallel
  ( parMapIO
  ) where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (mapConcurrently)

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

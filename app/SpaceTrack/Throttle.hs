{-# LANGUAGE RecordWildCards #-}

module SpaceTrack.Throttle
  ( RateLimiter
  , acquire
  , newRateLimiter
  ) where

import Control.Concurrent (threadDelay)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (uncons)
import Data.Time.Clock
  ( NominalDiffTime
  , UTCTime
  , diffUTCTime
  , getCurrentTime
  )

data RateLimiter = RateLimiter
  { rlCalls :: !(IORef [UTCTime])
  , rlLastCall :: !(IORef (Maybe UTCTime))
  , rlPerMinute :: !Int
  , rlPerHour :: !Int
  , rlMinSpacingSeconds :: !Double
  }

newRateLimiter :: Int -> Int -> Double -> IO RateLimiter
newRateLimiter perMinute perHour minSpacingSeconds = do
  rlCalls <- newIORef []
  rlLastCall <- newIORef Nothing
  pure
    RateLimiter
      { rlCalls
      , rlLastCall
      , rlPerMinute = perMinute
      , rlPerHour = perHour
      , rlMinSpacingSeconds = minSpacingSeconds
      }

acquire :: RateLimiter -> IO ()
acquire limiter@RateLimiter {..} = do
  now <- getCurrentTime
  calls <- pruneOldCalls now <$> readIORef rlCalls
  lastCall <- readIORef rlLastCall
  case waitSeconds now calls lastCall limiter of
    seconds
      | seconds <= 0 -> do
          writeIORef rlCalls (calls <> [now])
          writeIORef rlLastCall (Just now)
      | otherwise -> do
          threadDelay (ceiling (seconds * 1000000))
          acquire limiter

pruneOldCalls :: UTCTime -> [UTCTime] -> [UTCTime]
pruneOldCalls now = filter (\time -> diffUTCTime now time < 3600)

waitSeconds :: UTCTime -> [UTCTime] -> Maybe UTCTime -> RateLimiter -> Double
waitSeconds now calls lastCall RateLimiter {..} =
  maximum [0, minSpacingWait, minuteWait, hourWait]
 where
  minSpacingWait =
    case lastCall of
      Nothing -> 0
      Just time -> rlMinSpacingSeconds - nominalToDouble (diffUTCTime now time)

  minuteCalls = filter (\time -> diffUTCTime now time < 60) calls
  minuteWait =
    case uncons minuteCalls of
      Just (oldest, _) | length minuteCalls >= rlPerMinute -> secondsUntil now 60 oldest
      _ -> 0

  hourWait =
    case uncons calls of
      Just (oldest, _) | length calls >= rlPerHour -> secondsUntil now 3600 oldest
      _ -> 0

secondsUntil :: UTCTime -> NominalDiffTime -> UTCTime -> Double
secondsUntil now window oldest =
  nominalToDouble (window - diffUTCTime now oldest)

nominalToDouble :: NominalDiffTime -> Double
nominalToDouble = realToFrac

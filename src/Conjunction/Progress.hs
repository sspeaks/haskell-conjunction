{-# LANGUAGE BangPatterns #-}

-- | Lightweight, environment-gated progress logging for long screening runs.
--
-- Progress lines are written to stderr (so they reach journald when the screen
-- runs as a systemd service) only when the @CONJUNCTION_PROGRESS@ environment
-- variable is set to a value other than @0@ or the empty string. The screening
-- engine is a library shared with the test suite, so logging stays silent
-- unless a caller opts in; the @conjunction-screen@ executable enables it by
-- default.
module Conjunction.Progress
  ( progressEnabled
  , logInfo
  , withPhase
  , Counter
  , newCounter
  , tick
  , finishCounter
  ) where

import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr)
import Text.Printf (printf)

-- | Whether progress logging is currently enabled, read from the environment.
--
-- Read at each phase or counter boundary rather than cached globally, so a
-- caller that sets the variable before screening always sees it.
progressEnabled :: IO Bool
progressEnabled = do
  v <- lookupEnv "CONJUNCTION_PROGRESS"
  pure $ case v of
    Nothing -> False
    Just s -> s /= "" && s /= "0"

-- | Write a timestamped progress line to stderr and flush it immediately.
logLine :: String -> IO ()
logLine msg = do
  now <- getCurrentTime
  let ts = formatTime defaultTimeLocale "%H:%M:%S" now
  hPutStrLn stderr ("[conjunction " ++ ts ++ "] " ++ msg)
  hFlush stderr

-- | Emit a single progress line when logging is enabled.
logInfo :: String -> IO ()
logInfo msg = do
  enabled <- progressEnabled
  when enabled (logLine msg)

-- | Run an action as a named phase, logging its start and wall-clock duration.
withPhase :: String -> IO a -> IO a
withPhase label action = do
  enabled <- progressEnabled
  if not enabled
    then action
    else do
      start <- getCurrentTime
      logLine (label ++ ": start")
      result <- action
      end <- getCurrentTime
      logLine (printf "%s: done in %.1fs" label (elapsedSeconds start end))
      pure result

-- | A throttled counter for a phase processing a known number of items.
data Counter = Counter
  { cLabel :: !String
  , cTotal :: !Int
  , cRef :: !(IORef Int)
  , cStart :: !UTCTime
  , cStride :: !Int
  , cEnabled :: !Bool
  }

-- | Create a counter for @total@ items, logging an initial 0% line.
--
-- The reporting stride is chosen so progress is logged roughly every 5% (at
-- most ~20 update lines), which keeps the journal readable for both small and
-- very large catalogs.
newCounter :: String -> Int -> IO Counter
newCounter label total = do
  enabled <- progressEnabled
  start <- getCurrentTime
  ref <- newIORef 0
  let stride = max 1 (total `div` 20)
  when enabled (logLine (printf "%s: 0/%d (0%%)" label total))
  pure
    Counter
      { cLabel = label
      , cTotal = total
      , cRef = ref
      , cStart = start
      , cStride = stride
      , cEnabled = enabled
      }

-- | Record one completed item, logging a throttled progress line.
--
-- Safe to call concurrently: the increment is atomic, so each reported count is
-- distinct even when many worker threads tick at once.
tick :: Counter -> IO ()
tick c
  | not (cEnabled c) = pure ()
  | otherwise = do
      !n <- atomicModifyIORef' (cRef c) (\x -> let x' = x + 1 in (x', x'))
      when (n `mod` cStride c == 0 || n == cTotal c) $ do
        now <- getCurrentTime
        let elapsed = elapsedSeconds (cStart c) now
            done = fromIntegral n :: Double
            pct = if cTotal c == 0 then 100 else 100 * done / fromIntegral (cTotal c)
            rate = if elapsed > 0 then done / elapsed else 0
            remaining = fromIntegral (cTotal c - n) :: Double
            eta = if rate > 0 then remaining / rate else 0
        logLine
          ( printf
              "%s: %d/%d (%.0f%%) elapsed %.0fs rate %.0f/s eta %.0fs"
              (cLabel c)
              n
              (cTotal c)
              pct
              elapsed
              rate
              eta
          )

-- | Log a final completion line for a counter.
finishCounter :: Counter -> IO ()
finishCounter c
  | not (cEnabled c) = pure ()
  | otherwise = do
      n <- readIORef (cRef c)
      now <- getCurrentTime
      logLine
        ( printf
            "%s: complete %d/%d in %.1fs"
            (cLabel c)
            n
            (cTotal c)
            (elapsedSeconds (cStart c) now)
        )

elapsedSeconds :: UTCTime -> UTCTime -> Double
elapsedSeconds start end = realToFrac (diffUTCTime end start)

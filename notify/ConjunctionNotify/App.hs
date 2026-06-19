{-# LANGUAGE OverloadedStrings #-}

-- | Orchestration for @conjunction-notify@.
--
-- Reads the current screening run's conjunctions over the look-ahead window,
-- decides which are naked-eye visible from the configured observer
-- ("Conjunction.Visibility"), and publishes one ntfy notification per
-- newly-visible conjunction. A small de-duplication table suppresses repeats
-- across re-runs. Database errors are fatal; a failed individual publish is
-- logged and skipped so one bad event never blocks the rest, mirroring the
-- screener's failure semantics.
module ConjunctionNotify.App (main) where

import Conjunction.Visibility
  ( VisibilityParams (..)
  , VisibleConjunction (..)
  , conjunctionVisibility
  )
import ConjunctionNotify.Config (Config (..), parseConfig, trimSecret)
import ConjunctionNotify.Database
  ( alreadyNotified
  , loadStdMagMap
  , readWindowConjunctions
  , recordNotified
  , runMigrations
  , withDatabase
  )
import ConjunctionNotify.Ntfy
  ( NtfyTarget (..)
  , newNtfyManager
  , publish
  )
import Control.Exception (SomeException, try)
import Control.Monad (forM)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
  ( NominalDiffTime
  , UTCTime
  , addUTCTime
  , defaultTimeLocale
  , diffUTCTime
  , formatTime
  , getCurrentTime
  )
import Database.PostgreSQL.Simple (Connection)
import Network.HTTP.Client (Manager)
import SGP4
  ( GeodeticPosition (GeodeticPosition)
  , Kilometers (Km)
  , Radians (Radians)
  )
import System.IO
  ( BufferMode (LineBuffering)
  , hPutStrLn
  , hSetBuffering
  , hSetEncoding
  , stderr
  , stdout
  , utf8
  )
import Text.Printf (printf)

-- | Outcome of attempting to notify a single visible conjunction.
data Outcome = Sent | Skipped | Failed
  deriving (Eq)

main :: IO ()
main = do
  hSetBuffering stderr LineBuffering
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  config <- parseConfig
  now <- getCurrentTime
  let params = buildParams config
      observer = buildObserver config
      watch = fromMaybe (cfgNtfyTopic config) (cfgWatchLabel config)
      windowEnd = addUTCTime (realToFrac (cfgWindowHours config * 3600.0)) now
  withDatabase config $ \conn -> do
    runMigrations conn
    stdMagMap <- loadStdMagMap conn
    conjunctions <- readWindowConjunctions conn now windowEnd
    let visible =
          mapMaybe
            (conjunctionVisibility params observer (`Map.lookup` stdMagMap))
            conjunctions
    token <- traverse (fmap trimSecret . readFile) (cfgNtfyTokenFile config)
    manager <- if cfgDryRun config then pure Nothing else Just <$> newNtfyManager
    let target = buildTarget config token
    outcomes <-
      forM visible $ \visibleConjunction -> do
        seen <-
          if cfgDryRun config
            then pure False
            else alreadyNotified conn watch (vcId visibleConjunction)
        if seen
          then pure Skipped
          else dispatch conn target manager watch now visibleConjunction
    reportSummary (cfgDryRun config) (length conjunctions) (length visible) outcomes

-- | Publish (or, in dry-run, print) a single newly-visible conjunction.
dispatch ::
  Connection ->
  NtfyTarget ->
  Maybe Manager ->
  String ->
  UTCTime ->
  VisibleConjunction ->
  IO Outcome
dispatch conn target manager watch now visibleConjunction =
  case manager of
    Nothing -> do
      putStrLn ("[dry-run] would notify conjunction " <> show (vcId visibleConjunction))
      putStrLn (indent (T.unpack message))
      pure Sent
    Just activeManager -> do
      result <- try (publish activeManager target message)
      case result of
        Right () -> do
          recordNotified conn watch (vcId visibleConjunction)
          putStrLn
            ( "notified conjunction "
                <> show (vcId visibleConjunction)
                <> ": "
                <> summaryLine visibleConjunction
            )
          pure Sent
        Left err -> do
          hPutStrLn
            stderr
            ( "conjunction-notify: failed to publish conjunction "
                <> show (vcId visibleConjunction)
                <> ": "
                <> show (err :: SomeException)
            )
          pure Failed
 where
  message = buildMessage now visibleConjunction

buildParams :: Config -> VisibilityParams
buildParams config =
  VisibilityParams
    { vpWindowHours = cfgWindowHours config
    , vpMinElevationDeg = cfgMinElevationDeg config
    , vpSunMaxElevationDeg = cfgSunMaxElevationDeg config
    , vpMagnitudeCutoff = cfgMagnitudeCutoff config
    }

buildObserver :: Config -> GeodeticPosition
buildObserver config =
  GeodeticPosition
    (Radians (degToRad (cfgObserverLatDeg config)))
    (Radians (degToRad (cfgObserverLonDeg config)))
    (Km (cfgObserverHeightKm config))

buildTarget :: Config -> Maybe String -> NtfyTarget
buildTarget config token =
  NtfyTarget
    { ntServer = cfgNtfyServer config
    , ntTopic = cfgNtfyTopic config
    , ntTitle = cfgNtfyTitle config
    , ntTags = cfgNtfyTags config
    , ntPriority = cfgNtfyPriority config
    , ntToken = token
    }

-- | The notification body: object pair, absolute time and lead time, peak
-- geometry, and miss distance — consistent with the web panel's fields.
buildMessage :: UTCTime -> VisibleConjunction -> Text
buildMessage now vc =
  T.pack $
    unlines
      [ summaryLine vc
      , formatUtc (vcTca vc) <> " (" <> humanizeLeadTime (diffUTCTime (vcTca vc) now) <> ")"
      , printf
          "Peak %.0f deg elevation %s, mag %.1f"
          (vcPeakElevationDeg vc)
          (compassPoint (vcPeakAzimuthDeg vc))
          (vcPeakMagnitude vc)
      , printf "Miss distance %.2f km" (vcMissDistanceKm vc)
      ]

summaryLine :: VisibleConjunction -> String
summaryLine vc =
  objectLabel (vcAName vc) (vcANoradId vc)
    <> " x "
    <> objectLabel (vcBName vc) (vcBNoradId vc)

objectLabel :: Maybe Text -> Int -> String
objectLabel (Just name) _
  | not (T.null name) = T.unpack name
objectLabel _ noradId = "NORAD " <> show noradId

formatUtc :: UTCTime -> String
formatUtc = formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

-- | Human-friendly lead time from now to TCA.
humanizeLeadTime :: NominalDiffTime -> String
humanizeLeadTime dt
  | totalMinutes <= 0 = "now"
  | hours > 0 = printf "in %dh %02dm" hours minutes
  | otherwise = printf "in %dm" minutes
 where
  totalMinutes = floor (realToFrac dt / 60.0 :: Double) :: Int
  (hours, minutes) = totalMinutes `divMod` 60

-- | 8-point compass direction for an azimuth in degrees (0=N, 90=E), matching
-- the web panel's compass labels (@web/src/components/VisibilityPanel.tsx@).
compassPoint :: Double -> String
compassPoint azimuthDeg = points !! index
 where
  points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
  index = round (azimuthDeg / 45.0) `mod` 8

indent :: String -> String
indent = unlines . map ("  " <>) . lines

reportSummary :: Bool -> Int -> Int -> [Outcome] -> IO ()
reportSummary dryRun windowCount visibleCount outcomes =
  putStrLn $
    printf
      "conjunction-notify: %d in window, %d visible, %s %d, %d already notified, %d failed"
      windowCount
      visibleCount
      (if dryRun then "would notify" else "notified" :: String)
      (count Sent)
      (count Skipped)
      (count Failed)
 where
  count outcome = length (filter (== outcome) outcomes)

degToRad :: Double -> Double
degToRad d = d * pi / 180.0

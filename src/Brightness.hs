{-# LANGUAGE OverloadedStrings #-}

-- | Resolve intrinsic visual brightness for cataloged satellites.
--
-- Standard magnitude here follows the Molczan/Heavens-Above convention: the
-- apparent visual magnitude an object would have at 1000 km range and 50%
-- illumination.
module Brightness
  ( StdMag
  , resolveStdMag
  , brightObjects
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

type StdMag = Double

-- | Well-known bright objects keyed by NORAD catalog id.
brightObjects :: Map Int StdMag
brightObjects =
  Map.fromList
    [ (25544, -1.8) -- ISS (ZARYA)
    , (48274, 0.0) -- CSS (TIANHE) / Tiangong
    , (20580, 2.2) -- HST (Hubble)
    , (53807, 3.5) -- BlueWalker 3
    ]

-- | Resolve standard magnitude from known bright objects, RCS, or catalog
-- classification defaults.
--
-- The RCS-to-magnitude conversion is only an approximate heuristic for ranking
-- naked-eye brightness when no measured standard magnitude is available.
resolveStdMag ::
  Int ->
  Maybe Text ->
  Maybe Double ->
  Maybe Text ->
  Maybe StdMag
resolveStdMag noradId objectType rcsM2 rcsSize =
  case Map.lookup noradId brightObjects of
    Just stdMag -> Just stdMag
    Nothing ->
      case rcsM2 of
        Just rcs | rcs > 0.0 -> Just (3.5 - 2.5 * logBase 10 rcs)
        _ -> Just (defaultStdMag objectType rcsSize)

defaultStdMag :: Maybe Text -> Maybe Text -> StdMag
defaultStdMag objectType rcsSize =
  case normalized <$> rcsSize of
    Just "LARGE" -> largeDefault objectType
    Just "MEDIUM" -> 5.5
    Just "SMALL" -> 7.5
    _ -> objectTypeDefault objectType

largeDefault :: Maybe Text -> StdMag
largeDefault objectType =
  case normalized <$> objectType of
    Just "ROCKET BODY" -> 3.0
    Just "R/B" -> 3.0
    Just "PAYLOAD" -> 4.0
    Just "DEBRIS" -> 4.5
    _ -> 4.0

objectTypeDefault :: Maybe Text -> StdMag
objectTypeDefault objectType =
  case normalized <$> objectType of
    Just "ROCKET BODY" -> 5.0
    Just "R/B" -> 5.0
    Just "PAYLOAD" -> 5.5
    Just "DEBRIS" -> 7.0
    _ -> 8.0

normalized :: Text -> Text
normalized = Text.toUpper . Text.strip

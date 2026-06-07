{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module SpaceTrack.Json (decodeGpRecords) where

import Control.Exception (Exception, throwIO)
import Data.Aeson
  ( FromJSON (parseJSON)
  , Value (..)
  , eitherDecode
  , encode
  , withObject
  , (.:)
  , (.:?)
  )
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (asum)
import Data.Scientific (Scientific, toBoundedInteger, toRealFloat)
import qualified Data.Text as T
import Data.Time
  ( Day
  , UTCTime
  , defaultTimeLocale
  , parseTimeM
  )
import SpaceTrack.Types (GpRecord (..), JsonValue (..))
import Text.Read (readMaybe)

newtype DecodeError = DecodeError String
  deriving (Eq, Show)

instance Exception DecodeError

newtype ParsedGpRecord = ParsedGpRecord GpRecord

decodeGpRecords :: LBS.ByteString -> IO [GpRecord]
decodeGpRecords body =
  case eitherDecode body of
    Left err -> throwIO (DecodeError err)
    Right values ->
      traverse parseRecord values

parseRecord :: Value -> IO GpRecord
parseRecord value =
  case parseEither parseJSON value of
    Left err -> throwIO (DecodeError err)
    Right (ParsedGpRecord record) -> pure record {gpRawJson = JsonValue (encode value)}

instance FromJSON ParsedGpRecord where
  parseJSON value =
    withObject
      "GpRecord"
      ( \object -> do
          gpNoradCatId <- object .: "NORAD_CAT_ID" >>= parseIntValue "NORAD_CAT_ID"
          gpGpId <- object .:? "GP_ID" >>= traverse (parseIntValue "GP_ID")
          gpObjectName <- object .:? "OBJECT_NAME" >>= traverse parseTextValue
          gpObjectId <- object .:? "OBJECT_ID" >>= traverse parseTextValue
          gpObjectType <- object .:? "OBJECT_TYPE" >>= traverse parseTextValue
          gpClassificationType <- object .:? "CLASSIFICATION_TYPE" >>= traverse parseTextValue
          gpEpoch <- object .: "EPOCH" >>= parseUtcValue "EPOCH"
          gpCreationDate <- object .:? "CREATION_DATE" >>= traverse (parseUtcValue "CREATION_DATE")
          gpMeanMotion <- object .: "MEAN_MOTION" >>= parseDoubleValue "MEAN_MOTION"
          gpEccentricity <- object .: "ECCENTRICITY" >>= parseDoubleValue "ECCENTRICITY"
          gpInclinationDeg <- object .: "INCLINATION" >>= parseDoubleValue "INCLINATION"
          gpRaanDeg <- object .:? "RA_OF_ASC_NODE" >>= traverse (parseDoubleValue "RA_OF_ASC_NODE")
          gpArgOfPericenterDeg <- object .:? "ARG_OF_PERICENTER" >>= traverse (parseDoubleValue "ARG_OF_PERICENTER")
          gpMeanAnomalyDeg <- object .:? "MEAN_ANOMALY" >>= traverse (parseDoubleValue "MEAN_ANOMALY")
          gpBstar <- object .:? "BSTAR" >>= traverse (parseDoubleValue "BSTAR")
          gpSemimajorAxisKm <- object .:? "SEMIMAJOR_AXIS" >>= traverse (parseDoubleValue "SEMIMAJOR_AXIS")
          gpPeriodMin <- object .:? "PERIOD" >>= traverse (parseDoubleValue "PERIOD")
          gpApoapsisKm <- object .:? "APOAPSIS" >>= traverse (parseDoubleValue "APOAPSIS")
          gpPeriapsisKm <- object .: "PERIAPSIS" >>= parseDoubleValue "PERIAPSIS"
          gpDecayDate <- object .:? "DECAY_DATE" >>= traverse (parseDayValue "DECAY_DATE")
          gpTleLine0 <- object .:? "TLE_LINE0" >>= traverse parseTextValue
          gpTleLine1 <- object .:? "TLE_LINE1" >>= traverse parseTextValue
          gpTleLine2 <- object .:? "TLE_LINE2" >>= traverse parseTextValue
          ParsedGpRecord <$> validateGpRecord GpRecord {gpRawJson = JsonValue mempty, ..}
      )
      value

validateGpRecord :: GpRecord -> Parser GpRecord
validateGpRecord record
  | gpPeriapsisKm record >= 2000.0 = fail "PERIAPSIS must be below 2000 km"
  | gpDecayDate record /= Nothing = fail "DECAY_DATE must be null for active LEO ingest"
  | gpEccentricity record < 0.0 || gpEccentricity record >= 1.0 = fail "ECCENTRICITY out of range"
  | gpInclinationDeg record < 0.0 || gpInclinationDeg record > 180.0 = fail "INCLINATION out of range"
  | gpMeanMotion record <= 0.0 = fail "MEAN_MOTION must be positive"
  | otherwise = pure record

parseTextValue :: Value -> Parser T.Text
parseTextValue = \case
  String text -> pure text
  Null -> fail "unexpected null"
  other -> fail ("expected text, got " <> show other)

parseIntValue :: String -> Value -> Parser Int
parseIntValue fieldName = \case
  String text ->
    case readMaybe (T.unpack text) of
      Just value -> pure value
      Nothing -> fail ("invalid integer field " <> fieldName)
  Number number ->
    case toBoundedInteger number of
      Just value -> pure value
      Nothing -> fail ("invalid integer field " <> fieldName)
  other -> fail ("expected integer field " <> fieldName <> ", got " <> show other)

parseDoubleValue :: String -> Value -> Parser Double
parseDoubleValue fieldName = \case
  String text ->
    case readMaybe (T.unpack text) of
      Just value -> pure value
      Nothing -> fail ("invalid floating field " <> fieldName)
  Number number -> pure (toRealFloat (number :: Scientific))
  other -> fail ("expected floating field " <> fieldName <> ", got " <> show other)

parseUtcValue :: String -> Value -> Parser UTCTime
parseUtcValue fieldName value = do
  text <- parseTextValue value
  maybe (fail ("invalid UTC field " <> fieldName)) pure (parseUtcText text)

parseDayValue :: String -> Value -> Parser Day
parseDayValue fieldName value = do
  text <- parseTextValue value
  maybe (fail ("invalid date field " <> fieldName)) pure $
    parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack text)

parseUtcText :: T.Text -> Maybe UTCTime
parseUtcText text =
  asum
    [ parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" unpacked
    , parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q" unpacked
    , parseTimeM True defaultTimeLocale "%Y-%m-%d %H:%M:%S%Q" unpacked
    ]
 where
  unpacked = T.unpack text

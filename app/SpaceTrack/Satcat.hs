{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : SpaceTrack.Satcat
Description : Fetch and parse CelesTrak SATCAT brightness data.

Fetches the CelesTrak SATCAT CSV from https://celestrak.org/pub/satcat.csv.
Radar cross section (RCS) coverage is partial, so RCS values are nullable.
-}
module SpaceTrack.Satcat
  ( SatcatBrightness (..)
  , fetchSatcatBrightness
  , parseSatcatCsv
  ) where

import Data.Csv
  ( FromNamedRecord (parseNamedRecord)
  , decodeByName
  , (.:)
  )
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Network.HTTP.Client
  ( httpLbs
  , parseRequest
  , responseBody
  )
import Network.HTTP.Client.TLS (newTlsManager)

data SatcatBrightness = SatcatBrightness
  { sbNoradId :: !Int
  , sbRcsM2 :: !(Maybe Double)
  }
  deriving (Show, Eq)

instance FromNamedRecord SatcatBrightness where
  parseNamedRecord r =
    SatcatBrightness
      <$> r .: "NORAD_CAT_ID"
      <*> r .: "RCS"

parseSatcatCsv :: LBS.ByteString -> Either String [SatcatBrightness]
parseSatcatCsv bytes =
  toList . snd <$> decodeByName bytes

fetchSatcatBrightness :: IO [SatcatBrightness]
fetchSatcatBrightness = do
  manager <- newTlsManager
  request <- parseRequest "https://celestrak.org/pub/satcat.csv"
  response <- httpLbs request manager
  case parseSatcatCsv (responseBody response) of
    Left err -> ioError (userError ("failed to parse CelesTrak SATCAT CSV: " <> err))
    Right rows -> pure rows

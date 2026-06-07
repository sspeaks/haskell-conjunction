{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module SpaceTrack.Types
  ( GpRecord (..)
  , JsonValue (..)
  ) where

import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import Data.Time (Day, UTCTime)

newtype JsonValue = JsonValue {unJsonValue :: LBS.ByteString}
  deriving (Eq, Show)

data GpRecord = GpRecord
  { gpNoradCatId :: !Int
  , gpGpId :: !(Maybe Int)
  , gpObjectName :: !(Maybe T.Text)
  , gpObjectId :: !(Maybe T.Text)
  , gpObjectType :: !(Maybe T.Text)
  , gpClassificationType :: !(Maybe T.Text)
  , gpEpoch :: !UTCTime
  , gpCreationDate :: !(Maybe UTCTime)
  , gpMeanMotion :: !Double
  , gpEccentricity :: !Double
  , gpInclinationDeg :: !Double
  , gpRaanDeg :: !(Maybe Double)
  , gpArgOfPericenterDeg :: !(Maybe Double)
  , gpMeanAnomalyDeg :: !(Maybe Double)
  , gpBstar :: !(Maybe Double)
  , gpSemimajorAxisKm :: !(Maybe Double)
  , gpPeriodMin :: !(Maybe Double)
  , gpApoapsisKm :: !(Maybe Double)
  , gpPeriapsisKm :: !Double
  , gpDecayDate :: !(Maybe Day)
  , gpTleLine0 :: !(Maybe T.Text)
  , gpTleLine1 :: !(Maybe T.Text)
  , gpTleLine2 :: !(Maybe T.Text)
  , gpRawJson :: !JsonValue
  }
  deriving (Eq, Show)

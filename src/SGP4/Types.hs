module SGP4.Types
  ( Satrec
  , Satellite (..)
  , GravConst (..)
  , OpsMode (..)
  , Vec3 (..)
  , StateVector (..)
  , Sgp4Error (..)
  , gravConstToCInt
  , opsModeToCChar
  , sgp4ErrorCode
  , sgp4ErrorFromCode
  ) where

import Foreign.C.String (castCharToCChar)
import Foreign.C.Types (CChar, CInt)
import Foreign.ForeignPtr (ForeignPtr)

data Satrec

newtype Satellite = Satellite {unSatellite :: ForeignPtr Satrec}

data GravConst
  = WGS72Old
  | WGS72
  | WGS84
  deriving (Eq, Show)

data OpsMode
  = AFSPC
  | Improved
  deriving (Eq, Show)

data Vec3 = Vec3
  { vecX :: !Double
  , vecY :: !Double
  , vecZ :: !Double
  }
  deriving (Eq, Show)

data StateVector = StateVector
  { svPosition :: !Vec3
  , svVelocity :: !Vec3
  , svTsinceMinutes :: !Double
  }
  deriving (Eq, Show)

data Sgp4Error
  = MeanElementsOutOfRange
  | MeanMotionNonPositive
  | PerturbedEccentricityOutOfRange
  | SemiLatusRectumNegative
  | SubOrbitalEpoch
  | SatelliteDecayed
  | AllocationFailed
  | BadArgument
  | UnknownSgp4Error !Int
  deriving (Eq, Show)

gravConstToCInt :: GravConst -> CInt
gravConstToCInt WGS72Old = 0
gravConstToCInt WGS72 = 1
gravConstToCInt WGS84 = 2

opsModeToCChar :: OpsMode -> CChar
opsModeToCChar AFSPC = castCharToCChar 'a'
opsModeToCChar Improved = castCharToCChar 'i'

sgp4ErrorCode :: Sgp4Error -> Int
sgp4ErrorCode MeanElementsOutOfRange = 1
sgp4ErrorCode MeanMotionNonPositive = 2
sgp4ErrorCode PerturbedEccentricityOutOfRange = 3
sgp4ErrorCode SemiLatusRectumNegative = 4
sgp4ErrorCode SubOrbitalEpoch = 5
sgp4ErrorCode SatelliteDecayed = 6
sgp4ErrorCode AllocationFailed = -1
sgp4ErrorCode BadArgument = -2
sgp4ErrorCode (UnknownSgp4Error code) = code

sgp4ErrorFromCode :: Int -> Maybe Sgp4Error
sgp4ErrorFromCode 0 = Nothing
sgp4ErrorFromCode 1 = Just MeanElementsOutOfRange
sgp4ErrorFromCode 2 = Just MeanMotionNonPositive
sgp4ErrorFromCode 3 = Just PerturbedEccentricityOutOfRange
sgp4ErrorFromCode 4 = Just SemiLatusRectumNegative
sgp4ErrorFromCode 5 = Just SubOrbitalEpoch
sgp4ErrorFromCode 6 = Just SatelliteDecayed
sgp4ErrorFromCode (-1) = Just AllocationFailed
sgp4ErrorFromCode (-2) = Just BadArgument
sgp4ErrorFromCode code = Just (UnknownSgp4Error code)

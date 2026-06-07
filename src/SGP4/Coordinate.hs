-- | Typed coordinate and unit wrappers used by the higher-level SGP4 utilities.
--
-- The original FFI-facing 'Vec3' and 'StateVector' types stay unchanged for
-- compatibility. The wrappers in this module label units and reference frames
-- while using @linear@ vectors internally for clean transform math.
module SGP4.Coordinate
  ( Kilometers (..)
  , KilometersPerSecond (..)
  , Radians (..)
  , Degrees (..)
  , toRadians
  , toDegrees
  , TEMEPosition (..)
  , TEMEVelocity (..)
  , TEMEState (..)
  , ECEFPosition (..)
  , ECEFVelocity (..)
  , GeodeticPosition (..)
  , ENUVector (..)
  , TopocentricObservation (..)
  , mkTEMEPosition
  , mkTEMEVelocity
  , mkECEFPosition
  , mkECEFVelocity
  , vec3ToV3
  , v3ToVec3
  , temePositionToVec3
  , temeVelocityToVec3
  , ecefPositionToVec3
  , ecefVelocityToVec3
  , fromStateVector
  , toStateVector
  , rangeTEME
  , normTEME
  , dotTEME
  , rangeECEF
  , normECEF
  ) where

import Linear.Metric (dot, norm)
import Linear.V3 (V3 (V3))
import Linear.Vector ((^-^))
import SGP4.Time (MinutesSinceEpoch (MinutesSinceEpoch, getMinutes))
import SGP4.Types (StateVector (StateVector, svPosition, svTsinceMinutes, svVelocity), Vec3 (Vec3))

-- | Distance in kilometers.
newtype Kilometers = Km {getKilometers :: Double}
  deriving (Eq, Ord, Show, Read)

-- | Velocity in kilometers per second.
newtype KilometersPerSecond = KmS {getKilometersPerSecond :: Double}
  deriving (Eq, Ord, Show, Read)

-- | Angle in radians.
newtype Radians = Radians {getRadians :: Double}
  deriving (Eq, Ord, Show, Read)

-- | Angle in degrees.
newtype Degrees = Degrees {getDegrees :: Double}
  deriving (Eq, Ord, Show, Read)

toRadians :: Degrees -> Radians
toRadians (Degrees degrees) = Radians (degrees * pi / 180.0)

toDegrees :: Radians -> Degrees
toDegrees (Radians radians) = Degrees (radians * 180.0 / pi)

-- | SGP4-native TEME position in kilometers.
newtype TEMEPosition = TEMEPosition {getTEMEPosition :: V3 Double}
  deriving (Eq, Show)

-- | SGP4-native TEME velocity in kilometers per second.
newtype TEMEVelocity = TEMEVelocity {getTEMEVelocity :: V3 Double}
  deriving (Eq, Show)

-- | A propagated SGP4 state labelled as TEME with a typed tsince value.
data TEMEState = TEMEState
  { tsPosition :: !TEMEPosition
  , tsVelocity :: !TEMEVelocity
  , tsTsince :: !MinutesSinceEpoch
  }
  deriving (Eq, Show)

-- | Earth-centered, Earth-fixed position in kilometers.
newtype ECEFPosition = ECEFPosition {getECEFPosition :: V3 Double}
  deriving (Eq, Show)

-- | Rotating-frame ECEF velocity in kilometers per second.
newtype ECEFVelocity = ECEFVelocity {getECEFVelocity :: V3 Double}
  deriving (Eq, Show)

-- | WGS84 geodetic latitude, longitude, and ellipsoidal altitude.
data GeodeticPosition = GeodeticPosition
  { gpLatitude :: !Radians
  , gpLongitude :: !Radians
  , gpAltitude :: !Kilometers
  }
  deriving (Eq, Show)

-- | Local East-North-Up vector in kilometers.
newtype ENUVector = ENUVector {getENUVector :: V3 Double}
  deriving (Eq, Show)

-- | Observer-relative range and look-angle quantities.
data TopocentricObservation = TopocentricObservation
  { topoRange :: !Kilometers
  , topoRangeRate :: !KilometersPerSecond
  , topoAzimuth :: !Radians
  , topoElevation :: !Radians
  }
  deriving (Eq, Show)

mkTEMEPosition :: Kilometers -> Kilometers -> Kilometers -> TEMEPosition
mkTEMEPosition (Km x) (Km y) (Km z) = TEMEPosition (V3 x y z)

mkTEMEVelocity :: KilometersPerSecond -> KilometersPerSecond -> KilometersPerSecond -> TEMEVelocity
mkTEMEVelocity (KmS x) (KmS y) (KmS z) = TEMEVelocity (V3 x y z)

mkECEFPosition :: Kilometers -> Kilometers -> Kilometers -> ECEFPosition
mkECEFPosition (Km x) (Km y) (Km z) = ECEFPosition (V3 x y z)

mkECEFVelocity :: KilometersPerSecond -> KilometersPerSecond -> KilometersPerSecond -> ECEFVelocity
mkECEFVelocity (KmS x) (KmS y) (KmS z) = ECEFVelocity (V3 x y z)

vec3ToV3 :: Vec3 -> V3 Double
vec3ToV3 (Vec3 x y z) = V3 x y z

v3ToVec3 :: V3 Double -> Vec3
v3ToVec3 (V3 x y z) = Vec3 x y z

temePositionToVec3 :: TEMEPosition -> Vec3
temePositionToVec3 (TEMEPosition vector) = v3ToVec3 vector

temeVelocityToVec3 :: TEMEVelocity -> Vec3
temeVelocityToVec3 (TEMEVelocity vector) = v3ToVec3 vector

ecefPositionToVec3 :: ECEFPosition -> Vec3
ecefPositionToVec3 (ECEFPosition vector) = v3ToVec3 vector

ecefVelocityToVec3 :: ECEFVelocity -> Vec3
ecefVelocityToVec3 (ECEFVelocity vector) = v3ToVec3 vector

fromStateVector :: StateVector -> TEMEState
fromStateVector state =
  TEMEState
    { tsPosition = TEMEPosition (vec3ToV3 (svPosition state))
    , tsVelocity = TEMEVelocity (vec3ToV3 (svVelocity state))
    , tsTsince = MinutesSinceEpoch (svTsinceMinutes state)
    }

toStateVector :: TEMEState -> StateVector
toStateVector state =
  StateVector
    (temePositionToVec3 (tsPosition state))
    (temeVelocityToVec3 (tsVelocity state))
    (getMinutes (tsTsince state))

rangeTEME :: TEMEPosition -> TEMEPosition -> Kilometers
rangeTEME (TEMEPosition a) (TEMEPosition b) = Km (norm (a ^-^ b))

normTEME :: TEMEPosition -> Kilometers
normTEME (TEMEPosition vector) = Km (norm vector)

dotTEME :: TEMEPosition -> TEMEPosition -> Double
dotTEME (TEMEPosition a) (TEMEPosition b) = dot a b

rangeECEF :: ECEFPosition -> ECEFPosition -> Kilometers
rangeECEF (ECEFPosition a) (ECEFPosition b) = Km (norm (a ^-^ b))

normECEF :: ECEFPosition -> Kilometers
normECEF (ECEFPosition vector) = Km (norm vector)

-- | Frame and geodetic transforms for SGP4 state vectors.
--
-- These are Tier 1 transforms: TEME is rotated to an Earth-fixed frame with
-- Vallado/IAU-1982 GMST, treating UTC as UT1 when callers provide UTC-derived
-- Julian dates. Polar motion, DUT1, and full IAU precession/nutation are future
-- higher-accuracy layers.
module SGP4.Frames
  ( wgs84A
  , wgs84F
  , wgs84B
  , wgs84E2
  , earthAngularVelocity
  , gmstRotation
  , temeToEcef
  , ecefToTeme
  , temeVelocityToEcef
  , ecefVelocityToTeme
  , temeStateToEcef
  , ecefStateToTeme
  , geodeticToEcef
  , ecefToGeodetic
  , ecefDeltaToEnu
  , ecefToEnu
  , topocentricObservation
  ) where

import Linear.Matrix (M33, (!*), transpose)
import Linear.Metric (dot, norm)
import Linear.V3 (V3 (V3), cross)
import Linear.Vector ((^+^), (^-^), (^/))
import SGP4.Coordinate
  ( ECEFPosition (ECEFPosition)
  , ECEFVelocity (ECEFVelocity)
  , ENUVector (ENUVector)
  , GeodeticPosition (GeodeticPosition)
  , Kilometers (Km)
  , KilometersPerSecond (KmS)
  , Radians (Radians)
  , TEMEPosition (TEMEPosition)
  , TEMEState (TEMEState, tsPosition, tsTsince, tsVelocity)
  , TEMEVelocity (TEMEVelocity)
  , TopocentricObservation (..)
  )
import SGP4.Time (GMST (GMST), MinutesSinceEpoch, mod2pi)

wgs84A :: Double
wgs84A = 6378.137

wgs84F :: Double
wgs84F = 1.0 / 298.257223563

wgs84B :: Double
wgs84B = wgs84A * (1.0 - wgs84F)

wgs84E2 :: Double
wgs84E2 = 2.0 * wgs84F - wgs84F * wgs84F

earthAngularVelocity :: Double
earthAngularVelocity = 7.2921150e-5

gmstRotation :: GMST -> M33 Double
gmstRotation (GMST theta) =
  let c = cos theta
      s = sin theta
   in V3
        (V3 c s 0.0)
        (V3 (-s) c 0.0)
        (V3 0.0 0.0 1.0)

-- | Rotate a TEME position into the Earth-fixed frame using GMST.
temeToEcef :: GMST -> TEMEPosition -> ECEFPosition
temeToEcef siderealTime (TEMEPosition position) =
  ECEFPosition (gmstRotation siderealTime !* position)

ecefToTeme :: GMST -> ECEFPosition -> TEMEPosition
ecefToTeme siderealTime (ECEFPosition position) =
  TEMEPosition (transpose (gmstRotation siderealTime) !* position)

-- | Rotate TEME velocity into the rotating ECEF frame.
--
-- The returned velocity includes the @omega x r@ Earth-rotation correction, so
-- a stationary ground point has zero ECEF velocity.
temeVelocityToEcef :: GMST -> TEMEPosition -> TEMEVelocity -> ECEFVelocity
temeVelocityToEcef siderealTime temePosition (TEMEVelocity velocity) =
  let ECEFPosition position = temeToEcef siderealTime temePosition
      rotatedVelocity = gmstRotation siderealTime !* velocity
   in ECEFVelocity (rotatedVelocity ^-^ omegaCross position)

ecefVelocityToTeme :: GMST -> ECEFPosition -> ECEFVelocity -> TEMEVelocity
ecefVelocityToTeme siderealTime (ECEFPosition position) (ECEFVelocity velocity) =
  TEMEVelocity (transpose (gmstRotation siderealTime) !* (velocity ^+^ omegaCross position))

temeStateToEcef :: GMST -> TEMEState -> (ECEFPosition, ECEFVelocity)
temeStateToEcef siderealTime state =
  ( temeToEcef siderealTime (tsPosition state)
  , temeVelocityToEcef siderealTime (tsPosition state) (tsVelocity state)
  )

ecefStateToTeme :: GMST -> MinutesSinceEpoch -> ECEFPosition -> ECEFVelocity -> TEMEState
ecefStateToTeme siderealTime tsince position velocity =
  TEMEState
    { tsPosition = ecefToTeme siderealTime position
    , tsVelocity = ecefVelocityToTeme siderealTime position velocity
    , tsTsince = tsince
    }

-- | Convert WGS84 geodetic coordinates to ECEF kilometers.
geodeticToEcef :: GeodeticPosition -> ECEFPosition
geodeticToEcef (GeodeticPosition (Radians latitude) (Radians longitude) (Km altitude)) =
  let sinLat = sin latitude
      cosLat = cos latitude
      sinLon = sin longitude
      cosLon = cos longitude
      primeVertical = wgs84A / sqrt (1.0 - wgs84E2 * sinLat * sinLat)
   in ECEFPosition
        ( V3
            ((primeVertical + altitude) * cosLat * cosLon)
            ((primeVertical + altitude) * cosLat * sinLon)
            ((primeVertical * (1.0 - wgs84E2) + altitude) * sinLat)
        )

-- | Convert ECEF kilometers to WGS84 geodetic coordinates.
ecefToGeodetic :: ECEFPosition -> GeodeticPosition
ecefToGeodetic (ECEFPosition (V3 x y z))
  | p < 1.0e-12 =
      let latitude = if z < 0.0 then -pi / 2.0 else pi / 2.0
       in GeodeticPosition (Radians latitude) (Radians 0.0) (Km (abs z - wgs84B))
  | otherwise =
      let longitude = atan2 y x
          theta = atan2 (z * wgs84A) (p * wgs84B)
          sinTheta = sin theta
          cosTheta = cos theta
          secondEccentricitySquared = (wgs84A * wgs84A - wgs84B * wgs84B) / (wgs84B * wgs84B)
          latitude =
            atan2
              (z + secondEccentricitySquared * wgs84B * cube sinTheta)
              (p - wgs84E2 * wgs84A * cube cosTheta)
          sinLat = sin latitude
          cosLat = cos latitude
          primeVertical = wgs84A / sqrt (1.0 - wgs84E2 * sinLat * sinLat)
          altitude =
            if abs cosLat > 1.0e-12
              then p / cosLat - primeVertical
              else z / sinLat - primeVertical * (1.0 - wgs84E2)
       in GeodeticPosition (Radians latitude) (Radians longitude) (Km altitude)
 where
  p = sqrt (x * x + y * y)

ecefDeltaToEnu :: GeodeticPosition -> V3 Double -> ENUVector
ecefDeltaToEnu observer delta =
  ENUVector (enuRotation observer !* delta)

ecefToEnu :: GeodeticPosition -> ECEFPosition -> ENUVector
ecefToEnu observer target =
  let ECEFPosition observerPosition = geodeticToEcef observer
      ECEFPosition targetPosition = target
   in ecefDeltaToEnu observer (targetPosition ^-^ observerPosition)

-- | Compute range, range-rate, azimuth, and elevation for a fixed observer.
topocentricObservation :: GeodeticPosition -> ECEFPosition -> ECEFVelocity -> TopocentricObservation
topocentricObservation observer targetPosition targetVelocity =
  let ECEFPosition observerPosition = geodeticToEcef observer
      ECEFPosition satellitePosition = targetPosition
      ECEFVelocity satelliteVelocity = targetVelocity
      delta = satellitePosition ^-^ observerPosition
      range = norm delta
      ENUVector (V3 east north up) = ecefDeltaToEnu observer delta
      horizontalRange = sqrt (east * east + north * north)
      rangeRate =
        if range == 0.0
          then 0.0
          else dot satelliteVelocity (delta ^/ range)
      azimuth = mod2pi (atan2 east north)
      elevation = atan2 up horizontalRange
   in TopocentricObservation
        { topoRange = Km range
        , topoRangeRate = KmS rangeRate
        , topoAzimuth = Radians azimuth
        , topoElevation = Radians elevation
        }

omegaCross :: V3 Double -> V3 Double
omegaCross position = V3 0.0 0.0 earthAngularVelocity `cross` position

enuRotation :: GeodeticPosition -> M33 Double
enuRotation (GeodeticPosition (Radians latitude) (Radians longitude) _) =
  let sinLat = sin latitude
      cosLat = cos latitude
      sinLon = sin longitude
      cosLon = cos longitude
   in V3
        (V3 (-sinLon) cosLon 0.0)
        (V3 (-sinLat * cosLon) (-sinLat * sinLon) cosLat)
        (V3 (cosLat * cosLon) (cosLat * sinLon) sinLat)

cube :: Double -> Double
cube value = value * value * value

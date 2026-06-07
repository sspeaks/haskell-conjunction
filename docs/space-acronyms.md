# Space Time and Frame Acronyms

This guide defines the time scales, epochs, coordinate frames, and Earth models used by the SGP4 time and frame utilities.

## Time scales and epochs

### UTC - Coordinated Universal Time

UTC is the civil time scale used by clocks, timestamps, and TLE epochs. It is based on atomic seconds but occasionally inserts leap seconds so it stays close to Earth-rotation time. Read more: [USNO Universal Time](https://aa.usno.navy.mil/faq/UT), [CelesTrak TLE format](https://celestrak.org/columns/v04n03/).

### UT1 - Universal Time 1

UT1 is an Earth-rotation time scale. Sidereal time and Earth-fixed frame transforms should use UT1 because they depend on the actual rotation angle of the Earth. For Tier 1 TLE workflows this library treats UTC as approximately UT1; high-precision workflows need DUT1 from IERS. Read more: [USNO Universal Time](https://aa.usno.navy.mil/faq/UT), [IERS Earth orientation data](https://datacenter.iers.org/eop.php).

### DUT1 - UT1 minus UTC

DUT1 is the correction in seconds needed to convert UTC to UT1. IERS publishes it in Earth orientation products, and UTC is managed so DUT1 stays within about 0.9 seconds. Read more: [IERS Earth orientation data](https://datacenter.iers.org/eop.php).

### TAI - International Atomic Time

TAI is a continuous atomic time scale with no leap seconds. UTC differs from TAI by the accumulated leap-second offset. Read more: [USNO Universal Time](https://aa.usno.navy.mil/faq/UT), [ERFA time scale routines](https://github.com/liberfa/erfa).

### TT - Terrestrial Time

TT is the time scale used for many precise astronomical models, including precession and nutation. It is exactly 32.184 seconds ahead of TAI. Read more: [IERS Conventions 2010](https://iers-conventions.obspm.fr/content/tn36.pdf), [ERFA `eraTaitt`](https://github.com/liberfa/erfa).

### GPS - Global Positioning System Time

GPS time is a continuous time scale used by GPS. It does not include UTC leap seconds and is defined as TAI minus 19 seconds, so it currently differs from UTC by the leap-second offset minus 19 seconds. Read more: [USNO Universal Time](https://aa.usno.navy.mil/faq/UT).

### JD - Julian Date

Julian Date is a continuous count of days used in astronomy. JD days begin at noon, so midnight UTC has a `.5` fractional part. Read more: [USNO Julian Date formula](https://aa.usno.navy.mil/faq/JD_formula), Vallado's `jday` algorithm in *Fundamentals of Astrodynamics and Applications*.

### MJD - Modified Julian Date

Modified Julian Date is `JD - 2400000.5`, shifting the origin to midnight on 1858-11-17. Haskell's `Day` type is internally an integer MJD. Read more: [USNO Julian Date formula](https://aa.usno.navy.mil/faq/JD_formula), [`time` package `Day`](https://hackage.haskell.org/package/time).

### J2000

J2000.0 is the standard astronomical epoch at JD 2451545.0, corresponding to 2000-01-01 12:00 TT. Julian centuries from J2000 are commonly used in GMST, precession, and nutation formulas. Read more: [USNO Julian Date formula](https://aa.usno.navy.mil/faq/JD_formula), [IERS Conventions 2010](https://iers-conventions.obspm.fr/content/tn36.pdf).

### EOP - Earth Orientation Parameters

EOP are IERS-published values describing Earth's rotation and pole position, including DUT1, polar motion `xp`/`yp`, and length-of-day corrections. They are needed for higher-accuracy fixed-frame transforms. Read more: [IERS Earth orientation data](https://datacenter.iers.org/eop.php).

## Sidereal and rotation terms

### GMST - Greenwich Mean Sidereal Time

GMST is the angle between Greenwich and the mean equinox. SGP4/TEME workflows typically use the Vallado/IAU-1982 GMST formula to rotate TEME into an Earth-fixed frame. Read more: [CelesTrak sidereal time](https://celestrak.org/columns/v02n02/), Vallado's `gstime` algorithm.

### GAST - Greenwich Apparent Sidereal Time

GAST is GMST adjusted by the equation of the equinoxes, accounting for nutation. It is needed for higher-fidelity apparent-equator frame transforms but is not part of the Tier 1 implementation. Read more: [USNO GAST FAQ](https://aa.usno.navy.mil/faq/GAST), [ERFA sidereal time routines](https://github.com/liberfa/erfa).

### ERA - Earth Rotation Angle

ERA is the modern IAU 2000 Earth rotation angle used in CIO-based transformations between celestial and terrestrial frames. It is more appropriate for full IERS transformations than the older GMST polynomial. Read more: [IERS Conventions 2010](https://iers-conventions.obspm.fr/content/tn36.pdf), [ERFA `eraEra00`](https://github.com/liberfa/erfa).

## Reference frames and coordinates

### TEME - True Equator, Mean Equinox

TEME is the frame produced by SGP4. It uses the true equator of date but the mean equinox, making it distinct from modern IAU inertial frames like GCRF. Read more: [CelesTrak FAQ on SGP4 frames](https://celestrak.org/columns/v04n05/), Vallado AIAA 2006-6753.

### ECI - Earth-Centered Inertial

ECI is a family name for Earth-centered frames that do not rotate with Earth. TEME, J2000, and GCRF are all often called ECI in casual use, but they are not identical. Read more: [CelesTrak coordinate systems](https://celestrak.org/columns/v02n01/).

### GCRF - Geocentric Celestial Reference Frame

GCRF is the modern IAU/IERS geocentric inertial frame aligned with the International Celestial Reference System. High-fidelity transformations often go through GCRF before reaching ITRF. Read more: [IERS Conventions 2010](https://iers-conventions.obspm.fr/content/tn36.pdf).

### PEF - Pseudo Earth-Fixed

PEF is an intermediate Earth-fixed-like frame produced by rotating an inertial frame by sidereal time before applying polar motion. In the Tier 1 implementation, TEME rotated by GMST is effectively treated as ECEF/PEF without polar motion. Read more: Vallado, *Fundamentals of Astrodynamics and Applications*.

### ECEF - Earth-Centered, Earth-Fixed

ECEF is a generic term for coordinates centered at Earth and rotating with Earth. It is the natural frame for ground stations, geodetic coordinates, and local topocentric observations. Read more: [CelesTrak geodetic coordinates](https://celestrak.org/columns/v02n03/).

### ITRF - International Terrestrial Reference Frame

ITRF is the high-precision IERS realization of an Earth-fixed frame. It includes polar motion and other Earth orientation effects that are beyond the Tier 1 utilities. Read more: [IERS Conventions 2010](https://iers-conventions.obspm.fr/content/tn36.pdf).

### ENU - East, North, Up

ENU is a local topocentric coordinate frame centered on an observer. It is useful for converting ECEF range vectors into azimuth, elevation, and range. Read more: [CelesTrak topocentric coordinates](https://celestrak.org/columns/v02n02/).

### SEZ - South, East, Zenith

SEZ is another local topocentric frame commonly used in older satellite tracking references. It is equivalent to ENU with North equal to negative South and Up equal to Zenith. Read more: [CelesTrak topocentric coordinates](https://celestrak.org/columns/v02n02/).

### LLA - Latitude, Longitude, Altitude

LLA usually means geodetic latitude, longitude, and ellipsoidal altitude above a reference ellipsoid such as WGS84. Geodetic latitude differs from geocentric latitude because Earth is oblate. Read more: [CelesTrak geodetic coordinates](https://celestrak.org/columns/v02n03/).

## Earth models

### WGS72 - World Geodetic System 1972

WGS72 is the Earth gravity model traditionally used for public TLE/SGP4 propagation. This library keeps WGS72 as the default propagation model through Vallado's implementation. Read more: Vallado AIAA 2006-6753, CelesTrak SGP4 documentation.

### WGS84 - World Geodetic System 1984

WGS84 is the reference ellipsoid commonly used for GPS, ground stations, and geodetic latitude/longitude/altitude. The frame utilities use WGS84 for geodetic/ECEF observer geometry. Read more: [NGA WGS84 resources](https://earth-info.nga.mil/), [CelesTrak geodetic coordinates](https://celestrak.org/columns/v02n03/).

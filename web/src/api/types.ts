// TypeScript shapes mirroring the JSON returned by conjunction-api.

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface Geo {
  lat: number;
  lon: number;
  altKm: number;
}

export interface ObjectState {
  noradId: number;
  name: string | null;
  teme: Vec3; // km
  vel: Vec3; // km/s
  geo: Geo;
}

export interface Conjunction {
  id: number;
  screenDate: string;
  runId: number;
  tca: string; // ISO-8601 UTC
  missDistanceKm: number;
  relativeSpeedKms: number;
  a: ObjectState;
  b: ObjectState;
  midpoint: Geo;
}

export interface Satellite {
  noradId: number;
  name: string | null;
  objectType: string | null;
  rcsM2: number | null; // radar cross section in m^2 (from SATCAT), or null
  rcsSize: string | null; // "SMALL" | "MEDIUM" | "LARGE" or null
  stdMag: number | null; // resolved intrinsic/standard visual magnitude (1000km, 50% illum), or null
  tle1: string;
  tle2: string;
  inclinationDeg: number;
  raanDeg: number | null;
  eccentricity: number;
  meanMotion: number;
  periodMin: number | null;
  apoapsisKm: number | null;
  periapsisKm: number;
  semimajorAxisKm: number | null;
}

export interface Run {
  runId: number;
  screenDate: string;
  algorithm: string;
  startedAt: string;
  finishedAt: string | null;
  status: string;
  windowHours: number;
  stepSeconds: number;
  thresholdKm: number;
  objectCount: number | null;
  conjunctionCount: number | null;
}

/** Observer ground location for visibility prediction. */
export interface ObserverLocation {
  latDeg: number;
  lonDeg: number;
  heightKm: number; // height above ellipsoid in km (default 0)
}

/** User-tunable thresholds for the visibility predictor. */
export interface VisibilityOptions {
  windowHours: number; // prediction window length, default 24
  minElevationDeg: number; // horizon cutoff, default 10
  sunMaxElevationDeg: number; // observer-darkness threshold, default -6 (Sun must be below this)
  magnitudeCutoff: number; // hide passes fainter than this, default 6.5
}

/** One predicted naked-eye-visible satellite pass. */
export interface VisiblePass {
  noradId: number;
  name: string | null;
  riseTime: string; // ISO-8601 UTC
  peakTime: string; // ISO-8601 UTC (time of max elevation)
  setTime: string; // ISO-8601 UTC
  durationSec: number;
  peakElevationDeg: number;
  peakAzimuthDeg: number; // azimuth at peak (deg, 0=N, 90=E)
  minRangeKm: number; // slant range at peak
  peakMagnitude: number; // brightest (smallest) apparent magnitude during the visible portion
  sunlitAtPeak: boolean; // satellite sunlit at peak
  observerDarkAtPeak: boolean;
}

/** A conjunction event that is observable from the observer's location. */
export interface VisibleConjunction {
  conjunctionId: number;
  tca: string; // ISO-8601 UTC
  aNoradId: number;
  bNoradId: number;
  aName: string | null;
  bName: string | null;
  missDistanceKm: number;
  peakElevationDeg: number; // best elevation of the two objects at TCA
  peakMagnitude: number; // best (brightest) of the two objects at TCA
  observerDark: boolean;
}

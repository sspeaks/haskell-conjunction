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

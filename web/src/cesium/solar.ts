import * as satellite from "satellite.js";

const DEG_TO_RAD = Math.PI / 180;
const AU_KM = 149597870.7;

function degToRad(deg: number): number {
  return deg * DEG_TO_RAD;
}

function mod360(deg: number): number {
  return ((deg % 360) + 360) % 360;
}

function julianDate(date: Date): number {
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth() + 1;
  const day = date.getUTCDate();
  const hour = date.getUTCHours();
  const minute = date.getUTCMinutes();
  const second = date.getUTCSeconds() + date.getUTCMilliseconds() / 1000;
  const dayFraction = (hour + minute / 60 + second / 3600) / 24;

  return (
    367 * year -
    Math.floor((7 * (year + Math.floor((month + 9) / 12))) / 4) +
    Math.floor((275 * month) / 9) +
    day +
    1721013.5 +
    dayFraction
  );
}

/**
 * Low-precision Sun position in ECI (~TEME/MOD) kilometres.
 * Vallado/Meeus approximation, about 0.01° accuracy for 1950-2050;
 * dependency-free of Cesium and worker-safe.
 */
export function sunEciKm(date: Date): { x: number; y: number; z: number } {
  const jd = julianDate(date);
  const t = (jd - 2451545.0) / 36525.0;
  const lm = mod360(280.460 + 36000.771 * t);
  const m = mod360(357.5291092 + 35999.05034 * t);
  const mRad = degToRad(m);
  const lam = lm + 1.914666471 * Math.sin(mRad) + 0.019994643 * Math.sin(2 * mRad);
  const eps = 23.439291 - 0.0130042 * t;
  const lamRad = degToRad(lam);
  const epsRad = degToRad(eps);
  const rAU = 1.000140612 - 0.016708617 * Math.cos(mRad) - 0.000139589 * Math.cos(2 * mRad);

  return {
    x: rAU * Math.cos(lamRad) * AU_KM,
    y: rAU * Math.cos(epsRad) * Math.sin(lamRad) * AU_KM,
    z: rAU * Math.sin(epsRad) * Math.sin(lamRad) * AU_KM,
  };
}

/**
 * Sun elevation at an observer in radians, positive above the horizon.
 * Uses the worker-safe ECI (~TEME) Sun vector in km, rotated to ECEF via
 * satellite.js without any Cesium dependency.
 */
export function sunElevationRad(date: Date, latDeg: number, lonDeg: number, heightKm?: number): number {
  const sunEcf = satellite.eciToEcf(sunEciKm(date), satellite.gstime(date));
  const lookAngles = satellite.ecfToLookAngles(
    {
      longitude: degToRad(lonDeg),
      latitude: degToRad(latDeg),
      height: heightKm ?? 0,
    },
    sunEcf,
  );
  return lookAngles.elevation;
}

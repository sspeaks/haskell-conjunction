// Worker-safe visibility math: do not import Cesium from this module.
import * as satellite from "satellite.js";

import type {
  Conjunction,
  ObjectState,
  ObserverLocation,
  Satellite,
  Vec3,
  VisibilityOptions,
  VisibleConjunction,
  VisiblePass,
} from "../api/types";
import { sunEciKm, sunElevationRad } from "./solar";

const EARTH_RADIUS_KM = 6371;
const STEP_MS = 30_000;
const RAD_TO_DEG = 180 / Math.PI;

type Vec3Like = { x: number; y: number; z: number };

function dot(a: Vec3Like, b: Vec3Like): number {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

function sub(a: Vec3Like, b: Vec3Like): Vec3 {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

function norm(v: Vec3Like): number {
  return Math.sqrt(dot(v, v));
}

function normalize(v: Vec3Like): Vec3 {
  const n = norm(v);
  return n > 0 ? scale(v, 1 / n) : { x: 0, y: 0, z: 0 };
}

function scale(v: Vec3Like, s: number): Vec3 {
  return { x: v.x * s, y: v.y * s, z: v.z * s };
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function degToRad(deg: number): number {
  return satellite.degreesToRadians(deg);
}

function azimuthDeg(rad: number): number {
  return ((rad * RAD_TO_DEG) % 360 + 360) % 360;
}

function observerGd(obs: ObserverLocation): satellite.GeodeticLocation {
  return {
    longitude: degToRad(obs.lonDeg),
    latitude: degToRad(obs.latDeg),
    height: obs.heightKm,
  };
}

function parseSatrec(sat: Satellite): satellite.SatRec | null {
  if (!sat.tle1 || !sat.tle2) return null;
  try {
    const rec = satellite.twoline2satrec(sat.tle1, sat.tle2);
    return rec && rec.error === 0 ? rec : null;
  } catch {
    return null;
  }
}

/** Return true when a satellite ECEF position is inside Earth's cylindrical shadow. */
export function isInEarthShadow(satEcfKm: Vec3Like, sunEcfKm: Vec3Like): boolean {
  const antiSun = normalize(scale(sunEcfKm, -1));
  const p = dot(satEcfKm, antiSun);
  if (p <= 0) return false;
  const dPerp = Math.sqrt(Math.max(0, dot(satEcfKm, satEcfKm) - p * p));
  return dPerp < EARTH_RADIUS_KM;
}

/** Compute the phase angle at the satellite between the Sun and observer. */
export function phaseAngleRad(sunEcfKm: Vec3Like, satEcfKm: Vec3Like, obsEcfKm: Vec3Like): number {
  const sunDir = normalize(sub(sunEcfKm, satEcfKm));
  const obsDir = normalize(sub(obsEcfKm, satEcfKm));
  return Math.acos(clamp(dot(sunDir, obsDir), -1, 1));
}

/** Estimate apparent magnitude from standard magnitude, slant range, and phase angle. */
export function apparentMagnitude(stdMag: number, rangeKm: number, phaseRad: number): number {
  const arg = Math.sin(phaseRad) + (Math.PI - phaseRad) * Math.cos(phaseRad);
  if (arg <= 0) return Infinity;
  return stdMag + 5 * Math.log10(rangeKm / 1000) - 2.5 * Math.log10(arg);
}

/** Conservative brightest magnitude estimate for pruning pass candidates. */
export function bestCaseMagnitude(stdMag: number, perigeeKm: number): number {
  return stdMag + 5 * Math.log10(Math.max(perigeeKm, 100) / 1000) - 1.5;
}

/** Predict naked-eye-visible passes for one TLE satellite over the requested time window. */
export function predictPasses(
  sat: Satellite,
  obs: ObserverLocation,
  opts: VisibilityOptions,
  startDate?: Date,
): VisiblePass[] {
  const rec = parseSatrec(sat);
  if (!rec) return [];

  const stdMag = sat.stdMag ?? 8.0;
  const gd = observerGd(obs);
  const obsEcf = satellite.geodeticToEcf(gd);
  const minElevationRad = degToRad(opts.minElevationDeg);
  const sunMaxElevationRad = degToRad(opts.sunMaxElevationDeg);
  const startMs = (startDate ?? new Date()).getTime();
  const endMs = startMs + opts.windowHours * 3_600_000;
  const date = new Date(startMs);
  const passes: VisiblePass[] = [];

  let inPass = false;
  let riseMs = startMs;
  let setMs = startMs;
  let peakMs = startMs;
  let peakElevation = -Infinity;
  let peakAzimuth = 0;
  let peakRange = Infinity;
  let peakSunlit = false;
  let peakDark = false;
  let brightestMagnitude = Infinity;

  const finishPass = (): void => {
    if (!inPass || brightestMagnitude > opts.magnitudeCutoff) {
      inPass = false;
      return;
    }

    passes.push({
      noradId: sat.noradId,
      name: sat.name,
      riseTime: new Date(riseMs).toISOString(),
      peakTime: new Date(peakMs).toISOString(),
      setTime: new Date(setMs).toISOString(),
      durationSec: Math.max(0, (setMs - riseMs) / 1000),
      peakElevationDeg: peakElevation * RAD_TO_DEG,
      peakAzimuthDeg: peakAzimuth,
      minRangeKm: peakRange,
      peakMagnitude: brightestMagnitude,
      sunlitAtPeak: peakSunlit,
      observerDarkAtPeak: peakDark,
    });
    inPass = false;
  };

  for (let t = startMs; t <= endMs; t += STEP_MS) {
    date.setTime(t);
    const pv = satellite.propagate(rec, date);
    const pos = pv?.position;
    if (!pos || typeof pos === "boolean") {
      finishPass();
      continue;
    }

    const gmst = satellite.gstime(date);
    const satEcf = satellite.eciToEcf(pos, gmst);
    const look = satellite.ecfToLookAngles(gd, satEcf);
    const above = look.elevation >= minElevationRad;

    if (!above) {
      finishPass();
      continue;
    }

    const sunEcf = satellite.eciToEcf(sunEciKm(date), gmst);
    const sunlit = !isInEarthShadow(satEcf, sunEcf);
    const observerDark = sunElevationRad(date, obs.latDeg, obs.lonDeg, obs.heightKm) < sunMaxElevationRad;
    const phase = phaseAngleRad(sunEcf, satEcf, obsEcf);
    const mag = sunlit && observerDark ? apparentMagnitude(stdMag, look.rangeSat, phase) : Infinity;

    if (!inPass) {
      inPass = true;
      riseMs = t;
      peakElevation = -Infinity;
      brightestMagnitude = Infinity;
    }

    setMs = t;
    if (look.elevation > peakElevation) {
      peakMs = t;
      peakElevation = look.elevation;
      peakAzimuth = azimuthDeg(look.azimuth);
      peakRange = look.rangeSat;
      peakSunlit = sunlit;
      peakDark = observerDark;
    }
    if (mag < brightestMagnitude) brightestMagnitude = mag;
  }

  finishPass();
  return passes;
}

/** Evaluate whether a conjunction is visible to an observer at TCA. */
export function conjunctionVisibility(
  conj: Conjunction,
  satById: Map<number, Satellite>,
  obs: ObserverLocation,
  opts: VisibilityOptions,
): VisibleConjunction | null {
  const tca = new Date(conj.tca);
  const gd = observerGd(obs);
  const obsEcf = satellite.geodeticToEcf(gd);
  const gmst = satellite.gstime(tca);
  const sunEcf = satellite.eciToEcf(sunEciKm(tca), gmst);
  const minElevationRad = degToRad(opts.minElevationDeg);

  const evaluate = (obj: ObjectState): { elevation: number; sunlit: boolean; mag: number } => {
    const satEcf = satellite.eciToEcf(obj.teme, gmst);
    const look = satellite.ecfToLookAngles(gd, satEcf);
    const sunlit = !isInEarthShadow(satEcf, sunEcf);
    const stdMag = satById.get(obj.noradId)?.stdMag ?? 8.0;
    const phase = phaseAngleRad(sunEcf, satEcf, obsEcf);
    return {
      elevation: look.elevation,
      sunlit,
      mag: sunlit ? apparentMagnitude(stdMag, look.rangeSat, phase) : Infinity,
    };
  };

  const a = evaluate(conj.a);
  const b = evaluate(conj.b);
  const observerDark = sunElevationRad(tca, obs.latDeg, obs.lonDeg, obs.heightKm) < degToRad(opts.sunMaxElevationDeg);
  const peakElevation = Math.max(a.elevation, b.elevation);
  if (!observerDark || peakElevation < minElevationRad || (!a.sunlit && !b.sunlit)) {
    return null;
  }

  return {
    conjunctionId: conj.id,
    tca: conj.tca,
    aNoradId: conj.a.noradId,
    bNoradId: conj.b.noradId,
    aName: conj.a.name,
    bName: conj.b.name,
    missDistanceKm: conj.missDistanceKm,
    peakElevationDeg: peakElevation * RAD_TO_DEG,
    peakMagnitude: Math.min(a.mag, b.mag),
    observerDark: true,
  };
}

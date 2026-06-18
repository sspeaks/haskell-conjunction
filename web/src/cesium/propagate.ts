import * as satellite from "satellite.js";
import {
  Cartesian3,
  ExtrapolationType,
  JulianDate,
  LagrangePolynomialApproximation,
  ReferenceFrame,
  SampledPositionProperty,
} from "cesium";

export type SatRec = satellite.SatRec;

/** Parse a TLE pair into an SGP4 record, or null if it is unusable. */
export function parseTle(tle1: string, tle2: string): SatRec | null {
  try {
    const rec = satellite.twoline2satrec(tle1, tle2);
    // satrec.error is non-zero when the elements are rejected.
    return rec && rec.error === 0 ? rec : null;
  } catch {
    return null;
  }
}

/**
 * Propagate to a JS Date and return an Earth-fixed (ECEF) Cartesian3 in metres,
 * or null on a propagation error / decay. satellite.js returns positions in
 * km in the TEME frame; we rotate to ECEF via GMST and scale to metres, which
 * matches Cesium's default FIXED reference frame.
 */
export function propagateEcef(rec: SatRec, date: Date): Cartesian3 | null {
  const pv = satellite.propagate(rec, date);
  const pos = pv?.position;
  if (!pos || typeof pos === "boolean") return null;
  const gmst = satellite.gstime(date);
  const ecf = satellite.eciToEcf(pos, gmst); // km, ECEF
  if (!Number.isFinite(ecf.x) || !Number.isFinite(ecf.y) || !Number.isFinite(ecf.z)) {
    return null;
  }
  return new Cartesian3(ecf.x * 1000, ecf.y * 1000, ecf.z * 1000);
}

/**
 * Propagate to a JS Date and return an inertial (TEME/ECI) Cartesian3 in
 * metres, or null on a propagation error / decay. Unlike propagateEcef this
 * keeps satellite.js's native TEME frame (no GMST rotation) so callers can
 * render closed orbit geometry in an inertial frame.
 */
export function propagateEciMeters(rec: SatRec, date: Date): Cartesian3 | null {
  const pv = satellite.propagate(rec, date);
  const pos = pv?.position;
  if (!pos || typeof pos === "boolean") return null;
  if (!Number.isFinite(pos.x) || !Number.isFinite(pos.y) || !Number.isFinite(pos.z)) {
    return null;
  }
  return new Cartesian3(pos.x * 1000, pos.y * 1000, pos.z * 1000);
}

/** Geodetic sub-point (degrees + km altitude) at a given date, or null. */
export function propagateGeodetic(
  rec: SatRec,
  date: Date,
): { lonDeg: number; latDeg: number; altKm: number } | null {
  const pv = satellite.propagate(rec, date);
  const pos = pv?.position;
  if (!pos || typeof pos === "boolean") return null;
  const gmst = satellite.gstime(date);
  const gd = satellite.eciToGeodetic(pos, gmst);
  return {
    lonDeg: satellite.degreesLong(gd.longitude),
    latDeg: satellite.degreesLat(gd.latitude),
    altKm: gd.height,
  };
}

/**
 * Build a Cesium SampledPositionProperty in the INERTIAL (TEME) frame, in
 * metres, by propagating a TLE across [startJd, startJd + durationSec] at a
 * fixed step. Cesium rotates inertial samples into the Earth-fixed frame at
 * render time, so orbit-trail paths drawn from this property are not smeared
 * by Earth's rotation. Used for the conjunction theater's orbit trails.
 */
export function buildSampledPosition(
  rec: SatRec,
  startJd: JulianDate,
  durationSec: number,
  stepSec = 10,
): SampledPositionProperty {
  const prop = new SampledPositionProperty(ReferenceFrame.INERTIAL);
  prop.setInterpolationOptions({
    interpolationAlgorithm: LagrangePolynomialApproximation,
    interpolationDegree: 5,
  });
  prop.forwardExtrapolationType = ExtrapolationType.HOLD;
  prop.backwardExtrapolationType = ExtrapolationType.HOLD;

  for (let t = 0; t <= durationSec; t += stepSec) {
    const jd = JulianDate.addSeconds(startJd, t, new JulianDate());
    const pos = propagateEciMeters(rec, JulianDate.toDate(jd));
    if (pos) prop.addSample(jd, pos);
  }
  return prop;
}

/**
 * Sample one full orbital period as inertial (TEME) points in metres, for a
 * closed orbit ring. The returned points are in the TEME frame; the caller
 * rotates them into the Earth-fixed frame at the current time (e.g. via
 * Transforms.computeTemeToPseudoFixedMatrix) so the ring renders as a clean
 * closed circle/ellipse. The first point is appended again at the end to
 * explicitly close the loop.
 */
export function buildOrbitRingPoints(
  rec: SatRec,
  startJd: JulianDate,
  periodSec: number,
  stepSec: number,
): Cartesian3[] {
  const points: Cartesian3[] = [];
  for (let t = 0; t <= periodSec; t += stepSec) {
    const jd = JulianDate.addSeconds(startJd, t, new JulianDate());
    const p = propagateEciMeters(rec, JulianDate.toDate(jd));
    if (p) points.push(p);
  }
  if (points.length > 1) {
    points.push(points[0].clone());
  }
  return points;
}

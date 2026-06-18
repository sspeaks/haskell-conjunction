import * as satellite from "satellite.js";
import {
  Cartesian3,
  ExtrapolationType,
  JulianDate,
  LagrangePolynomialApproximation,
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
 * Build a Cesium SampledPositionProperty (FIXED/ECEF, metres) by propagating a
 * TLE across [startJd, startJd + durationSec] at a fixed step. Used for the
 * conjunction theater's orbit trails.
 */
export function buildSampledPosition(
  rec: SatRec,
  startJd: JulianDate,
  durationSec: number,
  stepSec = 10,
): SampledPositionProperty {
  const prop = new SampledPositionProperty();
  prop.setInterpolationOptions({
    interpolationAlgorithm: LagrangePolynomialApproximation,
    interpolationDegree: 5,
  });
  prop.forwardExtrapolationType = ExtrapolationType.HOLD;
  prop.backwardExtrapolationType = ExtrapolationType.HOLD;

  for (let t = 0; t <= durationSec; t += stepSec) {
    const jd = JulianDate.addSeconds(startJd, t, new JulianDate());
    const pos = propagateEcef(rec, JulianDate.toDate(jd));
    if (pos) prop.addSample(jd, pos);
  }
  return prop;
}

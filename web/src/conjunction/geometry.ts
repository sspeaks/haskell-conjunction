import type { Vec3 } from "../api/types";

// Minimal 3-vector helpers operating on the API's {x,y,z} TEME vectors (km).

const sub = (a: Vec3, b: Vec3): Vec3 => ({ x: a.x - b.x, y: a.y - b.y, z: a.z - b.z });
const dot = (a: Vec3, b: Vec3): number => a.x * b.x + a.y * b.y + a.z * b.z;
const cross = (a: Vec3, b: Vec3): Vec3 => ({
  x: a.y * b.z - a.z * b.y,
  y: a.z * b.x - a.x * b.z,
  z: a.x * b.y - a.y * b.x,
});
const norm = (a: Vec3): number => Math.sqrt(dot(a, a));
const scale = (a: Vec3, s: number): Vec3 => ({ x: a.x * s, y: a.y * s, z: a.z * s });

export interface RTNComponents {
  R: number; // radial (km)
  T: number; // transverse / in-track (km)
  N: number; // normal / cross-track (km)
}

export interface RTNState {
  pos: RTNComponents;
  vel: RTNComponents;
}

/**
 * Relative state of object B with respect to A, expressed in A's RTN/RIC frame.
 * Inputs are TEME position (km) and velocity (km/s). The magnitude of `pos`
 * equals the 3D miss distance, which is a built-in correctness check.
 */
export function computeRTN(rA: Vec3, vA: Vec3, rB: Vec3, vB: Vec3): RTNState {
  const rHat = scale(rA, 1 / norm(rA));
  const h = cross(rA, vA);
  const nHat = scale(h, 1 / norm(h));
  const tHat = cross(nHat, rHat);

  const dr = sub(rB, rA);
  const dv = sub(vB, vA);

  return {
    pos: { R: dot(dr, rHat), T: dot(dr, tHat), N: dot(dr, nHat) },
    vel: { R: dot(dv, rHat), T: dot(dv, tHat), N: dot(dv, nHat) },
  };
}

export interface BPlaneComponents {
  bXi: number; // km
  bEta: number; // km
  relSpeed: number; // km/s
}

/**
 * Project the relative position into the B-plane (perpendicular to the relative
 * velocity at TCA). Without covariance we can only plot the nominal miss point,
 * not a probability ellipse.
 */
export function computeBPlane(rA: Vec3, vA: Vec3, rB: Vec3, vB: Vec3): BPlaneComponents {
  const dv = sub(vB, vA);
  const vHat = scale(dv, 1 / norm(dv));
  const zHat: Vec3 = { x: 0, y: 0, z: 1 };
  const xiRaw = cross(zHat, vHat);
  const xiHat = scale(xiRaw, 1 / norm(xiRaw));
  const etaHat = cross(vHat, xiHat);
  const dr = sub(rB, rA);
  return { bXi: dot(dr, xiHat), bEta: dot(dr, etaHat), relSpeed: norm(dv) };
}

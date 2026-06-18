import { Color } from "cesium";
import type { Satellite } from "../api/types";

export type Regime = "LEO" | "MEO" | "GEO" | "HEO";

export const REGIMES: Regime[] = ["LEO", "MEO", "GEO", "HEO"];

const EARTH_RADIUS_KM = 6371;

// Mean altitude above the spherical Earth radius, derived from the parsed
// orbital elements the API serves (semi-major axis preferred).
export function meanAltitudeKm(sat: Satellite): number {
  if (sat.semimajorAxisKm != null) {
    return sat.semimajorAxisKm - EARTH_RADIUS_KM;
  }
  if (sat.apoapsisKm != null) {
    return (sat.apoapsisKm + sat.periapsisKm) / 2;
  }
  return sat.periapsisKm;
}

export function classifyRegime(sat: Satellite): Regime {
  if (sat.eccentricity > 0.25) return "HEO";
  const alt = meanAltitudeKm(sat);
  if (alt < 2000) return "LEO";
  if (alt < 34000) return "MEO";
  if (alt < 37000) return "GEO";
  return "HEO";
}

export const REGIME_HEX: Record<Regime, string> = {
  LEO: "#22d3ee",
  MEO: "#fbbf24",
  GEO: "#fb923c",
  HEO: "#c084fc",
};

export const REGIME_COLOR: Record<Regime, Color> = {
  LEO: Color.fromCssColorString(REGIME_HEX.LEO),
  MEO: Color.fromCssColorString(REGIME_HEX.MEO),
  GEO: Color.fromCssColorString(REGIME_HEX.GEO),
  HEO: Color.fromCssColorString(REGIME_HEX.HEO),
};

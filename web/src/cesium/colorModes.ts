import { Color } from "cesium";
import type { Satellite } from "../api/types";
import {
  classifyRegime,
  meanAltitudeKm,
  REGIME_COLOR,
  REGIME_HEX,
  REGIMES,
} from "./regime";

export type ColorMode = "regime" | "type" | "altitude";

export const COLOR_MODES: ColorMode[] = ["regime", "type", "altitude"];

export const COLOR_MODE_LABEL: Record<ColorMode, string> = {
  regime: "Orbit regime",
  type: "Object type",
  altitude: "Altitude",
};

export interface LegendItem {
  label: string;
  hex: string;
}

export type TypeCategory = "Payload" | "Rocket body" | "Debris" | "Other";

export const TYPE_HEX: Record<TypeCategory, string> = {
  Payload: "#22c55e",
  "Rocket body": "#f97316",
  Debris: "#94a3b8",
  Other: "#64748b",
};

export const TYPE_CATEGORIES: TypeCategory[] = [
  "Payload",
  "Rocket body",
  "Debris",
  "Other",
];

const ALTITUDE_MIN_KM = 200;
const ALTITUDE_MAX_KM = 2000;

const ALTITUDE_LEGEND_BANDS: LegendItem[] = [
  { label: "~300 km", hex: altitudeHex(300) },
  { label: "~700 km", hex: altitudeHex(700) },
  { label: "~1100 km", hex: altitudeHex(1100) },
  { label: ">1500 km", hex: altitudeHex(1600) },
];

export function typeCategory(sat: Satellite): TypeCategory {
  const objectType = sat.objectType?.toUpperCase() ?? "";
  if (objectType.includes("PAYLOAD")) return "Payload";
  if (objectType.includes("ROCKET")) return "Rocket body";
  if (objectType.includes("DEBRIS")) return "Debris";
  return "Other";
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

function altitudeColor(altitudeKm: number): Color {
  const t = clamp01((altitudeKm - ALTITUDE_MIN_KM) / (ALTITUDE_MAX_KM - ALTITUDE_MIN_KM));
  const hue = 0.5 + t * 0.33;
  return Color.fromHsl(hue, 0.9, 0.55, 1.0);
}

function altitudeHex(altitudeKm: number): string {
  return altitudeColor(altitudeKm).toCssHexString();
}

export function colorFor(sat: Satellite, mode: ColorMode): Color {
  switch (mode) {
    case "regime":
      return REGIME_COLOR[classifyRegime(sat)];
    case "type":
      return Color.fromCssColorString(TYPE_HEX[typeCategory(sat)]);
    case "altitude":
      return altitudeColor(meanAltitudeKm(sat));
  }
}

export function legendFor(mode: ColorMode): LegendItem[] {
  switch (mode) {
    case "regime":
      return REGIMES.map((regime) => ({ label: regime, hex: REGIME_HEX[regime] }));
    case "type":
      return TYPE_CATEGORIES.map((category) => ({ label: category, hex: TYPE_HEX[category] }));
    case "altitude":
      return ALTITUDE_LEGEND_BANDS;
  }
}

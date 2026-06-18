import { Color } from "cesium";

// Space-operations traffic-light scheme for miss distance.
// 5 km matches the screener's default threshold (scThresholdKm).
export function riskHex(missKm: number): string {
  if (missKm < 0.1) return "#ef4444"; // red    — < 100 m
  if (missKm < 1.0) return "#f97316"; // orange — 0.1–1 km
  if (missKm < 5.0) return "#eab308"; // yellow — 1–5 km
  return "#22c55e"; // green — > 5 km
}

export function riskColor(missKm: number): Color {
  return Color.fromCssColorString(riskHex(missKm));
}

export function riskLabel(missKm: number): string {
  if (missKm < 0.1) return "Critical";
  if (missKm < 1.0) return "High";
  if (missKm < 5.0) return "Elevated";
  return "Low";
}

export function formatMiss(missKm: number): string {
  return missKm < 1 ? `${(missKm * 1000).toFixed(0)} m` : `${missKm.toFixed(2)} km`;
}

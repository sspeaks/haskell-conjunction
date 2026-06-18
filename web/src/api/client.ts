import type { Conjunction, Run, Satellite } from "./types";

// In dev, "/api" is proxied to the Haskell server (see vite.config.ts).
// In production the same server serves this bundle, so relative URLs work.
const BASE = import.meta.env.VITE_API_BASE ?? "";

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`);
  if (!res.ok) {
    throw new Error(`${path} responded ${res.status}`);
  }
  return (await res.json()) as T;
}

export const fetchSatellites = () => getJson<Satellite[]>("/api/satellites");

export const fetchConjunctions = (limit = 500, date?: string) =>
  getJson<Conjunction[]>(
    `/api/conjunctions?limit=${limit}${date ? `&date=${encodeURIComponent(date)}` : ""}`,
  );

export const fetchConjunction = (id: number) =>
  getJson<Conjunction>(`/api/conjunctions/${id}`);

export const fetchRuns = () => getJson<Run[]>("/api/runs");

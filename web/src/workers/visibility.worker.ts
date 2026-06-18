/// <reference lib="webworker" />

import type {
  Conjunction,
  ObserverLocation,
  Satellite,
  VisibilityOptions,
  VisibleConjunction,
  VisiblePass,
} from "../api/types";
import { bestCaseMagnitude, conjunctionVisibility, predictPasses } from "../cesium/visibility";

export interface VisibilityRequest {
  observer: ObserverLocation;
  options: VisibilityOptions;
  satellites: Satellite[];
  conjunctions: Conjunction[];
}

export interface VisibilityResponse {
  passes: VisiblePass[];
  conjunctions: VisibleConjunction[];
}

const ctx = self as unknown as DedicatedWorkerGlobalScope;

ctx.onmessage = (e: MessageEvent<VisibilityRequest>): void => {
  try {
    const request = e.data;
    const { observer, options, satellites } = request;
    const satById = new Map(satellites.map((sat) => [sat.noradId, sat]));
    const candidates = satellites.filter(
      (sat) => bestCaseMagnitude(sat.stdMag ?? 8.0, sat.periapsisKm) <= options.magnitudeCutoff,
    );

    const passes = candidates
      .flatMap((sat) => predictPasses(sat, observer, options))
      .sort((a, b) => a.peakMagnitude - b.peakMagnitude)
      .slice(0, 200);

    const conjunctions = request.conjunctions
      .map((conjunction) => conjunctionVisibility(conjunction, satById, observer, options))
      .filter((conjunction): conjunction is VisibleConjunction => conjunction !== null)
      .sort((a, b) => a.peakMagnitude - b.peakMagnitude)
      .slice(0, 100);

    ctx.postMessage({ passes, conjunctions } satisfies VisibilityResponse);
  } catch (error) {
    console.error("Visibility worker failed", error);
    ctx.postMessage({ passes: [], conjunctions: [] } satisfies VisibilityResponse);
  }
};

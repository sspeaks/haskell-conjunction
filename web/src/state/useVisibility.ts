import { useEffect, useRef } from "react";
import { useStore } from "./store";
import type { VisibilityRequest, VisibilityResponse } from "../workers/visibility.worker";

export function useVisibility(): void {
  const observerLocation = useStore((s) => s.observerLocation);
  const visibilityOptions = useStore((s) => s.visibilityOptions);
  const satellites = useStore((s) => s.satellites);
  const conjunctions = useStore((s) => s.conjunctions);
  const setVisibilityResults = useStore((s) => s.setVisibilityResults);
  const setVisibilityLoading = useStore((s) => s.setVisibilityLoading);

  const workerRef = useRef<Worker | null>(null);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const latestRequestIdRef = useRef(0);
  const pendingRequestIdsRef = useRef<number[]>([]);

  useEffect(() => {
    const worker = new Worker(new URL("../workers/visibility.worker.ts", import.meta.url), {
      type: "module",
    });
    workerRef.current = worker;

    worker.onmessage = (event: MessageEvent<VisibilityResponse>): void => {
      const completedRequestId = pendingRequestIdsRef.current.shift();
      if (completedRequestId !== latestRequestIdRef.current) {
        return;
      }

      const response = event.data;
      setVisibilityResults(response.passes, response.conjunctions);
    };

    worker.onerror = (): void => {
      latestRequestIdRef.current += 1;
      pendingRequestIdsRef.current = [];
      setVisibilityResults([], []);
    };

    return () => {
      if (timeoutRef.current !== null) {
        clearTimeout(timeoutRef.current);
        timeoutRef.current = null;
      }
      latestRequestIdRef.current += 1;
      pendingRequestIdsRef.current = [];
      worker.onmessage = null;
      worker.onerror = null;
      worker.terminate();
      workerRef.current = null;
    };
  }, []);

  useEffect(() => {
    if (timeoutRef.current !== null) {
      clearTimeout(timeoutRef.current);
      timeoutRef.current = null;
    }

    if (observerLocation === null || satellites.length === 0) {
      latestRequestIdRef.current += 1;
      setVisibilityResults([], []);
      return;
    }

    timeoutRef.current = setTimeout(() => {
      const worker = workerRef.current;
      if (worker === null) {
        return;
      }

      const now = Date.now();
      const windowEnd = now + visibilityOptions.windowHours * 3_600_000;
      const windowedConjunctions = conjunctions.filter((conjunction) => {
        const tca = new Date(conjunction.tca).getTime();
        return tca >= now && tca <= windowEnd;
      });
      const requestId = latestRequestIdRef.current + 1;
      latestRequestIdRef.current = requestId;
      pendingRequestIdsRef.current.push(requestId);

      setVisibilityLoading(true);
      worker.postMessage({
        observer: observerLocation,
        options: visibilityOptions,
        satellites,
        conjunctions: windowedConjunctions,
      } satisfies VisibilityRequest);
      timeoutRef.current = null;
    }, 300);

    return () => {
      if (timeoutRef.current !== null) {
        clearTimeout(timeoutRef.current);
        timeoutRef.current = null;
      }
    };
  }, [
    observerLocation,
    visibilityOptions,
    satellites,
    conjunctions,
    setVisibilityResults,
    setVisibilityLoading,
  ]);
}

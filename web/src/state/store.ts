import { create } from "zustand";
import type {
  Conjunction,
  ObserverLocation,
  Run,
  Satellite,
  VisibilityOptions,
  VisibleConjunction,
  VisiblePass,
} from "../api/types";
import type { Regime } from "../cesium/regime";
import { REGIMES } from "../cesium/regime";
import type { ColorMode } from "../cesium/colorModes";
import type { ShellName } from "../cesium/AltitudeShells";

interface AppState {
  satellites: Satellite[];
  satById: Map<number, Satellite>;
  conjunctions: Conjunction[];
  runs: Run[];
  loading: boolean;
  error: string | null;

  selectedSat: Satellite | null;
  selectedConjunction: Conjunction | null;
  visibleRegimes: Record<Regime, boolean>;
  showAnalytics: boolean;
  colorMode: ColorMode;
  shellVisibility: Record<ShellName, boolean>;
  inertialMode: boolean;

  // Visibility feature
  observerLocation: ObserverLocation | null;
  visibilityOptions: VisibilityOptions;
  visiblePasses: VisiblePass[];
  visibleConjunctions: VisibleConjunction[];
  selectedPass: VisiblePass | null;
  visibilityLoading: boolean;
  pickingObserver: boolean;

  setData: (sats: Satellite[], conjs: Conjunction[], runs: Run[]) => void;
  setLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  selectSat: (sat: Satellite | null) => void;
  selectConjunction: (conj: Conjunction | null) => void;
  toggleRegime: (regime: Regime) => void;
  toggleAnalytics: () => void;
  setColorMode: (mode: ColorMode) => void;
  toggleShell: (shell: ShellName) => void;
  toggleInertial: () => void;
  setObserverLocation: (loc: ObserverLocation | null) => void;
  setVisibilityOptions: (opts: Partial<VisibilityOptions>) => void;
  setVisibilityResults: (passes: VisiblePass[], conjunctions: VisibleConjunction[]) => void;
  setVisibilityLoading: (loading: boolean) => void;
  selectPass: (pass: VisiblePass | null) => void;
  setPickingObserver: (picking: boolean) => void;
}

const allRegimesVisible = Object.fromEntries(
  REGIMES.map((r) => [r, true]),
) as Record<Regime, boolean>;

const loadObserver = (): ObserverLocation | null => {
  if (typeof localStorage === "undefined") {
    return null;
  }

  try {
    const raw = localStorage.getItem("observerLocation");
    if (!raw) {
      return null;
    }

    const parsed = JSON.parse(raw) as Partial<ObserverLocation>;
    if (
      typeof parsed.latDeg === "number" &&
      typeof parsed.lonDeg === "number" &&
      typeof parsed.heightKm === "number"
    ) {
      return {
        latDeg: parsed.latDeg,
        lonDeg: parsed.lonDeg,
        heightKm: parsed.heightKm,
      };
    }
  } catch {
    return null;
  }

  return null;
};

export const useStore = create<AppState>((set) => ({
  satellites: [],
  satById: new Map(),
  conjunctions: [],
  runs: [],
  loading: true,
  error: null,

  selectedSat: null,
  selectedConjunction: null,
  visibleRegimes: allRegimesVisible,
  showAnalytics: false,
  colorMode: "regime",
  shellVisibility: { LEO: false, MEO: false, GEO: false },
  inertialMode: false,

  // Visibility feature
  observerLocation: loadObserver(),
  visibilityOptions: {
    windowHours: 24,
    minElevationDeg: 10,
    sunMaxElevationDeg: -6,
    magnitudeCutoff: 6.5,
  },
  visiblePasses: [],
  visibleConjunctions: [],
  selectedPass: null,
  visibilityLoading: false,
  pickingObserver: false,

  setData: (satellites, conjunctions, runs) =>
    set({
      satellites,
      satById: new Map(satellites.map((s) => [s.noradId, s])),
      conjunctions,
      runs,
      loading: false,
      error: null,
    }),
  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error, loading: false }),
  selectSat: (selectedSat) => set({ selectedSat }),
  selectConjunction: (selectedConjunction) => set({ selectedConjunction, selectedPass: null }),
  toggleRegime: (regime) =>
    set((s) => ({
      visibleRegimes: { ...s.visibleRegimes, [regime]: !s.visibleRegimes[regime] },
    })),
  toggleAnalytics: () => set((s) => ({ showAnalytics: !s.showAnalytics })),
  setColorMode: (colorMode) => set({ colorMode }),
  toggleShell: (shell) =>
    set((s) => ({
      shellVisibility: { ...s.shellVisibility, [shell]: !s.shellVisibility[shell] },
    })),
  toggleInertial: () => set((s) => ({ inertialMode: !s.inertialMode })),
  setObserverLocation: (observerLocation) => {
    if (typeof localStorage !== "undefined") {
      if (observerLocation) {
        localStorage.setItem("observerLocation", JSON.stringify(observerLocation));
      } else {
        localStorage.removeItem("observerLocation");
      }
    }
    set({ observerLocation });
  },
  setVisibilityOptions: (opts) =>
    set((s) => ({ visibilityOptions: { ...s.visibilityOptions, ...opts } })),
  setVisibilityResults: (visiblePasses, visibleConjunctions) =>
    set({ visiblePasses, visibleConjunctions, visibilityLoading: false }),
  setVisibilityLoading: (visibilityLoading) => set({ visibilityLoading }),
  selectPass: (selectedPass) => set({ selectedPass, selectedConjunction: null }),
  setPickingObserver: (pickingObserver) => set({ pickingObserver }),
}));

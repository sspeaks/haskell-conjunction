import { create } from "zustand";
import type { Conjunction, Run, Satellite } from "../api/types";
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
}

const allRegimesVisible = Object.fromEntries(
  REGIMES.map((r) => [r, true]),
) as Record<Regime, boolean>;

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
  selectConjunction: (selectedConjunction) => set({ selectedConjunction }),
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
}));

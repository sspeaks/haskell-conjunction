import { useEffect } from "react";
import CesiumGlobe from "./components/CesiumGlobe";
import Sidebar from "./components/Sidebar";
import InfoPanel from "./components/InfoPanel";
import ConjunctionList from "./components/ConjunctionList";
import EncounterInset from "./components/EncounterInset";
import Analytics from "./components/Analytics";
import { useStore } from "./state/store";
import { fetchConjunctions, fetchRuns, fetchSatellites } from "./api/client";

export default function App() {
  const setData = useStore((s) => s.setData);
  const setLoading = useStore((s) => s.setLoading);
  const setError = useStore((s) => s.setError);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setLoading(true);
        const [sats, conjs, runs] = await Promise.all([
          fetchSatellites(),
          fetchConjunctions(2000),
          fetchRuns(),
        ]);
        if (!cancelled) setData(sats, conjs, runs);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [setData, setLoading, setError]);

  return (
    <div className="app">
      <CesiumGlobe />
      <Sidebar />
      <ConjunctionList />
      <InfoPanel />
      <EncounterInset />
      <Analytics />
    </div>
  );
}

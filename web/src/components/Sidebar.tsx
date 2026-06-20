import { useMemo } from "react";
import { useStore } from "../state/store";
import { classifyRegime, REGIME_HEX, REGIMES, type Regime } from "../cesium/regime";
import {
  COLOR_MODES,
  COLOR_MODE_LABEL,
  legendFor,
  typeCategory,
  TYPE_CATEGORIES,
  TYPE_HEX,
  type TypeCategory,
} from "../cesium/colorModes";
import { SHELL_HEX, SHELL_NAMES } from "../cesium/AltitudeShells";

export default function Sidebar() {
  const satellites = useStore((s) => s.satellites);
  const conjunctions = useStore((s) => s.conjunctions);
  const runs = useStore((s) => s.runs);
  const loading = useStore((s) => s.loading);
  const error = useStore((s) => s.error);
  const visibleRegimes = useStore((s) => s.visibleRegimes);
  const toggleRegime = useStore((s) => s.toggleRegime);
  const visibleTypes = useStore((s) => s.visibleTypes);
  const toggleType = useStore((s) => s.toggleType);
  const colorMode = useStore((s) => s.colorMode);
  const setColorMode = useStore((s) => s.setColorMode);
  const shellVisibility = useStore((s) => s.shellVisibility);
  const toggleShell = useStore((s) => s.toggleShell);
  const inertialMode = useStore((s) => s.inertialMode);
  const toggleInertial = useStore((s) => s.toggleInertial);

  const counts = useMemo(() => {
    const c: Record<Regime, number> = { LEO: 0, MEO: 0, GEO: 0, HEO: 0 };
    for (const s of satellites) c[classifyRegime(s)]++;
    return c;
  }, [satellites]);

  const typeCounts = useMemo(() => {
    const c: Record<TypeCategory, number> = {
      Payload: 0,
      "Rocket body": 0,
      Debris: 0,
      Other: 0,
    };
    for (const s of satellites) c[typeCategory(s)]++;
    return c;
  }, [satellites]);

  const latestRun = runs.find((r) => r.status === "success") ?? runs[0];

  return (
    <div className="sidebar">
      <h1>Conjunction Visualizer</h1>

      {loading && <p className="muted">Loading catalog…</p>}
      {error && <p className="error">Error: {error}</p>}

      {!loading && !error && (
        <>
          <section>
            <h2>Catalog</h2>
            <p className="muted">
              {satellites.length.toLocaleString()} objects ·{" "}
              {conjunctions.length.toLocaleString()} conjunctions
            </p>
          </section>

          <section>
            <h2>Color by</h2>
            <select
              className="color-select"
              value={colorMode}
              onChange={(e) => setColorMode(e.target.value as typeof colorMode)}
            >
              {COLOR_MODES.map((m) => (
                <option key={m} value={m}>
                  {COLOR_MODE_LABEL[m]}
                </option>
              ))}
            </select>
            <ul className="legend compact">
              {legendFor(colorMode).map((item) => (
                <li key={item.label}>
                  <span className="swatch" style={{ background: item.hex }} />
                  <span className="regime-name">{item.label}</span>
                </li>
              ))}
            </ul>
          </section>

          <section>
            <h2>Filter regimes</h2>
            <ul className="legend">
              {REGIMES.map((r) => (
                <li key={r}>
                  <label>
                    <input
                      type="checkbox"
                      checked={visibleRegimes[r]}
                      onChange={() => toggleRegime(r)}
                    />
                    <span className="swatch" style={{ background: REGIME_HEX[r] }} />
                    <span className="regime-name">{r}</span>
                    <span className="count">{counts[r].toLocaleString()}</span>
                  </label>
                </li>
              ))}
            </ul>
          </section>

          <section>
            <h2>Filter types</h2>
            <ul className="legend">
              {TYPE_CATEGORIES.map((t) => (
                <li key={t}>
                  <label>
                    <input
                      type="checkbox"
                      checked={visibleTypes[t]}
                      onChange={() => toggleType(t)}
                    />
                    <span className="swatch" style={{ background: TYPE_HEX[t] }} />
                    <span className="regime-name">{t}</span>
                    <span className="count">{typeCounts[t].toLocaleString()}</span>
                  </label>
                </li>
              ))}
            </ul>
          </section>

          <section>
            <h2>Overlays</h2>
            <ul className="legend">
              {SHELL_NAMES.map((name) => (
                <li key={name}>
                  <label>
                    <input
                      type="checkbox"
                      checked={shellVisibility[name]}
                      onChange={() => toggleShell(name)}
                    />
                    <span className="swatch ring" style={{ borderColor: SHELL_HEX[name] }} />
                    <span className="regime-name">{name} shell</span>
                  </label>
                </li>
              ))}
              <li>
                <label>
                  <input type="checkbox" checked={inertialMode} onChange={toggleInertial} />
                  <span className="regime-name">Inertial frame (orbit rings)</span>
                </label>
              </li>
            </ul>
          </section>

          {latestRun && (
            <section>
              <h2>Latest screen</h2>
              <p className="muted">
                {latestRun.screenDate} · {latestRun.status}
                <br />
                {(latestRun.conjunctionCount ?? 0).toLocaleString()} events ·{" "}
                {latestRun.thresholdKm} km threshold
              </p>
            </section>
          )}
        </>
      )}

      <p className="hint">Click a point to inspect · drag to rotate · scroll to zoom</p>
    </div>
  );
}

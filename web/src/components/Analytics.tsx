import { useMemo } from "react";
import {
  Bar,
  BarChart,
  Cell,
  CartesianGrid,
  ResponsiveContainer,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
  ZAxis,
} from "recharts";
import { useStore } from "../state/store";
import { formatMiss, riskHex } from "../conjunction/risk";
import type { Conjunction } from "../api/types";

const MISS_BINS = [
  { label: "<100m", min: 0, max: 0.1, color: "#ef4444" },
  { label: "0.1–1km", min: 0.1, max: 1, color: "#f97316" },
  { label: "1–2km", min: 1, max: 2, color: "#eab308" },
  { label: "2–5km", min: 2, max: 5, color: "#22c55e" },
];

const SHELLS = [
  { label: "<400", min: 0, max: 400 },
  { label: "400–600", min: 400, max: 600 },
  { label: "600–800", min: 600, max: 800 },
  { label: "800–1000", min: 800, max: 1000 },
  { label: "1000–1500", min: 1000, max: 1500 },
  { label: ">1500", min: 1500, max: 1e9 },
];

const axisTick = { fill: "#94a3b8", fontSize: 10 };
const tooltipStyle = {
  background: "#0f172a",
  border: "1px solid #334155",
  borderRadius: 6,
  fontSize: 12,
};

export default function Analytics() {
  const show = useStore((s) => s.showAnalytics);
  const toggle = useStore((s) => s.toggleAnalytics);
  const conjunctions = useStore((s) => s.conjunctions);
  const selectConjunction = useStore((s) => s.selectConjunction);

  const histogram = useMemo(
    () =>
      MISS_BINS.map((b) => ({
        label: b.label,
        color: b.color,
        count: conjunctions.filter((c) => c.missDistanceKm >= b.min && c.missDistanceKm < b.max)
          .length,
      })),
    [conjunctions],
  );

  const shellData = useMemo(
    () =>
      SHELLS.map((s) => ({
        label: s.label,
        count: conjunctions.filter(
          (c) => c.midpoint.altKm >= s.min && c.midpoint.altKm < s.max,
        ).length,
      })),
    [conjunctions],
  );

  const scatter = useMemo(
    () =>
      conjunctions.map((c) => ({
        miss: c.missDistanceKm,
        speed: c.relativeSpeedKms,
        risk: (c.relativeSpeedKms * c.relativeSpeedKms) / Math.max(c.missDistanceKm, 0.01),
        conj: c,
      })),
    [conjunctions],
  );

  const leaderboard = useMemo(() => {
    const counts = new Map<string, { count: number; worst: number }>();
    for (const c of conjunctions) {
      for (const o of [c.a, c.b]) {
        const key = o.name ?? `#${o.noradId}`;
        const cur = counts.get(key) ?? { count: 0, worst: Infinity };
        cur.count += 1;
        cur.worst = Math.min(cur.worst, c.missDistanceKm);
        counts.set(key, cur);
      }
    }
    return [...counts.entries()]
      .sort((a, b) => b[1].count - a[1].count)
      .slice(0, 8)
      .map(([name, v]) => ({ name, ...v }));
  }, [conjunctions]);

  if (!show) {
    return (
      <button className="analytics-toggle" onClick={toggle} title="Show analytics">
        Analytics
      </button>
    );
  }

  const onPointClick = (node: unknown) => {
    const c = (node as { conj?: Conjunction })?.conj;
    if (c) selectConjunction(c);
  };

  return (
    <div className="analytics">
      <div className="analytics-head">
        <h2>Conjunction analytics</h2>
        <button className="close" onClick={toggle} aria-label="Close">
          ×
        </button>
      </div>
      <p className="muted">{conjunctions.length.toLocaleString()} closest approaches in view</p>

      <h3>Miss-distance distribution</h3>
      <ResponsiveContainer width="100%" height={150}>
        <BarChart data={histogram} margin={{ top: 6, right: 8, bottom: 4, left: -18 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#1e2a44" />
          <XAxis dataKey="label" tick={axisTick} />
          <YAxis tick={axisTick} />
          <Tooltip contentStyle={tooltipStyle} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
          <Bar dataKey="count" radius={[3, 3, 0, 0]}>
            {histogram.map((d) => (
              <Cell key={d.label} fill={d.color} />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>

      <h3>Relative speed vs miss distance</h3>
      <ResponsiveContainer width="100%" height={180}>
        <ScatterChart margin={{ top: 6, right: 10, bottom: 16, left: -12 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#1e2a44" />
          <XAxis
            type="number"
            dataKey="miss"
            name="Miss"
            unit="km"
            tick={axisTick}
            domain={[0, 5]}
          />
          <YAxis type="number" dataKey="speed" name="Rel speed" unit="km/s" tick={axisTick} />
          <ZAxis type="number" dataKey="risk" range={[12, 180]} />
          <Tooltip
            contentStyle={tooltipStyle}
            cursor={{ strokeDasharray: "3 3" }}
            formatter={(v: number, n: string) =>
              n === "Miss" ? `${v.toFixed(3)} km` : `${v.toFixed(2)} km/s`
            }
          />
          <Scatter data={scatter} fill="#f97316" fillOpacity={0.7} onClick={onPointClick}>
            {scatter.map((d, i) => (
              <Cell key={i} fill={riskHex(d.miss)} cursor="pointer" />
            ))}
          </Scatter>
        </ScatterChart>
      </ResponsiveContainer>

      <h3>Conjunctions by altitude shell (km)</h3>
      <ResponsiveContainer width="100%" height={170}>
        <BarChart
          layout="vertical"
          data={shellData}
          margin={{ top: 4, right: 12, bottom: 4, left: 22 }}
        >
          <CartesianGrid strokeDasharray="3 3" stroke="#1e2a44" />
          <XAxis type="number" tick={axisTick} />
          <YAxis type="category" dataKey="label" tick={axisTick} width={64} />
          <Tooltip contentStyle={tooltipStyle} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
          <Bar dataKey="count" fill="#3b82f6" radius={[0, 3, 3, 0]} />
        </BarChart>
      </ResponsiveContainer>

      <h3>Most-involved objects</h3>
      <table className="leaderboard">
        <thead>
          <tr>
            <th>Object</th>
            <th>Events</th>
            <th>Closest</th>
          </tr>
        </thead>
        <tbody>
          {leaderboard.map((row) => (
            <tr key={row.name}>
              <td className="lb-name">{row.name}</td>
              <td>{row.count}</td>
              <td style={{ color: riskHex(row.worst) }}>{formatMiss(row.worst)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

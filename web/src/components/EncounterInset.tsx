import { useStore } from "../state/store";
import { computeRTN } from "../conjunction/geometry";
import { formatMiss, riskHex } from "../conjunction/risk";

const W = 240;

export default function EncounterInset() {
  const conj = useStore((s) => s.selectedConjunction);
  const selectConjunction = useStore((s) => s.selectConjunction);
  if (!conj) return null;

  const rtn = computeRTN(conj.a.teme, conj.a.vel, conj.b.teme, conj.b.vel);
  const miss = conj.missDistanceKm;
  const cx = W / 2;
  const maxKm = Math.max(miss * 2.5, 5.5);
  const scale = cx / maxKm;
  const color = riskHex(miss);
  const tPx = cx + rtn.pos.T * scale;
  const nPx = cx - rtn.pos.N * scale;

  return (
    <div className="encounter-inset">
      <button className="close" onClick={() => selectConjunction(null)} aria-label="Close">
        ×
      </button>
      <h3>
        {conj.a.name ?? `#${conj.a.noradId}`} × {conj.b.name ?? `#${conj.b.noradId}`}
      </h3>

      <svg width={W} height={W} className="enc-svg">
        <line x1={cx} y1={0} x2={cx} y2={W} stroke="#1e2a44" />
        <line x1={0} y1={cx} x2={W} y2={cx} stroke="#1e2a44" />
        {[1, 2, 5]
          .filter((r) => r <= maxKm)
          .map((r) => (
            <g key={r}>
              <circle
                cx={cx}
                cy={cx}
                r={r * scale}
                fill="none"
                stroke="#334155"
                strokeDasharray="3 3"
              />
              <text x={cx + r * scale + 2} y={cx - 2} fill="#64748b" fontSize={9}>
                {r}km
              </text>
            </g>
          ))}
        <circle cx={cx} cy={cx} r={miss * scale} fill={`${color}22`} stroke={color} />
        <circle cx={tPx} cy={nPx} r={5} fill="#ffffff" stroke={color} strokeWidth={2} />
        <text x={cx + 4} y={12} fill="#475569" fontSize={10}>
          N cross-track
        </text>
        <text x={W - 70} y={cx - 4} fill="#475569" fontSize={10}>
          T in-track
        </text>
      </svg>

      <table className="enc-table">
        <tbody>
          <tr>
            <td>Miss</td>
            <td style={{ color }}>{formatMiss(miss)}</td>
          </tr>
          <tr>
            <td>Rel. speed</td>
            <td>{conj.relativeSpeedKms.toFixed(2)} km/s</td>
          </tr>
          <tr>
            <td>Radial</td>
            <td>{rtn.pos.R.toFixed(2)} km</td>
          </tr>
          <tr>
            <td>In-track</td>
            <td>{rtn.pos.T.toFixed(2)} km</td>
          </tr>
          <tr>
            <td>Cross-track</td>
            <td>{rtn.pos.N.toFixed(2)} km</td>
          </tr>
          <tr>
            <td>TCA</td>
            <td>{new Date(conj.tca).toISOString().replace("T", " ").slice(0, 19)}Z</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

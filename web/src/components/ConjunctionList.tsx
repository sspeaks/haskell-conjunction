import { useMemo, useState } from "react";
import { useStore } from "../state/store";
import { formatMiss, riskHex } from "../conjunction/risk";

export default function ConjunctionList() {
  const conjunctions = useStore((s) => s.conjunctions);
  const selected = useStore((s) => s.selectedConjunction);
  const selectConjunction = useStore((s) => s.selectConjunction);
  const [limit, setLimit] = useState(50);

  const rows = useMemo(
    () =>
      [...conjunctions]
        .sort((a, b) => a.missDistanceKm - b.missDistanceKm)
        .slice(0, limit),
    [conjunctions, limit],
  );

  if (conjunctions.length === 0) return null;

  return (
    <div className="conj-list">
      <h2>Closest approaches</h2>
      <ul>
        {rows.map((c) => {
          const isSel = selected?.id === c.id;
          return (
            <li
              key={c.id}
              className={isSel ? "selected" : ""}
              onClick={() => selectConjunction(isSel ? null : c)}
            >
              <span className="dot" style={{ background: riskHex(c.missDistanceKm) }} />
              <span className="pair">
                {c.a.name ?? `#${c.a.noradId}`} <span className="x">×</span>{" "}
                {c.b.name ?? `#${c.b.noradId}`}
              </span>
              <span className="miss">{formatMiss(c.missDistanceKm)}</span>
            </li>
          );
        })}
      </ul>
      {conjunctions.length > limit && (
        <button className="more" onClick={() => setLimit((n) => n + 50)}>
          Show more ({(conjunctions.length - limit).toLocaleString()} hidden)
        </button>
      )}
    </div>
  );
}

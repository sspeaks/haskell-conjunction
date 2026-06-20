import { useMemo, useState } from "react";
import { useStore } from "../state/store";
import { formatMiss, riskHex } from "../conjunction/risk";
import { typeCategory } from "../cesium/colorModes";

export default function ConjunctionList() {
  const conjunctions = useStore((s) => s.conjunctions);
  const satById = useStore((s) => s.satById);
  const visibleTypes = useStore((s) => s.visibleTypes);
  const selected = useStore((s) => s.selectedConjunction);
  const selectConjunction = useStore((s) => s.selectConjunction);
  const [limit, setLimit] = useState(50);

  const filtered = useMemo(() => {
    const catOf = (noradId: number) => {
      const s = satById.get(noradId);
      return s ? typeCategory(s) : "Other";
    };
    return [...conjunctions]
      .filter(
        (c) => visibleTypes[catOf(c.a.noradId)] && visibleTypes[catOf(c.b.noradId)],
      )
      .sort((a, b) => a.missDistanceKm - b.missDistanceKm);
  }, [conjunctions, satById, visibleTypes]);

  const rows = useMemo(() => filtered.slice(0, limit), [filtered, limit]);

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
      {filtered.length > limit && (
        <button className="more" onClick={() => setLimit((n) => n + 50)}>
          Show more ({(filtered.length - limit).toLocaleString()} hidden)
        </button>
      )}
    </div>
  );
}

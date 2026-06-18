import { useStore } from "../state/store";
import { classifyRegime, meanAltitudeKm, REGIME_HEX } from "../cesium/regime";

export default function InfoPanel() {
  const sat = useStore((s) => s.selectedSat);
  const selectSat = useStore((s) => s.selectSat);
  if (!sat) return null;

  const regime = classifyRegime(sat);

  return (
    <div className="info-panel">
      <button className="close" onClick={() => selectSat(null)} aria-label="Close">
        ×
      </button>
      <h2>{sat.name ?? `NORAD ${sat.noradId}`}</h2>
      <table>
        <tbody>
          <tr>
            <td>NORAD</td>
            <td>{sat.noradId}</td>
          </tr>
          <tr>
            <td>Type</td>
            <td>{sat.objectType ?? "—"}</td>
          </tr>
          <tr>
            <td>Regime</td>
            <td>
              <span className="swatch" style={{ background: REGIME_HEX[regime] }} /> {regime}
            </td>
          </tr>
          <tr>
            <td>Inclination</td>
            <td>{sat.inclinationDeg.toFixed(2)}°</td>
          </tr>
          <tr>
            <td>Eccentricity</td>
            <td>{sat.eccentricity.toFixed(4)}</td>
          </tr>
          <tr>
            <td>Period</td>
            <td>{sat.periodMin ? `${sat.periodMin.toFixed(1)} min` : "—"}</td>
          </tr>
          <tr>
            <td>Mean alt</td>
            <td>{meanAltitudeKm(sat).toFixed(0)} km</td>
          </tr>
          <tr>
            <td>Apo / Peri</td>
            <td>
              {sat.apoapsisKm?.toFixed(0) ?? "—"} / {sat.periapsisKm.toFixed(0)} km
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

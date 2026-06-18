import { useEffect, useState } from "react";
import type { VisiblePass } from "../api/types";
import { formatMiss } from "../conjunction/risk";
import { useStore } from "../state/store";

const isValidLat = (n: number) => Number.isFinite(n) && n >= -90 && n <= 90;
const isValidLon = (n: number) => Number.isFinite(n) && n >= -180 && n <= 180;

const parseOptionalHeight = (value: string): number | null => {
  if (value.trim() === "") return 0;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

const timeRange = (start: string, end: string) =>
  `${new Date(start).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  })}–${new Date(end).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  })}`;

const compass = (azimuthDeg: number) => {
  const labels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
  const index = Math.round((((azimuthDeg % 360) + 360) % 360) / 45) % labels.length;
  return labels[index];
};

const samePass = (a: VisiblePass | null, b: VisiblePass) =>
  a?.noradId === b.noradId && a.peakTime === b.peakTime;

export default function VisibilityPanel() {
  const observerLocation = useStore((s) => s.observerLocation);
  const visibilityOptions = useStore((s) => s.visibilityOptions);
  const visiblePasses = useStore((s) => s.visiblePasses);
  const visibleConjunctions = useStore((s) => s.visibleConjunctions);
  const selectedPass = useStore((s) => s.selectedPass);
  const visibilityLoading = useStore((s) => s.visibilityLoading);
  const pickingObserver = useStore((s) => s.pickingObserver);
  const setObserverLocation = useStore((s) => s.setObserverLocation);
  const setVisibilityOptions = useStore((s) => s.setVisibilityOptions);
  const selectPass = useStore((s) => s.selectPass);
  const setPickingObserver = useStore((s) => s.setPickingObserver);

  const [lat, setLat] = useState(observerLocation?.latDeg.toString() ?? "");
  const [lon, setLon] = useState(observerLocation?.lonDeg.toString() ?? "");
  const [height, setHeight] = useState(observerLocation?.heightKm.toString() ?? "");
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    setLat(observerLocation?.latDeg.toString() ?? "");
    setLon(observerLocation?.lonDeg.toString() ?? "");
    setHeight(observerLocation?.heightKm.toString() ?? "");
  }, [observerLocation]);

  const commitLocation = (nextLat = lat, nextLon = lon, nextHeight = height) => {
    const latDeg = Number(nextLat);
    const lonDeg = Number(nextLon);
    const heightKm = parseOptionalHeight(nextHeight);

    if (isValidLat(latDeg) && isValidLon(lonDeg) && heightKm !== null) {
      setObserverLocation({ latDeg, lonDeg, heightKm });
      setMessage(null);
      return;
    }

    if (nextLat || nextLon) {
      setMessage("Enter latitude −90…90 and longitude −180…180.");
    }
  };

  const useGeolocation = () => {
    if (!navigator.geolocation) {
      setMessage("Geolocation is not available in this browser.");
      return;
    }

    setMessage("Requesting location…");
    navigator.geolocation.getCurrentPosition(
      ({ coords }) => {
        const loc = {
          latDeg: coords.latitude,
          lonDeg: coords.longitude,
          heightKm: (coords.altitude ?? 0) / 1000,
        };
        setObserverLocation(loc);
        setMessage("Location set.");
      },
      (error) => setMessage(error.message || "Location permission was denied."),
      { enableHighAccuracy: true, maximumAge: 60_000 },
    );
  };

  return (
    <div className="visibility-panel">
      <h2>Visible passes</h2>

      <section>
        <h3>Observer</h3>
        <div className="visibility-grid">
          <label>
            Lat (°)
            <input
              type="number"
              min="-90"
              max="90"
              step="0.0001"
              value={lat}
              onChange={(e) => {
                setLat(e.target.value);
                commitLocation(e.target.value, lon, height);
              }}
            />
          </label>
          <label>
            Lon (°)
            <input
              type="number"
              min="-180"
              max="180"
              step="0.0001"
              value={lon}
              onChange={(e) => {
                setLon(e.target.value);
                commitLocation(lat, e.target.value, height);
              }}
            />
          </label>
          <label>
            Height (km)
            <input
              type="number"
              step="0.01"
              value={height}
              placeholder="0"
              onChange={(e) => {
                setHeight(e.target.value);
                commitLocation(lat, lon, e.target.value);
              }}
            />
          </label>
        </div>
        <div className="visibility-actions">
          <button type="button" onClick={useGeolocation}>
            Use my location
          </button>
          <button
            type="button"
            className={pickingObserver ? "active" : ""}
            onClick={() => setPickingObserver(!pickingObserver)}
          >
            Pick on map
          </button>
        </div>
        {message && <p className="visibility-message">{message}</p>}
      </section>

      <section>
        <h3>Options</h3>
        <div className="visibility-grid">
          <label>
            Window (h)
            <input
              type="number"
              min="1"
              step="1"
              value={visibilityOptions.windowHours}
              onChange={(e) => setVisibilityOptions({ windowHours: Number(e.target.value) })}
            />
          </label>
          <label>
            Min elevation (°)
            <input
              type="number"
              min="0"
              max="90"
              step="1"
              value={visibilityOptions.minElevationDeg}
              onChange={(e) => setVisibilityOptions({ minElevationDeg: Number(e.target.value) })}
            />
          </label>
          <label>
            Sun below (°)
            <input
              type="number"
              min="-30"
              max="5"
              step="1"
              value={visibilityOptions.sunMaxElevationDeg}
              onChange={(e) => setVisibilityOptions({ sunMaxElevationDeg: Number(e.target.value) })}
            />
          </label>
          <label>
            Max magnitude
            <input
              type="number"
              min="-5"
              max="10"
              step="0.1"
              value={visibilityOptions.magnitudeCutoff}
              onChange={(e) => setVisibilityOptions({ magnitudeCutoff: Number(e.target.value) })}
            />
          </label>
        </div>
      </section>

      <section className="visibility-results">
        <h3>Passes</h3>
        {!observerLocation ? (
          <p className="muted">Set your location to compute visible passes.</p>
        ) : visibilityLoading ? (
          <p className="muted">Computing…</p>
        ) : visiblePasses.length === 0 ? (
          <p className="muted">No visible passes found for these options.</p>
        ) : (
          <ul className="visibility-pass-list">
            {visiblePasses.map((pass) => {
              const selected = samePass(selectedPass, pass);
              return (
                <li
                  key={`${pass.noradId}-${pass.peakTime}`}
                  className={selected ? "selected" : ""}
                  onClick={() => selectPass(selected ? null : pass)}
                >
                  <div className="visibility-pass-head">
                    <span className="visibility-object">{pass.name ?? `#${pass.noradId}`}</span>
                    {pass.peakMagnitude <= 4 && <span className="visibility-badge">naked-eye</span>}
                    <span className="visibility-mag">{pass.peakMagnitude.toFixed(1)}</span>
                  </div>
                  <div className="visibility-pass-meta">
                    <span>{timeRange(pass.riseTime, pass.setTime)}</span>
                    <span>{pass.peakElevationDeg.toFixed(0)}° elev</span>
                    <span>
                      {pass.peakAzimuthDeg.toFixed(0)}° {compass(pass.peakAzimuthDeg)}
                    </span>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      {visibleConjunctions.length > 0 && (
        <section className="visibility-conjunctions">
          <h3>Visible conjunctions</h3>
          <ul>
            {visibleConjunctions.map((conjunction) => (
              <li key={conjunction.conjunctionId}>
                <span className="visibility-pair">
                  {conjunction.aName ?? `#${conjunction.aNoradId}`}{" "}
                  <span className="x">×</span> {conjunction.bName ?? `#${conjunction.bNoradId}`}
                </span>
                <span>{formatMiss(conjunction.missDistanceKm)}</span>
                <span>{conjunction.peakElevationDeg.toFixed(0)}°</span>
                <span>mag {conjunction.peakMagnitude.toFixed(1)}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

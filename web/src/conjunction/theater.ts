import {
  ArcType,
  CallbackPositionProperty,
  CallbackProperty,
  Cartesian2,
  Cartesian3,
  ClockRange,
  Color,
  ConstantPositionProperty,
  Entity,
  JulianDate,
  LabelStyle,
  PolylineGlowMaterialProperty,
  PositionProperty,
  TimeInterval,
  Transforms,
  Viewer,
} from "cesium";
import type { Conjunction, Geo, ObjectState, Satellite } from "../api/types";
import { buildSampledPosition, parseTle } from "../cesium/propagate";
import { riskColor } from "./risk";

const WINDOW_SEC = 300; // ±5 minutes around TCA
const COLOR_A = Color.fromCssColorString("#38bdf8");
const COLOR_B = Color.fromCssColorString("#f472b6");

function geoToCartesian(lat: number, lon: number, altKm: number): Cartesian3 {
  return Cartesian3.fromDegrees(lon, lat, altKm * 1000);
}

function geoOf(geo: Geo): Cartesian3 {
  return geoToCartesian(geo.lat, geo.lon, geo.altKm);
}

/**
 * Choreographs the visualization of a single close approach: clock window
 * centered on TCA, animated orbit trails for both objects, a dynamic
 * miss-distance line + readout, a camera fly-to, and a slow-motion ramp.
 */
export class ConjunctionTheater {
  private readonly viewer: Viewer;
  private readonly entities: Entity[] = [];
  private removeRamp?: () => void;

  constructor(viewer: Viewer) {
    this.viewer = viewer;
  }

  show(conj: Conjunction, satById: Map<number, Satellite>): void {
    this.clear();
    const tca = JulianDate.fromIso8601(conj.tca);
    const start = JulianDate.addSeconds(tca, -WINDOW_SEC, new JulianDate());
    const stop = JulianDate.addSeconds(tca, WINDOW_SEC, new JulianDate());
    // Preload ICRF<->Fixed orientation for the encounter window so inertial-frame
    // orbit trails rotate with the best available accuracy (Cesium falls back to a
    // TEME pseudo-fixed rotation until this resolves).
    void Transforms.preloadIcrfFixed(new TimeInterval({ start, stop })).catch(() => {});

    const clock = this.viewer.clock;
    clock.startTime = start.clone();
    clock.stopTime = stop.clone();
    clock.currentTime = JulianDate.addSeconds(tca, -60, new JulianDate());
    clock.clockRange = ClockRange.LOOP_STOP;
    clock.multiplier = 8;
    clock.shouldAnimate = true;
    this.viewer.timeline?.zoomTo(start, stop);

    const entA = this.addObject(conj.a, satById, start, COLOR_A);
    const entB = this.addObject(conj.b, satById, start, COLOR_B);

    const posAt = (ent: Entity, time: JulianDate | undefined): Cartesian3 | undefined =>
      time ? (ent.position?.getValue(time) ?? undefined) : undefined;

    const color = riskColor(conj.missDistanceKm);

    // Dynamic line connecting the two moving objects.
    this.entities.push(
      this.viewer.entities.add({
        polyline: {
          positions: new CallbackProperty((time) => {
            const pa = posAt(entA, time);
            const pb = posAt(entB, time);
            return pa && pb ? [pa, pb] : undefined;
          }, false),
          width: 2,
          arcType: ArcType.NONE,
          material: new PolylineGlowMaterialProperty({ glowPower: 0.25, color }),
          depthFailMaterial: new PolylineGlowMaterialProperty({
            glowPower: 0.1,
            color: color.withAlpha(0.4),
          }),
        },
      }),
    );

    // Live separation readout at the midpoint.
    this.entities.push(
      this.viewer.entities.add({
        position: new CallbackPositionProperty((time) => {
          const pa = posAt(entA, time);
          const pb = posAt(entB, time);
          return pa && pb ? Cartesian3.midpoint(pa, pb, new Cartesian3()) : undefined;
        }, false),
        label: {
          text: new CallbackProperty((time) => {
            const pa = posAt(entA, time);
            const pb = posAt(entB, time);
            if (!pa || !pb) return "";
            return `${(Cartesian3.distance(pa, pb) / 1000).toFixed(3)} km`;
          }, false),
          font: "13px monospace",
          fillColor: Color.WHITE,
          showBackground: true,
          backgroundColor: new Color(0.05, 0.07, 0.12, 0.85),
          pixelOffset: new Cartesian2(0, -28),
          style: LabelStyle.FILL,
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        },
      }),
    );

    // Frame the encounter from above the midpoint.
    this.viewer.camera.flyTo({
      destination: geoToCartesian(conj.midpoint.lat, conj.midpoint.lon, conj.midpoint.altKm + 1200),
      duration: 1.8,
      orientation: { heading: 0, pitch: -Math.PI / 2.4, roll: 0 },
    });

    this.installSlowMo(tca);
  }

  private addObject(
    os: ObjectState,
    satById: Map<number, Satellite>,
    start: JulianDate,
    color: Color,
  ): Entity {
    const sat = satById.get(os.noradId);
    const rec = sat ? parseTle(sat.tle1, sat.tle2) : null;

    let position: PositionProperty;
    let hasTrail = false;
    if (rec) {
      position = buildSampledPosition(rec, start, WINDOW_SEC * 2, 5);
      hasTrail = true;
    } else {
      position = new ConstantPositionProperty(geoOf(os.geo));
    }

    const ent = this.viewer.entities.add({
      position,
      point: { pixelSize: 11, color, outlineColor: Color.WHITE, outlineWidth: 1.5 },
      label: {
        text: os.name ?? `NORAD ${os.noradId}`,
        font: "12px sans-serif",
        fillColor: color,
        pixelOffset: new Cartesian2(12, 0),
        style: LabelStyle.FILL,
        disableDepthTestDistance: Number.POSITIVE_INFINITY,
      },
      path: hasTrail
        ? {
            leadTime: WINDOW_SEC,
            trailTime: WINDOW_SEC,
            width: 1.5,
            resolution: 5,
            material: new PolylineGlowMaterialProperty({
              glowPower: 0.15,
              color: color.withAlpha(0.7),
            }),
          }
        : undefined,
    });
    this.entities.push(ent);
    return ent;
  }

  private installSlowMo(tca: JulianDate): void {
    const slowRadius = 45;
    const maxMult = 8;
    const listener = (clock: { currentTime: JulianDate; multiplier: number }) => {
      const dt = Math.abs(JulianDate.secondsDifference(clock.currentTime, tca));
      clock.multiplier = dt < slowRadius ? Math.max(1, maxMult * (dt / slowRadius)) : maxMult;
    };
    this.viewer.clock.onTick.addEventListener(listener);
    this.removeRamp = () => this.viewer.clock.onTick.removeEventListener(listener);
  }

  clear(): void {
    this.removeRamp?.();
    this.removeRamp = undefined;
    for (const e of this.entities) this.viewer.entities.remove(e);
    this.entities.length = 0;
  }

  /** Restore the default 24h-from-now clock window. */
  resetClock(): void {
    const start = JulianDate.now();
    const stop = JulianDate.addSeconds(start, 24 * 3600, new JulianDate());
    const clock = this.viewer.clock;
    clock.startTime = start.clone();
    clock.stopTime = stop.clone();
    clock.currentTime = start.clone();
    clock.clockRange = ClockRange.LOOP_STOP;
    clock.multiplier = 60;
    clock.shouldAnimate = true;
    this.viewer.timeline?.zoomTo(start, stop);
  }

  destroy(): void {
    this.clear();
  }
}

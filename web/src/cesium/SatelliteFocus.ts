import {
  ArcType,
  CallbackPositionProperty,
  CallbackProperty,
  Cartesian3,
  Color,
  JulianDate,
  Matrix3,
  PolylineDashMaterialProperty,
  PolylineGlowMaterialProperty,
  Transforms,
} from "cesium";
import type { Entity, Viewer } from "cesium";
import type { Satellite } from "../api/types";
import {
  buildOrbitRingPoints,
  parseTle,
  propagateEcef,
  propagateGeodetic,
} from "./propagate";

export class SatelliteFocus {
  private readonly viewer: Viewer;
  private orbitEntity?: Entity;
  private groundTrackEntity?: Entity;

  constructor(viewer: Viewer) {
    this.viewer = viewer;
  }

  show(sat: Satellite): void {
    this.clear();

    const rec = parseTle(sat.tle1, sat.tle2);
    if (!rec) return;

    const periodMin = sat.periodMin ?? 1440 / sat.meanMotion;
    const periodSec = periodMin * 60;
    const stepSec = Math.max(2, periodSec / 180);
    const cyan = Color.fromCssColorString("#67e8f9");

    // Orbit ring: one full period sampled in the inertial (TEME) frame and
    // rotated into the Earth-fixed frame at the current clock time, so it renders
    // as a clean closed circle/ellipse that is always complete regardless of the
    // animation clock. Re-anchor the sampling epoch when the clock drifts more
    // than one period so secular precession stays bounded and the marker stays
    // on the ring.
    let ringEpoch = JulianDate.now();
    let temePoints = buildOrbitRingPoints(rec, ringEpoch, periodSec, stepSec);
    const rotation = new Matrix3();

    const ringPositions = new CallbackProperty((time) => {
      if (!time) return undefined;
      if (Math.abs(JulianDate.secondsDifference(time, ringEpoch)) > periodSec) {
        ringEpoch = JulianDate.clone(time, ringEpoch);
        temePoints = buildOrbitRingPoints(rec, ringEpoch, periodSec, stepSec);
      }
      if (temePoints.length === 0) return undefined;
      const m = Transforms.computeTemeToPseudoFixedMatrix(time, rotation);
      if (!m) return undefined;
      return temePoints.map((p) => Matrix3.multiplyByVector(m, p, new Cartesian3()));
    }, false);

    // Marker dot: propagate at the current clock time so it always sits on the
    // ring and never freezes when the sampling window is exceeded.
    const markerPosition = new CallbackPositionProperty((time) => {
      if (!time) return undefined;
      return propagateEcef(rec, JulianDate.toDate(time)) ?? undefined;
    }, false);

    this.orbitEntity = this.viewer.entities.add({
      position: markerPosition,
      point: {
        pixelSize: 10,
        color: Color.WHITE,
      },
      polyline: {
        positions: ringPositions,
        width: 2,
        arcType: ArcType.NONE,
        material: new PolylineGlowMaterialProperty({
          glowPower: 0.18,
          color: cyan,
        }),
      },
    });

    // Ground track: a static sub-satellite path over one period (Earth-fixed),
    // clamped to the surface.
    const positions: Cartesian3[] = [];
    for (let t = 0; t <= periodSec; t += stepSec) {
      const date = JulianDate.toDate(JulianDate.addSeconds(ringEpoch, t, new JulianDate()));
      const gd = propagateGeodetic(rec, date);
      if (gd) {
        positions.push(Cartesian3.fromDegrees(gd.lonDeg, gd.latDeg, 0));
      }
    }

    this.groundTrackEntity = this.viewer.entities.add({
      polyline: {
        positions,
        width: 1.5,
        clampToGround: true,
        arcType: ArcType.GEODESIC,
        material: new PolylineDashMaterialProperty({
          color: cyan.withAlpha(0.7),
          dashLength: 16,
        }),
      },
    });

    this.viewer.scene.requestRender();
  }

  clear(): void {
    if (this.orbitEntity) {
      this.viewer.entities.remove(this.orbitEntity);
    }
    if (this.groundTrackEntity) {
      this.viewer.entities.remove(this.groundTrackEntity);
    }
    this.orbitEntity = undefined;
    this.groundTrackEntity = undefined;
    this.viewer.scene.requestRender();
  }

  destroy(): void {
    this.clear();
  }
}

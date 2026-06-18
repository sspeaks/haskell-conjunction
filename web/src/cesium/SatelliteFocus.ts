import {
  ArcType,
  Cartesian3,
  Color,
  JulianDate,
  PolylineDashMaterialProperty,
  PolylineGlowMaterialProperty,
} from "cesium";
import type { Entity, Viewer } from "cesium";
import type { Satellite } from "../api/types";
import { buildSampledPosition, parseTle, propagateGeodetic } from "./propagate";

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
    const start = JulianDate.addSeconds(JulianDate.now(), -periodSec / 2, new JulianDate());
    const position = buildSampledPosition(rec, start, periodSec, stepSec);
    const cyan = Color.fromCssColorString("#67e8f9");

    this.orbitEntity = this.viewer.entities.add({
      position,
      point: {
        pixelSize: 10,
        color: Color.WHITE,
      },
      path: {
        leadTime: periodSec / 2,
        trailTime: periodSec / 2,
        width: 2,
        resolution: stepSec,
        material: new PolylineGlowMaterialProperty({
          glowPower: 0.18,
          color: cyan,
        }),
      },
    });

    const positions: Cartesian3[] = [];
    for (let t = 0; t <= periodSec; t += stepSec) {
      const date = JulianDate.toDate(JulianDate.addSeconds(start, t, new JulianDate()));
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

import {
  ArcType,
  Cartesian3,
  Color,
  HeightReference,
  LabelStyle,
  PolylineGlowMaterialProperty,
  VerticalOrigin,
} from "cesium";
import type { Entity, Viewer } from "cesium";
import type { ObserverLocation, Satellite, VisiblePass } from "../api/types";
import { parseTle, propagateEcef } from "./propagate";

export class VisibilityPredictor {
  private readonly viewer: Viewer;
  private observerEntity?: Entity;
  private passEntity?: Entity;
  private lineOfSightEntity?: Entity;
  private peakEntity?: Entity;

  constructor(viewer: Viewer) {
    this.viewer = viewer;
  }

  setObserver(loc: ObserverLocation | null): void {
    if (this.observerEntity) {
      this.viewer.entities.remove(this.observerEntity);
      this.observerEntity = undefined;
    }

    if (!loc) {
      this.viewer.scene.requestRender();
      return;
    }

    const heightM = (loc.heightKm ?? 0) * 1000;
    const heightReference = heightM === 0 ? HeightReference.CLAMP_TO_GROUND : HeightReference.NONE;
    this.observerEntity = this.viewer.entities.add({
      position: Cartesian3.fromDegrees(loc.lonDeg, loc.latDeg, heightM),
      point: {
        pixelSize: 12,
        color: Color.LIME,
        outlineColor: Color.WHITE,
        outlineWidth: 2,
        heightReference,
        disableDepthTestDistance: Number.POSITIVE_INFINITY,
      },
      label: {
        text: "Observer",
        font: "14px sans-serif",
        fillColor: Color.WHITE,
        outlineColor: Color.BLACK,
        outlineWidth: 2,
        style: LabelStyle.FILL_AND_OUTLINE,
        pixelOffset: new Cartesian3(0, -24, 0),
        verticalOrigin: VerticalOrigin.BOTTOM,
        heightReference,
        disableDepthTestDistance: Number.POSITIVE_INFINITY,
      },
    });

    this.viewer.scene.requestRender();
  }

  showPass(pass: VisiblePass, sat: Satellite, observer: ObserverLocation): void {
    this.clear();

    const rec = parseTle(sat.tle1, sat.tle2);
    if (!rec) return;

    const riseTime = new Date(pass.riseTime);
    const peakTime = new Date(pass.peakTime);
    const setTime = new Date(pass.setTime);
    const riseMs = riseTime.getTime();
    const peakMs = peakTime.getTime();
    const setMs = setTime.getTime();
    if (!Number.isFinite(riseMs) || !Number.isFinite(peakMs) || !Number.isFinite(setMs)) return;

    const durationSec = (setMs - riseMs) / 1000;
    if (durationSec <= 0) return;

    const stepSec = Math.max(5, durationSec / 300);
    const positions: Cartesian3[] = [];
    let lastSampleSec = -Infinity;
    for (let t = 0; t <= durationSec; t += stepSec) {
      const position = propagateEcef(rec, new Date(riseMs + t * 1000));
      if (position) positions.push(position);
      lastSampleSec = t;
    }
    if (durationSec - lastSampleSec > 0.001) {
      const position = propagateEcef(rec, setTime);
      if (position) positions.push(position);
    }

    const cyan = Color.fromCssColorString("#67e8f9");
    if (positions.length >= 2) {
      this.passEntity = this.viewer.entities.add({
        polyline: {
          positions,
          width: 4,
          arcType: ArcType.NONE,
          material: new PolylineGlowMaterialProperty({
            glowPower: 0.2,
            color: cyan,
          }),
        },
      });
    }

    const observerPosition = Cartesian3.fromDegrees(
      observer.lonDeg,
      observer.latDeg,
      (observer.heightKm ?? 0) * 1000,
    );
    const peakPosition = propagateEcef(rec, peakTime);
    if (peakPosition) {
      this.lineOfSightEntity = this.viewer.entities.add({
        polyline: {
          positions: [observerPosition, peakPosition],
          width: 2,
          arcType: ArcType.NONE,
          material: Color.YELLOW.withAlpha(0.85),
        },
      });

      this.peakEntity = this.viewer.entities.add({
        position: peakPosition,
        point: {
          pixelSize: 9,
          color: Color.YELLOW,
          outlineColor: Color.WHITE,
          outlineWidth: 1,
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        },
      });
    }

    this.viewer.scene.requestRender();
  }

  clear(): void {
    if (this.passEntity) {
      this.viewer.entities.remove(this.passEntity);
    }
    if (this.lineOfSightEntity) {
      this.viewer.entities.remove(this.lineOfSightEntity);
    }
    if (this.peakEntity) {
      this.viewer.entities.remove(this.peakEntity);
    }
    this.passEntity = undefined;
    this.lineOfSightEntity = undefined;
    this.peakEntity = undefined;
    this.viewer.scene.requestRender();
  }

  destroy(): void {
    this.clear();
    if (this.observerEntity) {
      this.viewer.entities.remove(this.observerEntity);
      this.observerEntity = undefined;
      this.viewer.scene.requestRender();
    }
  }
}

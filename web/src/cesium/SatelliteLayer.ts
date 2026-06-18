import {
  BlendOption,
  Color,
  defined,
  JulianDate,
  PointPrimitive,
  PointPrimitiveCollection,
  ScreenSpaceEventHandler,
  ScreenSpaceEventType,
  Viewer,
} from "cesium";
import type { Satellite } from "../api/types";
import { parseTle, propagateEcef, type SatRec } from "./propagate";
import { classifyRegime, type Regime } from "./regime";
import { colorFor, type ColorMode } from "./colorModes";

interface SatEntry {
  sat: Satellite;
  rec: SatRec;
  regime: Regime;
  primitive: PointPrimitive;
  visible: boolean;
}

export interface SatPickPayload {
  kind: "satellite";
  sat: Satellite;
}

interface LayerOptions {
  // How many satellites to re-propagate per update slice.
  batchSize?: number;
  // Minimum wall-clock gap between update slices, in milliseconds.
  updateIntervalMs?: number;
}

/**
 * Renders the satellite catalog as a single GPU-batched point cloud and keeps
 * positions current by re-propagating a round-robin slice of the catalog each
 * update tick (so per-frame SGP4 work stays bounded for large catalogs).
 */
export class SatelliteLayer {
  private readonly viewer: Viewer;
  private readonly collection: PointPrimitiveCollection;
  private readonly entries: SatEntry[] = [];
  private readonly onSelect: (sat: Satellite | null) => void;
  private readonly batchSize: number;
  private readonly updateIntervalMs: number;

  private cursor = 0;
  private lastUpdate = 0;
  private colorMode: ColorMode = "regime";
  private removeTick?: () => void;
  private handler?: ScreenSpaceEventHandler;

  constructor(
    viewer: Viewer,
    onSelect: (sat: Satellite | null) => void,
    opts: LayerOptions = {},
  ) {
    this.viewer = viewer;
    this.onSelect = onSelect;
    this.batchSize = opts.batchSize ?? 2000;
    this.updateIntervalMs = opts.updateIntervalMs ?? 60;
    this.collection = viewer.scene.primitives.add(
      new PointPrimitiveCollection({ blendOption: BlendOption.OPAQUE }),
    );
  }

  /** Build the point cloud from a satellite list. Returns how many rendered. */
  load(sats: Satellite[]): number {
    const date = JulianDate.toDate(this.viewer.clock.currentTime);
    for (const sat of sats) {
      const rec = parseTle(sat.tle1, sat.tle2);
      if (!rec) continue;
      const regime = classifyRegime(sat);
      const pos = propagateEcef(rec, date);
      if (!pos) continue;
      const payload: SatPickPayload = { kind: "satellite", sat };
      const primitive = this.collection.add({
        position: pos,
        color: colorFor(sat, this.colorMode),
        pixelSize: sat.objectType === "DEBRIS" ? 2.5 : 4.5,
        id: payload,
      });
      this.entries.push({ sat, rec, regime, primitive, visible: true });
    }
    this.startUpdates();
    this.setupPicking();
    return this.entries.length;
  }

  /** Recolor every point according to a color scheme. */
  setColorMode(mode: ColorMode): void {
    this.colorMode = mode;
    for (const e of this.entries) {
      e.primitive.color = colorFor(e.sat, mode);
    }
    this.viewer.scene.requestRender();
  }

  /** Show or hide every satellite in a regime. */
  setRegimeVisible(regime: Regime, show: boolean): void {
    for (const e of this.entries) {
      if (e.regime === regime) {
        e.visible = show;
        e.primitive.show = show;
      }
    }
    this.viewer.scene.requestRender();
  }

  /** Highlight a single satellite (enlarge + white outline) or clear (null). */
  highlight(noradId: number | null): void {
    for (const e of this.entries) {
      const isSel = e.sat.noradId === noradId;
      e.primitive.pixelSize = isSel ? 12 : e.sat.objectType === "DEBRIS" ? 2.5 : 4.5;
      e.primitive.outlineColor = isSel ? Color.WHITE : Color.TRANSPARENT;
      e.primitive.outlineWidth = isSel ? 2 : 0;
    }
    this.viewer.scene.requestRender();
  }

  private startUpdates(): void {
    const listener = (clock: { currentTime: JulianDate }) => {
      const now = performance.now();
      if (now - this.lastUpdate < this.updateIntervalMs) return;
      this.lastUpdate = now;

      const n = this.entries.length;
      if (n === 0) return;
      const date = JulianDate.toDate(clock.currentTime);
      const count = Math.min(this.batchSize, n);
      for (let i = 0; i < count; i++) {
        const e = this.entries[(this.cursor + i) % n];
        if (!e.visible) continue;
        const pos = propagateEcef(e.rec, date);
        if (pos) e.primitive.position = pos;
      }
      this.cursor = (this.cursor + count) % n;
      this.viewer.scene.requestRender();
    };
    this.viewer.clock.onTick.addEventListener(listener);
    this.removeTick = () => this.viewer.clock.onTick.removeEventListener(listener);
  }

  private setupPicking(): void {
    const handler = new ScreenSpaceEventHandler(this.viewer.scene.canvas);
    handler.setInputAction((evt: ScreenSpaceEventHandler.PositionedEvent) => {
      const picked = this.viewer.scene.pick(evt.position);
      if (defined(picked) && picked.id && picked.id.kind === "satellite") {
        this.onSelect((picked.id as SatPickPayload).sat);
      } else {
        this.onSelect(null);
      }
    }, ScreenSpaceEventType.LEFT_CLICK);
    this.handler = handler;
  }

  destroy(): void {
    this.removeTick?.();
    this.handler?.destroy();
    this.handler = undefined;
    if (!this.collection.isDestroyed()) {
      this.viewer.scene.primitives.remove(this.collection);
    }
    this.entries.length = 0;
  }
}

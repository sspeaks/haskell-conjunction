import { Cartesian3, Color, Entity, Viewer } from "cesium";

export type ShellName = "LEO" | "MEO" | "GEO";

export const SHELL_NAMES: ShellName[] = ["LEO", "MEO", "GEO"];

export const SHELL_HEX: Record<ShellName, string> = {
  LEO: "#22d3ee",
  MEO: "#fbbf24",
  GEO: "#fb923c",
};

const EARTH_RADIUS_METERS = 6_371_000;
const SHELL_ALPHA = 0.05;
const OUTLINE_ALPHA = 0.3;

const SHELL_GEOMETRY: Record<ShellName, { inner: number; outer: number }> = {
  LEO: {
    inner: EARTH_RADIUS_METERS + 160_000,
    outer: EARTH_RADIUS_METERS + 2_000_000,
  },
  MEO: {
    inner: EARTH_RADIUS_METERS + 2_000_000,
    outer: EARTH_RADIUS_METERS + 34_000_000,
  },
  GEO: {
    inner: EARTH_RADIUS_METERS + 34_000_000,
    outer: EARTH_RADIUS_METERS + 37_000_000,
  },
};

export class AltitudeShells {
  private readonly viewer: Viewer;
  private readonly entities: Record<ShellName, Entity>;
  private readonly visibility: Record<ShellName, boolean> = {
    LEO: false,
    MEO: false,
    GEO: false,
  };

  constructor(viewer: Viewer) {
    this.viewer = viewer;
    const entities = {} as Record<ShellName, Entity>;

    for (const shell of SHELL_NAMES) {
      const { inner, outer } = SHELL_GEOMETRY[shell];
      const hex = SHELL_HEX[shell];
      const color = Color.fromCssColorString(hex);

      entities[shell] = viewer.entities.add({
        position: Cartesian3.ZERO,
        show: false,
        ellipsoid: {
          radii: new Cartesian3(outer, outer, outer),
          innerRadii: new Cartesian3(inner, inner, inner),
          fill: true,
          material: color.withAlpha(SHELL_ALPHA),
          outline: true,
          outlineColor: color.withAlpha(OUTLINE_ALPHA),
          slicePartitions: 32,
          stackPartitions: 32,
        },
      });
    }

    this.entities = entities;
  }

  setVisible(shell: ShellName, show: boolean): void {
    this.visibility[shell] = show;
    this.entities[shell].show = show;
    this.viewer.scene.requestRender();
  }

  setAllVisible(show: boolean): void {
    for (const shell of SHELL_NAMES) {
      this.setVisible(shell, show);
    }
  }

  isVisible(shell: ShellName): boolean {
    return this.visibility[shell];
  }

  destroy(): void {
    for (const shell of SHELL_NAMES) {
      this.viewer.entities.remove(this.entities[shell]);
    }
    this.viewer.scene.requestRender();
  }
}

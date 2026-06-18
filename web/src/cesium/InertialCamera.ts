import {
  Cartesian3,
  defined,
  JulianDate,
  Matrix4,
  TimeInterval,
  Transforms,
  Viewer,
} from "cesium";

export class InertialCamera {
  private readonly viewer: Viewer;
  private enabled = false;
  private removeListener?: () => void;

  constructor(viewer: Viewer) {
    this.viewer = viewer;

    void Transforms.preloadIcrfFixed(
      new TimeInterval({
        start: JulianDate.addDays(JulianDate.now(), -1, new JulianDate()),
        stop: JulianDate.addDays(JulianDate.now(), 2, new JulianDate()),
      }),
    ).catch(() => {});
  }

  setEnabled(enabled: boolean): void {
    if (enabled) {
      if (this.enabled) {
        return;
      }

      const handler = (_scene: unknown, time: JulianDate): void => {
        const icrfToFixed = Transforms.computeIcrfToFixedMatrix(time);
        if (!defined(icrfToFixed)) {
          return;
        }

        const offset = Cartesian3.clone(
          this.viewer.camera.position,
          new Cartesian3(),
        );
        const transform = Matrix4.fromRotationTranslation(icrfToFixed);
        this.viewer.camera.lookAtTransform(transform, offset);
      };

      this.viewer.scene.postUpdate.addEventListener(handler);
      this.removeListener = () => {
        this.viewer.scene.postUpdate.removeEventListener(handler);
      };
      this.enabled = true;
      return;
    }

    if (!this.enabled) {
      return;
    }

    this.removeListener?.();
    this.removeListener = undefined;
    this.viewer.camera.lookAtTransform(Matrix4.IDENTITY);
    this.enabled = false;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  destroy(): void {
    this.setEnabled(false);
  }
}

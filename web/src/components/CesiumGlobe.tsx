import { useEffect, useRef } from "react";
import {
  Cartographic,
  ClockRange,
  ClockStep,
  EllipsoidTerrainProvider,
  ImageryLayer,
  JulianDate,
  Math as CesiumMath,
  ScreenSpaceEventHandler,
  ScreenSpaceEventType,
  TileMapServiceImageryProvider,
  Viewer as CesiumViewer,
  buildModuleUrl,
} from "cesium";
import { Viewer, useCesium } from "resium";
import { useStore } from "../state/store";
import { SatelliteLayer } from "../cesium/SatelliteLayer";
import { ConjunctionTheater } from "../conjunction/theater";
import { SatelliteFocus } from "../cesium/SatelliteFocus";
import { AltitudeShells, SHELL_NAMES } from "../cesium/AltitudeShells";
import { InertialCamera } from "../cesium/InertialCamera";
import { VisibilityPredictor } from "../cesium/VisibilityPredictor";
import type { Regime } from "../cesium/regime";

// Token-free providers: flat WGS84 ellipsoid + bundled Natural Earth II imagery
// (natural-color relief, no city/street/road labels). Hoisted to module scope so
// Resium does not re-initialize on every render.
const terrainProvider = new EllipsoidTerrainProvider();
const baseLayer = ImageryLayer.fromProviderAsync(
  TileMapServiceImageryProvider.fromUrl(
    buildModuleUrl("Assets/Textures/NaturalEarthII"),
  ),
);

// 0 (or unset) renders the whole catalog; set VITE_MAX_SATS to cap for perf.
const MAX_SATS = Number(import.meta.env.VITE_MAX_SATS ?? 0);

function SceneContent() {
  const { viewer } = useCesium();
  const layerRef = useRef<SatelliteLayer | null>(null);
  const theaterRef = useRef<ConjunctionTheater | null>(null);
  const focusRef = useRef<SatelliteFocus | null>(null);
  const shellsRef = useRef<AltitudeShells | null>(null);
  const inertialRef = useRef<InertialCamera | null>(null);
  const predictorRef = useRef<VisibilityPredictor | null>(null);
  const satellites = useStore((s) => s.satellites);
  const satById = useStore((s) => s.satById);
  const selectedSat = useStore((s) => s.selectedSat);
  const selectedConjunction = useStore((s) => s.selectedConjunction);
  const observerLocation = useStore((s) => s.observerLocation);
  const selectedPass = useStore((s) => s.selectedPass);
  const pickingObserver = useStore((s) => s.pickingObserver);
  const visibleRegimes = useStore((s) => s.visibleRegimes);
  const colorMode = useStore((s) => s.colorMode);
  const shellVisibility = useStore((s) => s.shellVisibility);
  const inertialMode = useStore((s) => s.inertialMode);
  const selectSat = useStore((s) => s.selectSat);
  const setObserverLocation = useStore((s) => s.setObserverLocation);
  const setPickingObserver = useStore((s) => s.setPickingObserver);

  // Configure the clock once when the viewer is ready (24h window, 1x).
  useEffect(() => {
    if (!viewer) return;
    const start = JulianDate.now();
    const stop = JulianDate.addSeconds(start, 24 * 3600, new JulianDate());
    const clock = viewer.clock;
    clock.startTime = start.clone();
    clock.stopTime = stop.clone();
    clock.currentTime = start.clone();
    clock.clockRange = ClockRange.LOOP_STOP;
    clock.clockStep = ClockStep.SYSTEM_CLOCK_MULTIPLIER;
    clock.multiplier = 1;
    clock.shouldAnimate = true;
    viewer.timeline?.zoomTo(start, stop);
  }, [viewer]);

  // Build / rebuild the point cloud when catalog data arrives.
  useEffect(() => {
    if (!viewer || satellites.length === 0) return;
    const list = MAX_SATS > 0 ? satellites.slice(0, MAX_SATS) : satellites;
    const layer = new SatelliteLayer(viewer as CesiumViewer, selectSat);
    layer.load(list);
    layer.setColorMode(useStore.getState().colorMode);
    layerRef.current = layer;
    return () => {
      layer.destroy();
      layerRef.current = null;
    };
  }, [viewer, satellites, selectSat]);

  // Per-viewer mode controllers (focus overlay, altitude shells, inertial camera).
  useEffect(() => {
    if (!viewer) return;
    const v = viewer as CesiumViewer;
    const focus = new SatelliteFocus(v);
    const shells = new AltitudeShells(v);
    const inertial = new InertialCamera(v);
    focusRef.current = focus;
    shellsRef.current = shells;
    inertialRef.current = inertial;
    return () => {
      focus.destroy();
      shells.destroy();
      inertial.destroy();
      focusRef.current = null;
      shellsRef.current = null;
      inertialRef.current = null;
    };
  }, [viewer]);

  // Visibility predictor overlays.
  useEffect(() => {
    if (!viewer) return;
    const p = new VisibilityPredictor(viewer as CesiumViewer);
    predictorRef.current = p;
    return () => {
      p.destroy();
      predictorRef.current = null;
    };
  }, [viewer]);

  // Apply regime visibility toggles.
  useEffect(() => {
    const layer = layerRef.current;
    if (!layer) return;
    (Object.entries(visibleRegimes) as [Regime, boolean][]).forEach(([r, show]) =>
      layer.setRegimeVisible(r, show),
    );
  }, [visibleRegimes]);

  // Apply the active color scheme to the point cloud.
  useEffect(() => {
    layerRef.current?.setColorMode(colorMode);
  }, [colorMode]);

  // Highlight the selected satellite and draw its orbit + ground track.
  useEffect(() => {
    layerRef.current?.highlight(selectedSat?.noradId ?? null);
    const focus = focusRef.current;
    if (!focus) return;
    if (selectedSat) focus.show(selectedSat);
    else focus.clear();
  }, [selectedSat]);

  // Altitude shells.
  useEffect(() => {
    const shells = shellsRef.current;
    if (!shells) return;
    for (const name of SHELL_NAMES) shells.setVisible(name, shellVisibility[name]);
  }, [shellVisibility]);

  // Inertial-frame camera lock.
  useEffect(() => {
    inertialRef.current?.setEnabled(inertialMode);
  }, [inertialMode]);

  // Observer marker.
  useEffect(() => {
    predictorRef.current?.setObserver(observerLocation);
  }, [observerLocation]);

  // Selected visible pass overlay.
  useEffect(() => {
    const p = predictorRef.current;
    if (!viewer || !p) return;
    if (selectedPass && observerLocation) {
      const sat = satById.get(selectedPass.noradId);
      if (sat) {
        p.showPass(selectedPass, sat, observerLocation);
        viewer.clock.currentTime = JulianDate.fromIso8601(selectedPass.riseTime);
        viewer.clock.shouldAnimate = true;
      }
    } else {
      p.clear();
    }
  }, [viewer, selectedPass, observerLocation, satById]);

  // Pick an observer location on the globe.
  useEffect(() => {
    if (!viewer || !pickingObserver) return;
    const handler = new ScreenSpaceEventHandler(viewer.scene.canvas);
    handler.setInputAction((movement: ScreenSpaceEventHandler.PositionedEvent) => {
      const cartesian = viewer.camera.pickEllipsoid(
        movement.position,
        viewer.scene.globe.ellipsoid,
      );
      if (cartesian) {
        const carto = Cartographic.fromCartesian(cartesian);
        setObserverLocation({
          latDeg: CesiumMath.toDegrees(carto.latitude),
          lonDeg: CesiumMath.toDegrees(carto.longitude),
          heightKm: 0,
        });
        setPickingObserver(false);
      }
    }, ScreenSpaceEventType.LEFT_CLICK);
    return () => handler.destroy();
  }, [viewer, pickingObserver, setObserverLocation, setPickingObserver]);

  // Conjunction theater: build it once the viewer is ready.
  useEffect(() => {
    if (!viewer) return;
    const theater = new ConjunctionTheater(viewer as CesiumViewer);
    theaterRef.current = theater;
    return () => {
      theater.destroy();
      theaterRef.current = null;
    };
  }, [viewer]);

  // React to conjunction selection.
  useEffect(() => {
    const theater = theaterRef.current;
    if (!theater) return;
    if (selectedConjunction) {
      theater.show(selectedConjunction, satById);
    } else {
      theater.clear();
      theater.resetClock();
    }
  }, [selectedConjunction, satById]);

  return null;
}

export default function CesiumGlobe() {
  return (
    <Viewer
      full
      baseLayer={baseLayer}
      terrainProvider={terrainProvider}
      baseLayerPicker={false}
      geocoder={false}
      homeButton={false}
      navigationHelpButton={false}
      sceneModePicker={true}
      infoBox={false}
      selectionIndicator={false}
      timeline={true}
      animation={true}
    >
      <SceneContent />
    </Viewer>
  );
}

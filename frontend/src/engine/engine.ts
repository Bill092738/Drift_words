import { Application, Container, UPDATE_PRIORITY } from 'pixi.js';
import type {
  CreateEngine,
  Engine,
  FrameInfo,
  Intent,
  LayerName,
  Spring,
  SpringConfig,
  Vec,
} from './api.ts';
import { CameraImpl } from './camera.ts';
import { motion, quality } from './config.ts';
import { GestureRecognizer, wheelZoomFactor } from './gestures.ts';
import { registerInternals } from './internals.ts';
import { PerfOverlay } from './perf.ts';
import { LAYERS, Scene } from './scene.ts';
import { SpringImpl } from './spring.ts';

/** The renderer that is actually in use. WebGL reports its version, so a WebGL1 fallback is visible. */
function rendererLabel(renderer: Application['renderer']): string {
  if (renderer.name !== 'webgl') return renderer.name;
  const gl = (renderer as unknown as { context?: { webGLVersion?: number } }).context;
  return gl?.webGLVersion === undefined ? 'webgl' : `webgl${gl.webGLVersion}`;
}

export const createEngine: CreateEngine = async (host, options = {}) => {
  const {
    preferWebGPU = true,
    maxResolution = quality.maxResolution,
    perfOverlay = false,
  } = options;

  const app = new Application();
  await app.init({
    resizeTo: host,
    // Pixi falls back to WebGL when WebGPU is not available.
    preference: preferWebGPU ? 'webgpu' : 'webgl',
    resolution: Math.min(window.devicePixelRatio || 1, maxResolution),
    autoDensity: true,
    antialias: quality.antialias,
    // Transparent: the desk color and dot grid are CSS on the host, so they
    // follow the page theme (including live dark mode changes).
    backgroundAlpha: 0,
  });
  host.appendChild(app.canvas);
  app.canvas.style.touchAction = 'none';
  app.canvas.style.display = 'block';

  const camera = new CameraImpl();
  // Size the camera now, so the viewport is right before the first frame.
  camera.resize(app.screen.width, app.screen.height);
  const scene = new Scene();
  const overlay = perfOverlay ? new PerfOverlay(host, rendererLabel(app.renderer)) : null;

  // The world container follows the camera; the hud container stays in screen space.
  const world = new Container();
  const containers = {} as Record<LayerName, Container>;
  for (const name of LAYERS) {
    const c = new Container({ label: name });
    containers[name] = c;
    (name === 'hud' ? app.stage : world).addChild(c);
  }
  app.stage.addChildAt(world, 0);

  const layerOf = new Map<string, LayerName>();
  const springList = new Set<WeakRef<SpringImpl>>();
  const frameCallbacks = new Set<(frame: FrameInfo) => void>();
  const intentCallbacks = new Set<(intent: Intent) => void>();
  let selectedId: string | null = null;
  let time = 0;

  const emit = (intent: Intent): void => {
    for (const cb of intentCallbacks) cb(intent);
  };

  const handleTap = (screen: Vec): void => {
    const id = scene.hit(screen, camera.screenToWorld(screen));
    if (id === null) {
      selectedId = null;
      emit({ type: 'background', at: camera.screenToWorld(screen) });
    } else if (id === selectedId) {
      emit({ type: 'open', id });
    } else {
      selectedId = id;
      emit({ type: 'select', id });
    }
  };

  const abort = new AbortController();

  const gestures = new GestureRecognizer({
    pan: (dx, dy) => camera.panBy(dx, dy),
    zoom: (factor, at) => camera.zoomAt(at, factor),
    tap: handleTap,
    fling: (vx, vy) => camera.fling(vx, vy),
  });

  // Reduced motion: follows the OS setting live.
  const motionQuery =
    typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : null;
  const applyReducedMotion = (): void => {
    const reduced = motionQuery?.matches ?? false;
    camera.reducedMotion = reduced;
    if (reduced) camera.stopFling();
    for (const ref of springList) {
      const s = ref.deref();
      if (s !== undefined) s.reducedMotion = reduced;
    }
  };
  applyReducedMotion();
  motionQuery?.addEventListener('change', applyReducedMotion, { signal: abort.signal });

  const local = (e: { clientX: number; clientY: number }): Vec => {
    const r = app.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  const listen = { signal: abort.signal };
  const canvas = app.canvas;
  canvas.addEventListener(
    'pointerdown',
    (e) => {
      try {
        canvas.setPointerCapture(e.pointerId);
      } catch {
        // Synthetic pointers (tests, scripted input) have no capturable id.
      }
      camera.stopFling(); // touching the desk stops it coasting
      gestures.pointerDown(e.pointerId, local(e), e.timeStamp);
    },
    listen,
  );
  canvas.addEventListener(
    'pointermove',
    (e) => gestures.pointerMove(e.pointerId, local(e), e.timeStamp),
    listen,
  );
  canvas.addEventListener(
    'pointerup',
    (e) => gestures.pointerUp(e.pointerId, local(e), e.timeStamp),
    listen,
  );
  canvas.addEventListener('pointercancel', (e) => gestures.pointerCancel(e.pointerId), listen);
  canvas.addEventListener(
    'wheel',
    (e) => {
      e.preventDefault();
      camera.zoomAtSmooth(local(e), wheelZoomFactor(e.deltaY, e.deltaMode, e.ctrlKey));
    },
    { signal: abort.signal, passive: false },
  );

  // Frame accounting for the overlay: `logic` is this callback; `render` is what
  // runs after it up to a final low-priority callback, which includes Pixi's render.
  let logicStart = 0;
  let logicEnd = 0;
  let frameMs = 0;

  app.ticker.add((ticker) => {
    logicStart = performance.now();
    frameMs = ticker.elapsedMS;
    const dt = Math.min(ticker.deltaMS / 1000, motion.maxFrameSeconds);
    time += dt;

    for (const ref of springList) {
      const s = ref.deref();
      if (s === undefined) springList.delete(ref);
      else s.step(dt);
    }
    camera.resize(app.screen.width, app.screen.height);
    camera.step(dt);
    for (const cb of frameCallbacks) cb({ dt, time });

    const z = camera.zoom;
    const c = camera.center;
    world.scale.set(z);
    world.position.set(app.screen.width / 2 - c.x * z, app.screen.height / 2 - c.y * z);
    // Move the host's CSS dot grid with the world.
    host.style.backgroundSize = `${quality.gridCell * z}px ${quality.gridCell * z}px`;
    host.style.backgroundPosition = `${world.position.x}px ${world.position.y}px`;
    scene.cull(camera.viewport);
    logicEnd = performance.now();
  });

  if (overlay !== null) {
    app.ticker.add(
      () => {
        const end = performance.now();
        overlay.record(frameMs, logicEnd - logicStart, end - logicEnd, scene.visible, scene.total);
      },
      undefined,
      UPDATE_PRIORITY.UTILITY,
    );
  }

  const engine: Engine = {
    camera,
    add(layer, drawable) {
      scene.add(layer, drawable);
      layerOf.set(drawable.id, layer);
      containers[layer].addChild(drawable.view);
    },
    remove(id) {
      const drawable = scene.remove(id);
      if (drawable === undefined) return;
      const layer = layerOf.get(id);
      layerOf.delete(id);
      if (layer !== undefined) containers[layer].removeChild(drawable.view);
      if (selectedId === id) selectedId = null;
    },
    moved(id) {
      scene.moved(id);
    },
    spring(initial: number, config?: SpringConfig): Spring {
      const s = new SpringImpl(initial, config);
      s.reducedMotion = camera.reducedMotion;
      springList.add(new WeakRef(s));
      return s;
    },
    onFrame(callback) {
      frameCallbacks.add(callback);
      return () => frameCallbacks.delete(callback);
    },
    onIntent(callback) {
      intentCallbacks.add(callback);
      return () => intentCallbacks.delete(callback);
    },
    destroy() {
      abort.abort();
      frameCallbacks.clear();
      intentCallbacks.clear();
      overlay?.destroy();
      app.destroy({ removeView: true }, { children: true });
    },
  };
  registerInternals(engine, { resolution: app.renderer.resolution });
  return engine;
};

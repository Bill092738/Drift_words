import { Application, Container } from 'pixi.js';
import type {
  CreateEngine,
  Drawable,
  Engine,
  FrameInfo,
  Intent,
  LayerName,
  Rect,
  Spring,
  SpringConfig,
  Vec,
} from './api.ts';
import { CameraImpl } from './camera.ts';
import { GestureRecognizer, wheelZoomFactor } from './gestures.ts';
import { SpringImpl } from './spring.ts';

/** Back to front. */
const LAYERS: readonly LayerName[] = ['sources', 'edges', 'words', 'focus', 'hud'];
/** Frames longer than this are treated as this long, so a background tab does not cause a jump. */
const MAX_DT = 0.1;

const intersects = (a: Rect, b: Rect): boolean =>
  a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY;

const contains = (r: Rect, p: Vec): boolean =>
  p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY;

const prefersDark = (): boolean =>
  typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches;

interface Entry {
  layer: LayerName;
  drawable: Drawable;
}

export const createEngine: CreateEngine = async (host, options = {}) => {
  const { preferWebGPU = true, maxResolution = 2 } = options;

  const app = new Application();
  await app.init({
    resizeTo: host,
    // Pixi falls back to WebGL when WebGPU is not available.
    preference: preferWebGPU ? 'webgpu' : 'webgl',
    resolution: Math.min(window.devicePixelRatio || 1, maxResolution),
    autoDensity: true,
    antialias: true,
    background: prefersDark() ? 0x151517 : 0xf6f5f2,
  });
  host.appendChild(app.canvas);
  app.canvas.style.touchAction = 'none';
  app.canvas.style.display = 'block';

  const camera = new CameraImpl();

  // The world container follows the camera; the hud container stays in screen space.
  const world = new Container();
  const containers = {} as Record<LayerName, Container>;
  for (const name of LAYERS) {
    const c = new Container({ label: name });
    containers[name] = c;
    (name === 'hud' ? app.stage : world).addChild(c);
  }
  app.stage.addChildAt(world, 0);

  const members = {} as Record<LayerName, Map<string, Drawable>>;
  for (const name of LAYERS) members[name] = new Map();
  const entries = new Map<string, Entry>();

  const springList = new Set<WeakRef<SpringImpl>>();
  const frameCallbacks = new Set<(frame: FrameInfo) => void>();
  const intentCallbacks = new Set<(intent: Intent) => void>();
  let selectedId: string | null = null;
  let time = 0;

  const emit = (intent: Intent): void => {
    for (const cb of intentCallbacks) cb(intent);
  };

  // Linear scans for now; milestone work later replaces them with an rbush index.
  const hitTest = (screen: Vec): string | null => {
    const worldPoint = camera.screenToWorld(screen);
    for (let i = LAYERS.length - 1; i >= 0; i--) {
      const layer = LAYERS[i]!;
      const point = layer === 'hud' ? screen : worldPoint;
      let hit: string | null = null;
      for (const d of members[layer].values()) {
        if (d.interactive && contains(d.bounds(), point)) hit = d.id; // later = on top
      }
      if (hit !== null) return hit;
    }
    return null;
  };

  const handleTap = (screen: Vec): void => {
    const id = hitTest(screen);
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
      canvas.setPointerCapture(e.pointerId);
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

  app.ticker.add((ticker) => {
    const dt = Math.min(ticker.deltaMS / 1000, MAX_DT);
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

    const viewport = camera.viewport;
    for (const name of LAYERS) {
      if (name === 'hud') continue;
      for (const d of members[name].values()) d.view.visible = intersects(d.bounds(), viewport);
    }
  });

  const engine: Engine = {
    camera,
    add(layer, drawable) {
      if (entries.has(drawable.id)) throw new Error(`drawable "${drawable.id}" already added`);
      entries.set(drawable.id, { layer, drawable });
      members[layer].set(drawable.id, drawable);
      containers[layer].addChild(drawable.view);
    },
    remove(id) {
      const entry = entries.get(id);
      if (entry === undefined) return;
      entries.delete(id);
      members[entry.layer].delete(id);
      containers[entry.layer].removeChild(entry.drawable.view);
      if (selectedId === id) selectedId = null;
    },
    moved() {
      // Nothing to re-index until the spatial index lands.
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
      app.destroy({ removeView: true }, { children: true });
    },
  };
  return engine;
};

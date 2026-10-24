// TEMPORARY: a minimal implementation of the engine API so the desk (M4) can
// be built before the M3 engine lands. It has a camera with springs, pan with
// inertia, wheel and pinch zoom, and tap intents. It has no culling, spatial
// index, text LOD or perf overlay; those are M3's job. When M3 lands, replace
// `createStubEngine` with M3's `createEngine` in Desk.tsx and delete this file.
import { Application, Container } from 'pixi.js';
import type {
  Camera,
  Drawable,
  Engine,
  EngineOptions,
  FrameInfo,
  Intent,
  LayerName,
  Rect,
  Spring,
  SpringConfig,
  Vec,
} from '../engine/api.ts';
import { springs } from '../engine/api.ts';
import { SpringValue } from '../motion/spring.ts';

const LAYERS: readonly LayerName[] = ['sources', 'edges', 'words', 'focus', 'hud'];
const TAP_SLOP_PX = 6;
const MIN_ZOOM = 0.25;
const MAX_ZOOM = 3;
/** Seconds of pan velocity carried into the glide after a drag ends. */
const PAN_INERTIA_S = 0.35;
/** World units per grid cell of the CSS desk background. */
const GRID = 24;

class SpringHandle implements Spring {
  readonly s: SpringValue;
  constructor(initial: number, config: SpringConfig) {
    this.s = new SpringValue(initial, config);
  }
  get value() {
    return this.s.value;
  }
  get velocity() {
    return this.s.velocity;
  }
  get target() {
    return this.s.target;
  }
  get settled() {
    return this.s.settled;
  }
  to(target: number, config?: SpringConfig) {
    if (config) this.s.configure(config);
    this.s.target = target;
  }
  snap(value: number) {
    this.s.snap(value);
  }
}

export async function createStubEngine(host: HTMLElement, options: EngineOptions = {}): Promise<Engine> {
  const app = new Application();
  await app.init({
    resizeTo: host,
    backgroundAlpha: 0,
    antialias: true,
    autoDensity: true,
    resolution: Math.min(window.devicePixelRatio || 1, options.maxResolution ?? 2),
    preference: options.preferWebGPU === false ? 'webgl' : 'webgpu',
  });
  host.appendChild(app.canvas);
  app.canvas.style.touchAction = 'none';

  const world = new Container();
  const hud = new Container();
  const layers = new Map<LayerName, Container>();
  for (const name of LAYERS) {
    const layer = new Container();
    layer.sortableChildren = true;
    layers.set(name, layer);
    (name === 'hud' ? hud : world).addChild(layer);
  }
  app.stage.addChild(world, hud);

  const drawables = new Map<string, { d: Drawable; layer: LayerName }>();
  const springsList = new Set<SpringHandle>();
  const frameCallbacks = new Set<(f: FrameInfo) => void>();
  const intentCallbacks = new Set<(i: Intent) => void>();

  // Camera ------------------------------------------------------------------
  const cx = new SpringValue(0, springs.smooth, 0.01);
  const cy = new SpringValue(0, springs.smooth, 0.01);
  const cz = new SpringValue(1, springs.smooth, 0.0001);
  const size = () => ({ w: app.screen.width, h: app.screen.height });

  const camera: Camera = {
    get center() {
      return { x: cx.value, y: cy.value };
    },
    get zoom() {
      return cz.value;
    },
    get viewport(): Rect {
      const { w, h } = size();
      const z = cz.value;
      return { minX: cx.value - w / 2 / z, minY: cy.value - h / 2 / z, maxX: cx.value + w / 2 / z, maxY: cy.value + h / 2 / z };
    },
    glideTo(center: Vec, zoom?: number, config: SpringConfig = springs.smooth) {
      cx.configure(config);
      cy.configure(config);
      cx.target = center.x;
      cy.target = center.y;
      if (zoom !== undefined) {
        cz.configure(config);
        cz.target = clampZoom(zoom);
      }
    },
    worldToScreen(p: Vec): Vec {
      const { w, h } = size();
      return { x: (p.x - cx.value) * cz.value + w / 2, y: (p.y - cy.value) * cz.value + h / 2 };
    },
    screenToWorld(p: Vec): Vec {
      const { w, h } = size();
      return { x: (p.x - w / 2) / cz.value + cx.value, y: (p.y - h / 2) / cz.value + cy.value };
    },
  };

  const clampZoom = (z: number) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z));

  const applyCamera = () => {
    const { w, h } = size();
    const z = cz.value;
    world.scale.set(z);
    world.position.set(w / 2 - cx.value * z, h / 2 - cy.value * z);
    // The dotted desk background is CSS on the host; move it with the camera.
    const cell = GRID * z;
    host.style.backgroundSize = `${cell}px ${cell}px`;
    host.style.backgroundPosition = `${w / 2 - cx.value * z}px ${h / 2 - cy.value * z}px`;
  };

  // Input -------------------------------------------------------------------
  const pointers = new Map<number, Vec>();
  let gesture: {
    start: Vec;
    startTime: number;
    moved: boolean;
    samples: { t: number; x: number; y: number }[];
    pinch?: { distance: number; zoom: number; mid: Vec };
  } | null = null;

  const local = (e: PointerEvent | WheelEvent): Vec => {
    const r = app.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  /** Moves the camera so that world point `world` sits under screen point `screen`. */
  const pinTo = (world: Vec, screen: Vec, zoom: number) => {
    const { w, h } = size();
    const z = clampZoom(zoom);
    cz.snap(z);
    cx.snap(world.x - (screen.x - w / 2) / z);
    cy.snap(world.y - (screen.y - h / 2) / z);
  };

  const hitTest = (p: Vec): Drawable | undefined => {
    // Front-most layer first, then the most recently added.
    for (const name of [...LAYERS].reverse()) {
      const hits = [...drawables.values()].filter(({ d, layer }) => layer === name && d.interactive && d.view.visible);
      for (const { d } of hits.reverse()) {
        const b = d.bounds();
        if (p.x >= b.minX && p.x <= b.maxX && p.y >= b.minY && p.y <= b.maxY) return d;
      }
    }
    return undefined;
  };

  const emit = (i: Intent) => intentCallbacks.forEach((cb) => cb(i));

  const onDown = (e: PointerEvent) => {
    app.canvas.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, local(e));
    const p = local(e);
    if (pointers.size === 1) {
      gesture = { start: p, startTime: e.timeStamp, moved: false, samples: [{ t: e.timeStamp, ...p }] };
    } else if (pointers.size === 2 && gesture) {
      const [a, b] = [...pointers.values()] as [Vec, Vec];
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      gesture.moved = true;
      gesture.pinch = { distance: Math.hypot(a.x - b.x, a.y - b.y), zoom: cz.value, mid: camera.screenToWorld(mid) };
    }
  };

  const onMove = (e: PointerEvent) => {
    if (!pointers.has(e.pointerId) || gesture === null) return;
    const prev = pointers.get(e.pointerId) as Vec;
    const p = local(e);
    pointers.set(e.pointerId, p);
    if (gesture.pinch && pointers.size >= 2) {
      const [a, b] = [...pointers.values()] as [Vec, Vec];
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      pinTo(gesture.pinch.mid, mid, (gesture.pinch.zoom * Math.hypot(a.x - b.x, a.y - b.y)) / gesture.pinch.distance);
      return;
    }
    if (Math.hypot(p.x - gesture.start.x, p.y - gesture.start.y) > TAP_SLOP_PX) gesture.moved = true;
    if (gesture.moved) {
      cx.snap(cx.value - (p.x - prev.x) / cz.value);
      cy.snap(cy.value - (p.y - prev.y) / cz.value);
    }
    gesture.samples.push({ t: e.timeStamp, ...p });
    if (gesture.samples.length > 6) gesture.samples.shift();
  };

  const onUp = (e: PointerEvent) => {
    pointers.delete(e.pointerId);
    const g = gesture;
    if (g === null || pointers.size > 0) {
      if (g?.pinch && pointers.size === 1) {
        // Continue as a pan with the remaining finger.
        const p = [...pointers.values()][0] as Vec;
        gesture = { start: p, startTime: e.timeStamp, moved: true, samples: [{ t: e.timeStamp, ...p }] };
      }
      return;
    }
    gesture = null;
    if (!g.moved) {
      const world = camera.screenToWorld(local(e));
      const hit = hitTest(world);
      emit(hit ? { type: 'select', id: hit.id } : { type: 'background', at: world });
      return;
    }
    if (g.pinch) return;
    const first = g.samples[0];
    const last = g.samples[g.samples.length - 1];
    if (first && last && last.t > first.t) {
      const dt = (last.t - first.t) / 1000;
      const vx = (last.x - first.x) / dt / cz.value;
      const vy = (last.y - first.y) / dt / cz.value;
      cx.configure(springs.smooth);
      cy.configure(springs.smooth);
      cx.target = cx.value - vx * PAN_INERTIA_S;
      cy.target = cy.value - vy * PAN_INERTIA_S;
    }
  };

  const onWheel = (e: WheelEvent) => {
    e.preventDefault();
    const screen = local(e);
    const world = camera.screenToWorld(screen);
    // Trackpad pinch arrives as ctrl+wheel with small deltas.
    const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015));
    pinTo(world, screen, cz.value * factor);
  };

  app.canvas.addEventListener('pointerdown', onDown);
  app.canvas.addEventListener('pointermove', onMove);
  app.canvas.addEventListener('pointerup', onUp);
  app.canvas.addEventListener('pointercancel', onUp);
  app.canvas.addEventListener('wheel', onWheel, { passive: false });

  // Clock -------------------------------------------------------------------
  let time = 0;
  const tick = () => {
    const dt = Math.min(app.ticker.deltaMS / 1000, 0.1);
    time += dt;
    cx.step(dt);
    cy.step(dt);
    cz.step(dt);
    for (const s of springsList) s.s.step(dt);
    const frame = { dt, time };
    frameCallbacks.forEach((cb) => cb(frame));
    applyCamera();
  };
  app.ticker.add(tick);
  applyCamera();

  return {
    camera,
    add(layer, d) {
      drawables.set(d.id, { d, layer });
      (layers.get(layer) as Container).addChild(d.view);
    },
    remove(id) {
      const entry = drawables.get(id);
      if (!entry) return;
      entry.d.view.removeFromParent();
      drawables.delete(id);
    },
    moved() {
      // No spatial index in the stub.
    },
    spring(initial, config = springs.smooth) {
      const s = new SpringHandle(initial, config);
      springsList.add(s);
      return s;
    },
    onFrame(cb) {
      frameCallbacks.add(cb);
      return () => frameCallbacks.delete(cb);
    },
    onIntent(cb) {
      intentCallbacks.add(cb);
      return () => intentCallbacks.delete(cb);
    },
    destroy() {
      app.ticker.remove(tick);
      app.canvas.removeEventListener('pointerdown', onDown);
      app.canvas.removeEventListener('pointermove', onMove);
      app.canvas.removeEventListener('pointerup', onUp);
      app.canvas.removeEventListener('pointercancel', onUp);
      app.canvas.removeEventListener('wheel', onWheel);
      frameCallbacks.clear();
      intentCallbacks.clear();
      app.destroy({ removeView: true }, { children: true });
    },
  };
}

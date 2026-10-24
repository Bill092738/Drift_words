// The engine API: the contract between FE-Engine (which implements it in M3)
// and FE-Desk (which builds the Driftwords scene on top of it in M4).
//
// The engine knows nothing about words, trees or sources. It owns the canvas,
// the camera, the clock, springs, input and culling, and reports what the user
// did as semantic intents. Changes here must be agreed by both tracks.
import type { Container } from 'pixi.js';

export interface Vec {
  x: number;
  y: number;
}

/** Axis-aligned rectangle in world units. */
export interface Rect {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

/**
 * Spring parameters in the style of Apple's spring animations: `response` is
 * roughly the period in seconds, `dampingFraction` 1 is critically damped
 * (no overshoot) and lower values overshoot.
 */
export interface SpringConfig {
  response: number;
  dampingFraction: number;
}

export const springs = {
  /** Camera glides and sidebar motion. */
  smooth: { response: 0.55, dampingFraction: 1 },
  /** Selection scale and dimming. */
  snappy: { response: 0.3, dampingFraction: 0.9 },
  /** Objects landing on the desk. */
  bouncy: { response: 0.5, dampingFraction: 0.65 },
} as const satisfies Record<string, SpringConfig>;

/**
 * A value that moves toward its target. Springs are advanced by the engine's
 * clock; retargeting mid-flight keeps velocity, so motion is interruptible.
 */
export interface Spring {
  readonly value: number;
  readonly velocity: number;
  readonly target: number;
  readonly settled: boolean;
  /** Moves toward a new target, keeping the current velocity. */
  to(target: number, config?: SpringConfig): void;
  /** Jumps to a value with zero velocity. */
  snap(value: number): void;
}

export interface Camera {
  /** World point at the center of the screen. */
  readonly center: Vec;
  readonly zoom: number;
  /** The world-space rectangle currently on screen. */
  readonly viewport: Rect;
  /** Glides to a world point (and optionally a zoom) with a spring. */
  glideTo(center: Vec, zoom?: number, config?: SpringConfig): void;
  worldToScreen(p: Vec): Vec;
  screenToWorld(p: Vec): Vec;
}

/** Back to front. `hud` is in screen space; the others move with the camera. */
export type LayerName = 'sources' | 'edges' | 'words' | 'focus' | 'hud';

/** Anything the engine draws, culls and hit-tests. */
export interface Drawable {
  readonly id: string;
  readonly view: Container;
  /** World-space bounds, used for culling and hit testing. */
  bounds(): Rect;
  /** Whether taps on it produce intents. */
  readonly interactive: boolean;
  /**
   * Static drawables live in the spatial index and must call
   * {@link Engine.moved} when their bounds change. Moving ones (orbiting,
   * drifting) are checked directly every frame and should be few.
   */
  readonly moving: boolean;
}

/** What the user meant, after gesture recognition. */
export type Intent =
  | { type: 'select'; id: string } // tap on an interactive drawable
  | { type: 'open'; id: string } // second tap on an already selected drawable
  | { type: 'background'; at: Vec }; // tap on empty desk (world coordinates)

export interface FrameInfo {
  /** Seconds since the previous frame, clamped to avoid huge steps. */
  dt: number;
  /** Seconds since the engine started. */
  time: number;
}

export interface Engine {
  readonly camera: Camera;
  add(layer: LayerName, drawable: Drawable): void;
  remove(id: string): void;
  /** Re-indexes a static drawable after its bounds changed. */
  moved(id: string): void;
  /** Creates a spring advanced by the engine clock. */
  spring(initial: number, config?: SpringConfig): Spring;
  /** Runs every frame before rendering; returns an unsubscribe function. */
  onFrame(callback: (frame: FrameInfo) => void): () => void;
  onIntent(callback: (intent: Intent) => void): () => void;
  destroy(): void;
}

export interface EngineOptions {
  /** Prefer WebGPU, falling back to WebGL2. Default true. */
  preferWebGPU?: boolean;
  /** Device pixel ratio cap. Default 2. */
  maxResolution?: number;
  /** Shows frame time, draw calls and object counts. */
  perfOverlay?: boolean;
}

/** Implemented in M3. */
export type CreateEngine = (host: HTMLElement, options?: EngineOptions) => Promise<Engine>;

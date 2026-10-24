import type { Engine } from './api.ts';

/**
 * Facts about an engine that engine-side helpers (text LOD, for one) need but
 * the shared `Engine` interface does not carry. Kept off the interface on
 * purpose, so `api.ts` stays as agreed between the tracks.
 */
export interface EngineInternals {
  /** Renderer resolution: screen pixels per CSS pixel. */
  resolution: number;
}

const registry = new WeakMap<Engine, EngineInternals>();

export function registerInternals(engine: Engine, internals: EngineInternals): void {
  registry.set(engine, internals);
}

export function internalsOf(engine: Engine): EngineInternals {
  return registry.get(engine) ?? { resolution: Math.min(globalThis.devicePixelRatio || 1, 2) };
}

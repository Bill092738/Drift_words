// Parametric motion for things that move continuously: drifting cloud words and
// orbiting branch candidates. Pure functions of time, with no physics engine.
// The desk layer (M4) calls these from `engine.onFrame` and reports the new
// bounds; moving drawables (`moving: true`) are culled and hit-tested each frame.
import { createNoise2D } from 'simplex-noise';
import type { Vec } from './api.ts';

/** Small deterministic PRNG, so a scene or a noise field looks the same on every load. */
export function seededRandom(seed: number): () => number {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export interface DriftOptions {
  seed: number;
  /** Largest offset from the home position, in world units. Default 24. */
  amplitude?: number;
  /** Noise cycles per second; low values drift slowly. Default 0.15. */
  frequency?: number;
}

/**
 * A smooth, organic offset field. Give each object its own `phase` (any
 * number, such as its index) so neighbours do not move in step.
 * Offsets never exceed `amplitude` in either axis.
 */
export function createDrift(options: DriftOptions): (phase: number, time: number) => Vec {
  const { seed, amplitude = 24, frequency = 0.15 } = options;
  const noise = createNoise2D(seededRandom(seed));
  return (phase, time) => ({
    x: noise(phase * 0.7, time * frequency) * amplitude,
    y: noise(phase * 0.7 + 101.7, time * frequency) * amplitude,
  });
}

/** A point on a circle; angles in radians. */
export function orbitPoint(center: Vec, radius: number, angle: number): Vec {
  return { x: center.x + Math.cos(angle) * radius, y: center.y + Math.sin(angle) * radius };
}

/** Advances an orbit angle, wrapped to [0, 2π) so it never loses precision over a long session. */
export function advanceOrbit(angle: number, angularSpeed: number, dt: number): number {
  const full = Math.PI * 2;
  const next = (angle + angularSpeed * dt) % full;
  return next < 0 ? next + full : next;
}

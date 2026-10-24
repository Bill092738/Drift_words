// Pure layout functions for the word tree on the desk.
import type { Vec } from '../engine/api.ts';

/** Distance from a node to a newly placed child. */
export const CHILD_DISTANCE = 290;
/** Radius of the orbiting ring of branch words. */
export const RING_RADIUS = 150;
/**
 * Closest two nodes may sit to each other. Larger than the ring radius plus
 * about one word's width, so an orbiting ring never passes over another node.
 */
export const MIN_NODE_GAP = 260;

const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

export function polar(center: Vec, angle: number, radius: number): Vec {
  return { x: center.x + Math.cos(angle) * radius, y: center.y + Math.sin(angle) * radius };
}

export function angleOf(from: Vec, to: Vec): number {
  return Math.atan2(to.y - from.y, to.x - from.x);
}

export function distance(a: Vec, b: Vec): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

/** Angle of slot `i` of `n` on a ring rotated by `phase`. */
export function ringAngle(i: number, n: number, phase: number): number {
  return phase + (2 * Math.PI * i) / Math.max(n, 1);
}

/**
 * Scatters `n` points around `center` on a sunflower spiral with jitter, so
 * the cloud looks random but words never pile up. Deterministic for a given
 * `random`. `aspect` > 1 spreads the cloud wider than it is tall.
 */
export function cloudLayout(n: number, center: Vec, radius: number, random: () => number, aspect = 1.4): Vec[] {
  const points: Vec[] = [];
  for (let i = 0; i < n; i++) {
    const r = radius * Math.sqrt((i + 0.6) / n) * (0.9 + random() * 0.2);
    const a = i * GOLDEN_ANGLE + (random() - 0.5) * 0.5;
    points.push({ x: center.x + Math.cos(a) * r * Math.sqrt(aspect), y: center.y + Math.sin(a) * r / Math.sqrt(aspect) });
  }
  return points;
}

/**
 * Where to put a new child of `parent`, preferring the direction `angle`
 * (where the user picked it). If that spot is crowded, the angle is swung
 * alternately left and right in growing steps until it is clear.
 */
export function placeChild(
  parent: Vec,
  angle: number,
  occupied: readonly Vec[],
  dist = CHILD_DISTANCE,
  minGap = MIN_NODE_GAP,
): { pos: Vec; angle: number } {
  const step = Math.PI / 18;
  // Sweep the whole circle at the preferred distance, then further out.
  for (let ring = 0; ; ring++) {
    const r = dist * (1 + ring * 0.5);
    for (let k = 0; k < 36; k++) {
      const a = angle + (k % 2 === 1 ? 1 : -1) * Math.ceil(k / 2) * step;
      const pos = polar(parent, a, r);
      if (occupied.every((o) => distance(o, pos) >= minGap)) return { pos, angle: a };
    }
  }
}

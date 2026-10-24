import { describe, expect, it } from 'vitest';
import { MOVING_EVERY, SCENES, type SceneKind, generateScene } from './scenes.ts';

const kinds = Object.keys(SCENES) as SceneKind[];

describe('generateScene', () => {
  it('matches the roadmap object counts: 2000 on desktop, 600 on a phone', () => {
    expect(generateScene('small')).toHaveLength(50);
    expect(generateScene('desktop')).toHaveLength(2000);
    expect(generateScene('mobile')).toHaveLength(600);
  });

  it('is deterministic for a seed', () => {
    expect(generateScene('mobile', 3)).toEqual(generateScene('mobile', 3));
    expect(generateScene('mobile', 3)).not.toEqual(generateScene('mobile', 4));
  });

  it('has unique ids and finite positions', () => {
    for (const kind of kinds) {
      const scene = generateScene(kind);
      expect(new Set(scene.map((t) => t.id)).size).toBe(scene.length);
      for (const t of scene) {
        expect(Number.isFinite(t.x) && Number.isFinite(t.y)).toBe(true);
        expect(t.label.length).toBeGreaterThan(0);
      }
    }
  });

  it('includes moving tiles, both drifting and orbiting', () => {
    for (const kind of kinds) {
      const scene = generateScene(kind);
      const moving = scene.filter((t) => t.motion.kind !== 'static');
      expect(moving).toHaveLength(Math.ceil(scene.length / MOVING_EVERY));
      expect(moving.some((t) => t.motion.kind === 'drift')).toBe(true);
      expect(moving.some((t) => t.motion.kind === 'orbit')).toBe(true);
    }
  });

  it('starts orbiting tiles on their orbit', () => {
    for (const t of generateScene('desktop')) {
      if (t.motion.kind !== 'orbit') continue;
      const { center, radius } = t.motion;
      expect(Math.hypot(t.x - center.x, t.y - center.y)).toBeCloseTo(radius, 9);
    }
  });

  it('uses plain English words only', () => {
    for (const t of generateScene('desktop')) expect(t.label).toMatch(/^[a-z]+$/);
  });
});

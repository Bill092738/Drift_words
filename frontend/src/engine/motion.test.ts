import { describe, expect, it } from 'vitest';
import { advanceOrbit, createDrift, orbitPoint, seededRandom } from './motion.ts';

describe('seededRandom', () => {
  it('repeats for a seed and differs between seeds', () => {
    const a = seededRandom(5);
    const b = seededRandom(5);
    const c = seededRandom(6);
    const first = [a(), a(), a()];
    expect([b(), b(), b()]).toEqual(first);
    expect([c(), c(), c()]).not.toEqual(first);
    expect(first.every((v) => v >= 0 && v < 1)).toBe(true);
  });
});

describe('createDrift', () => {
  it('is deterministic for a seed', () => {
    const a = createDrift({ seed: 1 });
    const b = createDrift({ seed: 1 });
    expect(a(3, 12.5)).toEqual(b(3, 12.5));
  });

  it('stays within the amplitude', () => {
    const drift = createDrift({ seed: 2, amplitude: 10 });
    for (let phase = 0; phase < 20; phase++) {
      for (let t = 0; t < 60; t += 0.7) {
        const o = drift(phase, t);
        expect(Math.abs(o.x)).toBeLessThanOrEqual(10);
        expect(Math.abs(o.y)).toBeLessThanOrEqual(10);
      }
    }
  });

  it('moves smoothly: a 16 ms step is a tiny change', () => {
    const drift = createDrift({ seed: 3, amplitude: 24, frequency: 0.15 });
    for (let t = 0; t < 30; t += 0.5) {
      const a = drift(4, t);
      const b = drift(4, t + 0.016);
      expect(Math.hypot(a.x - b.x, a.y - b.y)).toBeLessThan(0.5);
    }
  });

  it('gives different objects different paths', () => {
    const drift = createDrift({ seed: 4 });
    expect(drift(1, 5)).not.toEqual(drift(2, 5));
  });
});

describe('orbit', () => {
  it('keeps a constant radius around the center', () => {
    const center = { x: 100, y: -50 };
    for (const angle of [0, 1, 2.5, 4, 6]) {
      const p = orbitPoint(center, 80, angle);
      expect(Math.hypot(p.x - center.x, p.y - center.y)).toBeCloseTo(80, 9);
    }
  });

  it('advances and wraps the angle', () => {
    expect(advanceOrbit(0, Math.PI, 0.5)).toBeCloseTo(Math.PI / 2, 12);
    expect(advanceOrbit(6, 1, 1)).toBeCloseTo(7 - Math.PI * 2, 12);
    expect(advanceOrbit(0.1, -1, 1)).toBeGreaterThanOrEqual(0);
    expect(advanceOrbit(1, 1e9, 1)).toBeLessThan(Math.PI * 2);
  });
});

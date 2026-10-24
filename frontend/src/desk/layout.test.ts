import { describe, expect, it } from 'vitest';
import { rng } from '../transport/wordbank.ts';
import { CHILD_DISTANCE, cloudLayout, distance, MIN_NODE_GAP, placeChild, ringAngle } from './layout.ts';

describe('cloudLayout', () => {
  it('is deterministic and keeps words apart', () => {
    const a = cloudLayout(12, { x: 0, y: 0 }, 300, rng(3));
    const b = cloudLayout(12, { x: 0, y: 0 }, 300, rng(3));
    expect(a).toEqual(b);
    const gaps = a.flatMap((p, i) => a.slice(i + 1).map((q) => distance(p, q)));
    expect(Math.min(...gaps)).toBeGreaterThan(40);
  });
});

describe('ringAngle', () => {
  it('spaces slots evenly from the phase', () => {
    expect(ringAngle(0, 4, 1)).toBe(1);
    expect(ringAngle(2, 4, 0)).toBeCloseTo(Math.PI);
  });
});

describe('placeChild', () => {
  it('uses the preferred direction when it is free', () => {
    const { pos, angle } = placeChild({ x: 0, y: 0 }, 0, []);
    expect(angle).toBe(0);
    expect(pos.x).toBeCloseTo(CHILD_DISTANCE);
    expect(pos.y).toBeCloseTo(0);
  });

  it('swings away from occupied spots', () => {
    const blocked = { x: CHILD_DISTANCE, y: 0 };
    const { pos } = placeChild({ x: 0, y: 0 }, 0, [{ x: 0, y: 0 }, blocked]);
    expect(distance(pos, blocked)).toBeGreaterThanOrEqual(MIN_NODE_GAP);
    expect(distance(pos, { x: 0, y: 0 })).toBeCloseTo(CHILD_DISTANCE);
  });

  it('never lands on top of an existing node in a crowded neighbourhood', () => {
    const random = rng(9);
    const occupied = [{ x: 0, y: 0 }];
    for (let i = 0; i < 40; i++) {
      const parent = occupied[Math.floor(random() * occupied.length)]!;
      const { pos } = placeChild(parent, random() * Math.PI * 2, occupied);
      expect(occupied.every((o) => distance(o, pos) >= MIN_NODE_GAP - 1e-6)).toBe(true);
      occupied.push(pos);
    }
  });
});

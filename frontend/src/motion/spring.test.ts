import { describe, expect, it } from 'vitest';
import { springs } from '../engine/api.ts';
import { SpringValue } from './spring.ts';

function run(s: SpringValue, seconds: number, fps = 60): number[] {
  const values: number[] = [];
  for (let t = 0; t < seconds; t += 1 / fps) {
    s.step(1 / fps);
    values.push(s.value);
  }
  return values;
}

describe('SpringValue', () => {
  it('reaches its target and comes to rest', () => {
    const s = new SpringValue(0, springs.smooth);
    s.target = 1;
    run(s, 2);
    expect(s.value).toBe(1);
    expect(s.settled).toBe(true);
  });

  it('does not overshoot when critically damped', () => {
    const s = new SpringValue(0, springs.smooth);
    s.target = 1;
    expect(Math.max(...run(s, 2))).toBeLessThanOrEqual(1);
  });

  it('overshoots when underdamped', () => {
    const s = new SpringValue(0, springs.bouncy);
    s.target = 1;
    expect(Math.max(...run(s, 2))).toBeGreaterThan(1.01);
  });

  it('is independent of frame rate', () => {
    const a = new SpringValue(0, springs.snappy);
    const b = new SpringValue(0, springs.snappy);
    a.target = b.target = 100;
    run(a, 0.25, 30);
    run(b, 0.25, 144);
    expect(Math.abs(a.value - b.value)).toBeLessThan(2);
  });

  it('keeps velocity when retargeted mid-flight', () => {
    const s = new SpringValue(0, springs.smooth);
    s.target = 1;
    run(s, 0.1);
    const v = s.velocity;
    s.target = 2;
    expect(s.velocity).toBe(v);
    expect(v).toBeGreaterThan(0);
  });
});

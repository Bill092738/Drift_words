import { describe, expect, it } from 'vitest';
import { springs } from './api.ts';
import { SpringImpl } from './spring.ts';

function run(spring: SpringImpl, seconds: number, dt = 1 / 60): number[] {
  const values: number[] = [];
  for (let t = 0; t < seconds; t += dt) {
    spring.step(dt);
    values.push(spring.value);
  }
  return values;
}

describe('SpringImpl', () => {
  it('starts settled at its initial value', () => {
    const s = new SpringImpl(5);
    expect(s.value).toBe(5);
    expect(s.settled).toBe(true);
  });

  it('reaches the target and settles', () => {
    const s = new SpringImpl(0, springs.smooth);
    s.to(100);
    run(s, 3);
    expect(s.value).toBe(100);
    expect(s.settled).toBe(true);
  });

  it('does not overshoot when critically damped', () => {
    const s = new SpringImpl(0, springs.smooth);
    s.to(100);
    expect(Math.max(...run(s, 3))).toBeLessThanOrEqual(100.0001);
  });

  it('overshoots when under-damped', () => {
    const s = new SpringImpl(0, springs.bouncy);
    s.to(100);
    expect(Math.max(...run(s, 3))).toBeGreaterThan(101);
  });

  it('keeps velocity when retargeted mid-flight', () => {
    const s = new SpringImpl(0, springs.smooth);
    s.to(100);
    run(s, 0.2);
    const v = s.velocity;
    expect(v).toBeGreaterThan(0);
    s.to(-100);
    expect(s.velocity).toBe(v);
    run(s, 4);
    expect(s.value).toBe(-100);
  });

  it('snap jumps with zero velocity', () => {
    const s = new SpringImpl(0);
    s.to(100);
    run(s, 0.1);
    s.snap(7);
    expect(s.value).toBe(7);
    expect(s.target).toBe(7);
    expect(s.velocity).toBe(0);
    expect(s.settled).toBe(true);
  });

  it('gives the same result at different frame rates', () => {
    const a = new SpringImpl(0, springs.snappy);
    const b = new SpringImpl(0, springs.snappy);
    a.to(50);
    b.to(50);
    run(a, 0.5, 1 / 30);
    run(b, 0.5, 1 / 120);
    expect(Math.abs(a.value - b.value)).toBeLessThan(0.5);
  });

  it('survives a very long frame', () => {
    const s = new SpringImpl(0);
    s.to(10);
    s.step(60);
    expect(Number.isFinite(s.value)).toBe(true);
  });
});

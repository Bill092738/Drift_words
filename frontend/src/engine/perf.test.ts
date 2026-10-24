import { describe, expect, it } from 'vitest';
import { Samples, formatPerf } from './perf.ts';

describe('Samples', () => {
  it('summarizes average, p95 and max', () => {
    const s = new Samples();
    for (let i = 1; i <= 100; i++) s.add(i);
    expect(s.summary()).toEqual({ count: 100, avg: 50.5, p95: 95, max: 100 });
  });

  it('handles empty and single samples', () => {
    const s = new Samples();
    expect(s.summary()).toEqual({ count: 0, avg: 0, p95: 0, max: 0 });
    s.add(7);
    expect(s.summary()).toEqual({ count: 1, avg: 7, p95: 7, max: 7 });
  });

  it('clears', () => {
    const s = new Samples();
    s.add(1);
    s.clear();
    expect(s.count).toBe(0);
  });
});

describe('formatPerf', () => {
  const sum = (avg: number) => ({ count: 30, avg, p95: avg * 1.5, max: avg * 2 });

  it('reports fps from frames over seconds and keeps logic apart from frame time', () => {
    const text = formatPerf({
      renderer: 'webgl2',
      frame: sum(16),
      logic: sum(1),
      render: sum(3),
      visible: 120,
      total: 2000,
      seconds: 0.5,
    });
    expect(text).toContain('renderer  webgl2');
    expect(text).toContain('fps       60.0');
    expect(text).toContain('frame     16.0 avg · 24.0 p95 · 32.0 max ms');
    expect(text).toContain('logic     1.0 avg · 2.0 max ms');
    expect(text).toContain('objects   120 visible / 2000');
  });

  it('does not invent a draw call count', () => {
    const text = formatPerf({
      renderer: 'webgpu',
      frame: sum(16),
      logic: sum(1),
      render: sum(1),
      visible: 1,
      total: 1,
      seconds: 1,
    });
    expect(text.toLowerCase()).not.toContain('draw call');
  });
});

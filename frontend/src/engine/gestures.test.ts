import { describe, expect, it } from 'vitest';
import { GestureRecognizer, TAP_MAX_MS, wheelZoomFactor } from './gestures.ts';

function setup() {
  const log: string[] = [];
  const pans: [number, number][] = [];
  const zooms: [number, number, number][] = [];
  const g = new GestureRecognizer({
    pan: (dx, dy) => pans.push([dx, dy]),
    zoom: (f, at) => zooms.push([f, at.x, at.y]),
    tap: (at) => log.push(`tap ${at.x},${at.y}`),
  });
  return { g, log, pans, zooms };
}

describe('GestureRecognizer', () => {
  it('recognizes a tap', () => {
    const { g, log, pans } = setup();
    g.pointerDown(1, { x: 10, y: 10 }, 0);
    g.pointerUp(1, { x: 10, y: 10 }, 100);
    expect(log).toEqual(['tap 10,10']);
    expect(pans).toEqual([]);
  });

  it('tolerates small jitter in a tap', () => {
    const { g, log, pans } = setup();
    g.pointerDown(1, { x: 10, y: 10 }, 0);
    g.pointerMove(1, { x: 13, y: 12 });
    g.pointerUp(1, { x: 13, y: 12 }, 100);
    expect(log).toHaveLength(1);
    expect(pans).toEqual([]);
  });

  it('does not tap after a long press', () => {
    const { g, log } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerUp(1, { x: 0, y: 0 }, TAP_MAX_MS + 1);
    expect(log).toEqual([]);
  });

  it('pans, including the movement spent inside the slop, and never taps', () => {
    const { g, log, pans } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerMove(1, { x: 20, y: 0 });
    g.pointerMove(1, { x: 25, y: 5 });
    g.pointerUp(1, { x: 25, y: 5 }, 100);
    expect(pans).toEqual([
      [20, 0],
      [5, 5],
    ]);
    expect(log).toEqual([]);
  });

  it('ignores moves from unknown pointers', () => {
    const { g, pans } = setup();
    g.pointerMove(9, { x: 100, y: 100 });
    expect(pans).toEqual([]);
  });

  it('pinches: zoom by the distance ratio around the midpoint', () => {
    const { g, zooms, pans } = setup();
    g.pointerDown(1, { x: 100, y: 100 }, 0);
    g.pointerDown(2, { x: 200, y: 100 }, 0);
    g.pointerMove(2, { x: 300, y: 100 });
    expect(zooms).toEqual([[2, 200, 100]]);
    expect(pans).toEqual([[50, 0]]);
  });

  it('is not a tap if a second finger ever touched', () => {
    const { g, log } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerDown(2, { x: 50, y: 0 }, 10);
    g.pointerUp(2, { x: 50, y: 0 }, 20);
    g.pointerUp(1, { x: 0, y: 0 }, 30);
    expect(log).toEqual([]);
  });

  it('keeps panning with the remaining finger after a pinch, without a jump', () => {
    const { g, pans } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerDown(2, { x: 100, y: 0 }, 0);
    g.pointerUp(2, { x: 100, y: 0 }, 10);
    g.pointerMove(1, { x: 3, y: 0 });
    expect(pans).toEqual([[3, 0]]);
  });

  it('cancel drops the gesture', () => {
    const { g, log } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerCancel(1);
    g.pointerUp(1, { x: 0, y: 0 }, 10);
    expect(log).toEqual([]);
  });
});

describe('wheelZoomFactor', () => {
  it('zooms in when scrolling up and out when scrolling down', () => {
    expect(wheelZoomFactor(-100, 0, false)).toBeGreaterThan(1);
    expect(wheelZoomFactor(100, 0, false)).toBeLessThan(1);
    expect(wheelZoomFactor(0, 0, false)).toBe(1);
  });

  it('is symmetric and more sensitive for trackpad pinch', () => {
    const a = wheelZoomFactor(-40, 0, false);
    expect(a * wheelZoomFactor(40, 0, false)).toBeCloseTo(1, 12);
    expect(wheelZoomFactor(-5, 0, true)).toBeGreaterThan(wheelZoomFactor(-5, 0, false));
  });

  it('scales line-based wheels', () => {
    expect(wheelZoomFactor(-3, 1, false)).toBeCloseTo(wheelZoomFactor(-48, 0, false), 12);
  });
});

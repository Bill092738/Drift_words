import { describe, expect, it } from 'vitest';
import {
  FLING_WINDOW_MS,
  GestureRecognizer,
  MAX_FLING_SPEED,
  TAP_MAX_MS,
  releaseVelocity,
  wheelZoomFactor,
} from './gestures.ts';

function setup() {
  const log: string[] = [];
  const pans: [number, number][] = [];
  const zooms: [number, number, number][] = [];
  const flings: [number, number][] = [];
  const g = new GestureRecognizer({
    pan: (dx, dy) => pans.push([dx, dy]),
    zoom: (f, at) => zooms.push([f, at.x, at.y]),
    tap: (at) => log.push(`tap ${at.x},${at.y}`),
    fling: (vx, vy) => flings.push([vx, vy]),
  });
  return { g, log, pans, zooms, flings };
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
    const { g, log, pans, flings } = setup();
    g.pointerDown(1, { x: 10, y: 10 }, 0);
    g.pointerMove(1, { x: 13, y: 12 }, 50);
    g.pointerUp(1, { x: 13, y: 12 }, 100);
    expect(log).toHaveLength(1);
    expect(pans).toEqual([]);
    expect(flings).toEqual([]);
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
    g.pointerMove(1, { x: 20, y: 0 }, 100);
    g.pointerMove(1, { x: 25, y: 5 }, 200);
    g.pointerUp(1, { x: 25, y: 5 }, 600);
    expect(pans).toEqual([
      [20, 0],
      [5, 5],
    ]);
    expect(log).toEqual([]);
  });

  it('ignores moves from unknown pointers', () => {
    const { g, pans } = setup();
    g.pointerMove(9, { x: 100, y: 100 }, 0);
    expect(pans).toEqual([]);
  });

  it('pinches: zoom by the distance ratio around the midpoint', () => {
    const { g, zooms, pans } = setup();
    g.pointerDown(1, { x: 100, y: 100 }, 0);
    g.pointerDown(2, { x: 200, y: 100 }, 0);
    g.pointerMove(2, { x: 300, y: 100 }, 16);
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
    g.pointerMove(1, { x: 3, y: 0 }, 20);
    expect(pans).toEqual([[3, 0]]);
  });

  it('cancel drops the gesture', () => {
    const { g, log, flings } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerCancel(1);
    g.pointerUp(1, { x: 0, y: 0 }, 10);
    expect(log).toEqual([]);
    expect(flings).toEqual([]);
  });

  it('flings with the release velocity after a fast drag', () => {
    const { g, flings, log } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerMove(1, { x: 50, y: 0 }, 50);
    g.pointerMove(1, { x: 100, y: 0 }, 100);
    g.pointerUp(1, { x: 100, y: 0 }, 105);
    expect(flings).toHaveLength(1);
    expect(flings[0]![0]).toBeCloseTo(1000, 6);
    expect(flings[0]![1]).toBeCloseTo(0, 6);
    expect(log).toEqual([]);
  });

  it('does not fling when the pointer rested before release', () => {
    const { g, flings } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerMove(1, { x: 50, y: 0 }, 50);
    g.pointerMove(1, { x: 100, y: 0 }, 100);
    g.pointerUp(1, { x: 100, y: 0 }, 100 + FLING_WINDOW_MS + 1);
    expect(flings).toEqual([]);
  });

  it('does not fling after a pinch', () => {
    const { g, flings } = setup();
    g.pointerDown(1, { x: 0, y: 0 }, 0);
    g.pointerDown(2, { x: 100, y: 0 }, 0);
    g.pointerUp(2, { x: 100, y: 0 }, 10);
    g.pointerMove(1, { x: 60, y: 0 }, 20);
    g.pointerUp(1, { x: 60, y: 0 }, 25);
    expect(flings).toEqual([]);
  });
});

describe('releaseVelocity', () => {
  const at = (x: number, y = 0) => ({ x, y });

  it('ignores samples older than the window', () => {
    const v = releaseVelocity(
      [
        { time: 0, at: at(0) },
        { time: 500, at: at(500) },
        { time: 550, at: at(600) },
      ],
      560,
    );
    expect(v?.x).toBeCloseTo(2000, 6);
  });

  it('returns null for a slow release', () => {
    expect(
      releaseVelocity(
        [
          { time: 0, at: at(0) },
          { time: 100, at: at(5) },
        ],
        100,
      ),
    ).toBeNull();
  });

  it('caps the speed but keeps the direction', () => {
    const v = releaseVelocity(
      [
        { time: 0, at: at(0, 0) },
        { time: 10, at: at(300, 400) },
      ],
      10,
    );
    expect(Math.hypot(v!.x, v!.y)).toBeCloseTo(MAX_FLING_SPEED, 6);
    expect(v!.x / v!.y).toBeCloseTo(0.75, 9);
  });

  it('returns null without samples', () => {
    expect(releaseVelocity([], 0)).toBeNull();
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

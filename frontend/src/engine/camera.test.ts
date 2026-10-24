import { describe, expect, it } from 'vitest';
import { CameraImpl, MAX_ZOOM, MIN_ZOOM } from './camera.ts';

function camera(): CameraImpl {
  const c = new CameraImpl();
  c.resize(800, 600);
  return c;
}

describe('CameraImpl', () => {
  it('maps the center to the middle of the screen', () => {
    const c = camera();
    expect(c.worldToScreen({ x: 0, y: 0 })).toEqual({ x: 400, y: 300 });
    expect(c.viewport).toEqual({ minX: -400, minY: -300, maxX: 400, maxY: 300 });
  });

  it('worldToScreen and screenToWorld are inverses', () => {
    const c = camera();
    c.panBy(-120, 45);
    c.zoomAt({ x: 100, y: 200 }, 2.5);
    const world = { x: 33, y: -71 };
    const back = c.screenToWorld(c.worldToScreen(world));
    expect(back.x).toBeCloseTo(world.x, 9);
    expect(back.y).toBeCloseTo(world.y, 9);
  });

  it('panBy moves the world with the pointer, independent of zoom', () => {
    const c = camera();
    c.zoomAt({ x: 400, y: 300 }, 2);
    const before = c.worldToScreen({ x: 10, y: 10 });
    c.panBy(30, -20);
    const after = c.worldToScreen({ x: 10, y: 10 });
    expect(after.x - before.x).toBeCloseTo(30, 9);
    expect(after.y - before.y).toBeCloseTo(-20, 9);
  });

  it('zoomAt keeps the world point under the pointer fixed', () => {
    const c = camera();
    const at = { x: 650, y: 120 };
    const anchor = c.screenToWorld(at);
    c.zoomAt(at, 3);
    expect(c.zoom).toBeCloseTo(3, 9);
    const screen = c.worldToScreen(anchor);
    expect(screen.x).toBeCloseTo(at.x, 9);
    expect(screen.y).toBeCloseTo(at.y, 9);
  });

  it('clamps zoom', () => {
    const c = camera();
    c.zoomAt({ x: 0, y: 0 }, 1e6);
    expect(c.zoom).toBeCloseTo(MAX_ZOOM, 9);
    c.zoomAt({ x: 0, y: 0 }, 1e-9);
    expect(c.zoom).toBeCloseTo(MIN_ZOOM, 9);
  });

  it('glideTo converges on the target center and zoom', () => {
    const c = camera();
    c.glideTo({ x: 500, y: -250 }, 2);
    expect(c.animating).toBe(true);
    for (let i = 0; i < 300; i++) c.step(1 / 60);
    expect(c.animating).toBe(false);
    expect(c.center).toEqual({ x: 500, y: -250 });
    expect(c.zoom).toBeCloseTo(2, 6);
  });

  describe('fling', () => {
    it('coasts in the drag direction, slows down and stops', () => {
      const c = camera();
      c.fling(-1000, 0); // finger moving left drags the desk left, so the view moves right
      c.step(1 / 60);
      const first = c.center.x;
      expect(first).toBeGreaterThan(0);
      c.step(1 / 60);
      const second = c.center.x - first;
      expect(second).toBeLessThan(first);
      for (let i = 0; i < 600; i++) c.step(1 / 60);
      expect(c.animating).toBe(false);
    });

    it('moves the same distance in screen pixels at any zoom', () => {
      const a = camera();
      const b = camera();
      b.zoomAt({ x: 400, y: 300 }, 4);
      a.fling(500, 0);
      b.fling(500, 0);
      for (let i = 0; i < 600; i++) {
        a.step(1 / 60);
        b.step(1 / 60);
      }
      expect(Math.abs(b.center.x * 4)).toBeCloseTo(Math.abs(a.center.x), 3);
    });

    it('stopFling and glideTo cancel it', () => {
      const c = camera();
      c.fling(800, 0);
      c.stopFling();
      c.step(0.1);
      expect(c.center.x).toBe(0);
      c.fling(800, 0);
      c.glideTo({ x: 10, y: 10 });
      for (let i = 0; i < 300; i++) c.step(1 / 60);
      expect(c.center).toEqual({ x: 10, y: 10 });
    });
  });

  describe('smooth wheel zoom', () => {
    it('eases toward the target instead of jumping, keeping the pointer anchor fixed', () => {
      const c = camera();
      const at = { x: 650, y: 120 };
      const anchor = c.screenToWorld(at);
      c.zoomAtSmooth(at, 2);
      expect(c.zoom).toBe(1);
      for (let i = 0; i < 6; i++) {
        c.step(1 / 60);
        const s = c.worldToScreen(anchor);
        expect(s.x).toBeCloseTo(at.x, 6);
        expect(s.y).toBeCloseTo(at.y, 6);
      }
      expect(c.zoom).toBeGreaterThan(1);
      expect(c.zoom).toBeLessThan(2);
      for (let i = 0; i < 120; i++) c.step(1 / 60);
      expect(c.zoom).toBeCloseTo(2, 6);
      expect(c.animating).toBe(false);
    });

    it('accumulates fast scrolling on the target and never overshoots', () => {
      const c = camera();
      const at = { x: 400, y: 300 };
      c.zoomAtSmooth(at, 1.5);
      c.step(1 / 60);
      c.zoomAtSmooth(at, 1.5);
      let max = 0;
      for (let i = 0; i < 240; i++) {
        c.step(1 / 60);
        max = Math.max(max, c.zoom);
      }
      expect(c.zoom).toBeCloseTo(2.25, 6);
      expect(max).toBeLessThanOrEqual(2.25 + 1e-6);
    });

    it('is cancelled by direct manipulation', () => {
      const c = camera();
      c.zoomAtSmooth({ x: 0, y: 0 }, 3);
      c.step(1 / 60);
      c.panBy(5, 5);
      const z = c.zoom;
      for (let i = 0; i < 60; i++) c.step(1 / 60);
      expect(c.zoom).toBe(z);
    });
  });

  describe('reduced motion', () => {
    it('glides, wheel zooms and flings land instantly or not at all', () => {
      const c = camera();
      c.reducedMotion = true;
      c.glideTo({ x: 40, y: -20 }, 2);
      expect(c.center).toEqual({ x: 40, y: -20 });
      expect(c.zoom).toBeCloseTo(2, 9);
      c.zoomAtSmooth({ x: 400, y: 300 }, 2);
      expect(c.zoom).toBeCloseTo(4, 9);
      c.fling(2000, 0);
      expect(c.animating).toBe(false);
    });
  });

  it('direct manipulation cancels a glide', () => {
    const c = camera();
    c.glideTo({ x: 500, y: 0 });
    c.step(0.1);
    c.panBy(10, 0);
    expect(c.animating).toBe(false);
    const x = c.center.x;
    c.step(1);
    expect(c.center.x).toBe(x);
  });
});

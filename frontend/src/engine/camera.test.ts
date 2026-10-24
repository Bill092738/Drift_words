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

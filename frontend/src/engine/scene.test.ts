import type { Container } from 'pixi.js';
import { describe, expect, it } from 'vitest';
import type { Drawable, LayerName, Rect } from './api.ts';
import { Scene } from './scene.ts';

interface Fake extends Drawable {
  rect: Rect;
  visible(): boolean;
}

function fake(
  id: string,
  rect: Rect,
  options: { moving?: boolean; interactive?: boolean } = {},
): Fake {
  const view = { visible: true } as unknown as Container;
  const d: Fake = {
    id,
    view,
    rect,
    bounds: () => d.rect,
    interactive: options.interactive ?? true,
    moving: options.moving ?? false,
    visible: () => view.visible,
  };
  return d;
}

const box = (x: number, y: number, size = 10): Rect => ({
  minX: x,
  minY: y,
  maxX: x + size,
  maxY: y + size,
});

const screenView: Rect = { minX: 0, minY: 0, maxX: 100, maxY: 100 };

function sceneOf(...items: [LayerName, Fake][]): Scene {
  const scene = new Scene();
  for (const [layer, d] of items) scene.add(layer, d);
  return scene;
}

describe('Scene culling', () => {
  it('shows only what intersects the viewport', () => {
    const a = fake('a', box(10, 10));
    const b = fake('b', box(500, 500));
    const scene = sceneOf(['words', a], ['words', b]);
    scene.cull(screenView);
    expect(a.visible()).toBe(true);
    expect(b.visible()).toBe(false);
    expect(scene.visible).toBe(1);
    expect(scene.total).toBe(2);
  });

  it('hides new drawables until they are proven on screen', () => {
    const a = fake('a', box(10, 10));
    sceneOf(['words', a]);
    expect(a.visible()).toBe(false);
  });

  it('brings an object back when the camera returns to it', () => {
    const a = fake('a', box(10, 10));
    const scene = sceneOf(['words', a]);
    scene.cull(screenView);
    scene.cull({ minX: 1000, minY: 1000, maxX: 1100, maxY: 1100 });
    expect(a.visible()).toBe(false);
    scene.cull(screenView);
    expect(a.visible()).toBe(true);
  });

  it('counts an object touching the viewport edge as visible', () => {
    const a = fake('a', box(100, 0));
    const scene = sceneOf(['words', a]);
    scene.cull(screenView);
    expect(a.visible()).toBe(true);
  });

  it('follows moving drawables without being told', () => {
    const m = fake('m', box(500, 0), { moving: true });
    const scene = sceneOf(['words', m]);
    scene.cull(screenView);
    expect(m.visible()).toBe(false);
    m.rect = box(20, 20);
    scene.cull(screenView);
    expect(m.visible()).toBe(true);
    m.rect = box(900, 900);
    scene.cull(screenView);
    expect(m.visible()).toBe(false);
  });

  it('re-indexes a static drawable after moved()', () => {
    const a = fake('a', box(500, 500));
    const scene = sceneOf(['words', a]);
    scene.cull(screenView);
    expect(a.visible()).toBe(false);
    a.rect = box(20, 20);
    scene.moved('a');
    scene.cull(screenView);
    expect(a.visible()).toBe(true);
    // The old position must no longer be indexed.
    a.rect = box(800, 800);
    scene.moved('a');
    scene.cull(screenView);
    expect(a.visible()).toBe(false);
    expect(scene.hit({ x: 0, y: 0 }, { x: 505, y: 505 })).toBeNull();
    expect(scene.hit({ x: 0, y: 0 }, { x: 805, y: 805 })).toBe('a');
  });

  it('forgets removed drawables, visible or not', () => {
    const a = fake('a', box(10, 10));
    const b = fake('b', box(500, 500));
    const scene = sceneOf(['words', a], ['words', b]);
    scene.cull(screenView);
    expect(scene.remove('a')).toBe(a);
    expect(scene.remove('b')).toBe(b);
    expect(scene.remove('nope')).toBeUndefined();
    expect(scene.total).toBe(0);
    expect(scene.visible).toBe(0);
    scene.cull(screenView);
    expect(scene.hit({ x: 0, y: 0 }, { x: 15, y: 15 })).toBeNull();
  });

  it('allows re-adding an id after removal', () => {
    const scene = sceneOf(['words', fake('a', box(10, 10))]);
    expect(() => scene.add('words', fake('a', box(0, 0)))).toThrow();
    scene.remove('a');
    const again = fake('a', box(30, 30));
    scene.add('words', again);
    scene.cull(screenView);
    expect(again.visible()).toBe(true);
  });

  it('keeps the hud visible and out of culling', () => {
    const h = fake('h', box(5000, 5000));
    const scene = sceneOf(['hud', h]);
    scene.cull({ minX: 0, minY: 0, maxX: 1, maxY: 1 });
    expect(h.visible()).toBe(true);
    expect(scene.visible).toBe(1);
  });
});

describe('Scene hit testing', () => {
  const at = (x: number, y: number) => ({ x, y });

  it('finds the drawable under a point and nothing in empty space', () => {
    const scene = sceneOf(['words', fake('a', box(10, 10))]);
    expect(scene.hit(at(0, 0), at(15, 15))).toBe('a');
    expect(scene.hit(at(0, 0), at(25, 25))).toBeNull();
  });

  it('includes the bounds edge', () => {
    const scene = sceneOf(['words', fake('a', box(10, 10))]);
    expect(scene.hit(at(0, 0), at(20, 20))).toBe('a');
    expect(scene.hit(at(0, 0), at(10, 10))).toBe('a');
  });

  it('prefers the one added later within a layer', () => {
    const scene = sceneOf(['words', fake('under', box(0, 0, 50))], ['words', fake('over', box(20, 20, 50))]);
    expect(scene.hit(at(0, 0), at(30, 30))).toBe('over');
    expect(scene.hit(at(0, 0), at(5, 5))).toBe('under');
  });

  it('prefers the higher layer regardless of insertion order', () => {
    const scene = sceneOf(['focus', fake('focus', box(0, 0, 50))], ['words', fake('word', box(0, 0, 50))]);
    expect(scene.hit(at(0, 0), at(25, 25))).toBe('focus');
  });

  it('compares moving and static drawables by display order, not by kind', () => {
    const scene = sceneOf(
      ['words', fake('static', box(0, 0, 50))],
      ['words', fake('moving', box(0, 0, 50), { moving: true })],
    );
    expect(scene.hit(at(0, 0), at(25, 25))).toBe('moving');
    const other = sceneOf(
      ['words', fake('moving', box(0, 0, 50), { moving: true })],
      ['words', fake('static', box(0, 0, 50))],
    );
    expect(other.hit(at(0, 0), at(25, 25))).toBe('static');
  });

  it('skips non-interactive drawables and lets the one below be hit', () => {
    const scene = sceneOf(
      ['words', fake('below', box(0, 0, 50))],
      ['focus', fake('glow', box(0, 0, 50), { interactive: false })],
    );
    expect(scene.hit(at(0, 0), at(25, 25))).toBe('below');
  });

  it('tests the hud in screen space and ahead of the world', () => {
    const scene = sceneOf(['words', fake('word', box(0, 0, 50))], ['hud', fake('button', box(100, 100, 20))]);
    expect(scene.hit(at(110, 110), at(25, 25))).toBe('button');
    expect(scene.hit(at(0, 0), at(25, 25))).toBe('word');
    // A hud button's screen position is not looked up in world space.
    expect(scene.hit(at(0, 0), at(110, 110))).toBeNull();
  });

  it('still finds objects while they are culled away', () => {
    const scene = sceneOf(['words', fake('a', box(500, 500))]);
    scene.cull(screenView);
    expect(scene.hit(at(0, 0), at(505, 505))).toBe('a');
  });

  it('stays correct with many drawables', () => {
    const scene = new Scene();
    for (let i = 0; i < 2000; i++) {
      scene.add('words', fake(`w${i}`, box((i % 50) * 20, Math.floor(i / 50) * 20, 10)));
    }
    scene.cull({ minX: 0, minY: 0, maxX: 205, maxY: 205 });
    // 11 x 11 boxes touch that viewport.
    expect(scene.visible).toBe(121);
    expect(scene.hit(at(0, 0), at(5 * 20 + 3, 7 * 20 + 3))).toBe(`w${7 * 50 + 5}`);
    expect(scene.hit(at(0, 0), at(5 * 20 + 15, 7 * 20 + 3))).toBeNull();
  });
});

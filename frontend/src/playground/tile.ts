import { Container, Graphics } from 'pixi.js';
import { type Drawable, type Engine, type Rect, createLodText } from '../engine/index.ts';

export interface Tile extends Drawable {
  setSelected(selected: boolean): void;
  /** Moves the tile; for moving tiles only. */
  place(x: number, y: number): void;
  destroy(): void;
  /** Text texture resolution tier, to watch the LOD at work. */
  textTier(): number;
}

const dark = (): boolean =>
  typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches;

/**
 * A placeholder word tile centered on (x, y). The real tiles belong to the desk
 * layer (M4); this one only exists to exercise the engine, and shows how a
 * drawable uses `createLodText` for zoom-sharp text.
 */
export function createTile(
  engine: Engine,
  id: string,
  label: string,
  x: number,
  y: number,
  moving: boolean,
): Tile {
  const night = dark();
  const fg = night ? 0xf2f2f4 : 0x1d1d1f;
  const fill = night ? 0x232326 : 0xffffff;
  const line = night ? 0x3a3a40 : 0xd8d6d0;
  const accent = night ? 0x7c9cff : 0x3b6ef5;

  const lod = createLodText(engine, {
    text: label,
    style: { fontSize: 22, fill: fg, fontFamily: 'system-ui, sans-serif' },
  });
  const text = lod.text;
  text.anchor.set(0.5);
  const w = Math.ceil(text.width) + 28;
  const h = 44;

  const box = new Graphics();
  const draw = (selected: boolean): void => {
    box
      .clear()
      .roundRect(-w / 2, -h / 2, w, h, 12)
      .fill(selected ? accent : fill)
      .stroke({ width: selected ? 0 : 1.5, color: line });
    text.style.fill = selected ? 0xffffff : fg;
  };
  draw(false);

  const view = new Container();
  view.addChild(box, text);

  // One rectangle, updated in place: bounds() runs for every tile on every frame.
  const bounds: Rect = { minX: 0, minY: 0, maxX: 0, maxY: 0 };
  const place = (px: number, py: number): void => {
    view.position.set(px, py);
    bounds.minX = px - w / 2;
    bounds.minY = py - h / 2;
    bounds.maxX = px + w / 2;
    bounds.maxY = py + h / 2;
  };
  place(x, y);

  return {
    id,
    view,
    bounds: () => bounds,
    interactive: true,
    moving,
    setSelected: draw,
    place,
    textTier: () => lod.tier,
    destroy: () => {
      lod.destroy();
      box.destroy();
      view.destroy();
    },
  };
}

import { Container, Graphics, Text } from 'pixi.js';
import type { Drawable, Rect } from '../engine/index.ts';

export interface Tile extends Drawable {
  setSelected(selected: boolean): void;
}

const dark = (): boolean =>
  typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches;

/** A placeholder word tile centered on (x, y). The real tiles belong to the desk layer (M4). */
export function createTile(id: string, label: string, x: number, y: number): Tile {
  const night = dark();
  const fg = night ? 0xf2f2f4 : 0x1d1d1f;
  const fill = night ? 0x232326 : 0xffffff;
  const line = night ? 0x3a3a40 : 0xd8d6d0;
  const accent = night ? 0x7c9cff : 0x3b6ef5;

  const text = new Text({ text: label, style: { fontSize: 22, fill: fg, fontFamily: 'system-ui, sans-serif' } });
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
  view.position.set(x, y);

  const bounds: Rect = { minX: x - w / 2, minY: y - h / 2, maxX: x + w / 2, maxY: y + h / 2 };
  return {
    id,
    view,
    bounds: () => bounds,
    interactive: true,
    moving: false,
    setSelected: draw,
  };
}

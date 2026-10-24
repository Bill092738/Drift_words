import RBush from 'rbush';
import type { Drawable, LayerName, Rect, Vec } from './api.ts';

/** Back to front. */
export const LAYERS: readonly LayerName[] = ['sources', 'edges', 'words', 'focus', 'hud'];

export const intersects = (a: Rect, b: Rect): boolean =>
  a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY;

export const contains = (r: Rect, p: Vec): boolean =>
  p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY;

interface Entry {
  layer: LayerName;
  layerIndex: number;
  /** Insertion order; within a layer a later drawable is drawn on top. */
  seq: number;
  drawable: Drawable;
  /** The record in the spatial index; null for moving and screen-space drawables. */
  item: Item | null;
}

/** Immutable once inserted: moving a drawable replaces its item, so removal always finds it. */
interface Item extends Rect {
  entry: Entry;
}

/**
 * What is on the desk: which drawables exist, which are on screen, and what is
 * under a point. It touches `view.visible` and nothing else of Pixi, so it is
 * tested without a renderer.
 *
 * - Static world drawables live in an rbush index. They must call {@link moved}
 *   when their bounds change.
 * - Moving world drawables are checked directly every frame.
 * - The `hud` layer is in screen space, always visible, and also scanned directly.
 */
export class Scene {
  private readonly entries = new Map<string, Entry>();
  private readonly tree = new RBush<Item>();
  private readonly moving = new Set<Entry>();
  private readonly hud = new Set<Entry>();
  private shown = new Set<Entry>();
  private scratch = new Set<Entry>();
  private seq = 0;

  /** Number of drawables on the desk, on screen or not. */
  get total(): number {
    return this.entries.size;
  }

  /** Number of drawables that are currently visible, including the hud. */
  get visible(): number {
    return this.shown.size + this.hud.size;
  }

  has(id: string): boolean {
    return this.entries.has(id);
  }

  add(layer: LayerName, drawable: Drawable): void {
    if (this.entries.has(drawable.id)) throw new Error(`drawable "${drawable.id}" already added`);
    const entry: Entry = {
      layer,
      layerIndex: LAYERS.indexOf(layer),
      seq: this.seq++,
      drawable,
      item: null,
    };
    this.entries.set(drawable.id, entry);
    if (layer === 'hud') {
      this.hud.add(entry);
      drawable.view.visible = true;
      return;
    }
    // Hidden until the next cull proves it is on screen.
    drawable.view.visible = false;
    if (drawable.moving) {
      this.moving.add(entry);
    } else {
      this.index(entry);
    }
  }

  /** Returns the removed drawable, so the caller can detach its view. */
  remove(id: string): Drawable | undefined {
    const entry = this.entries.get(id);
    if (entry === undefined) return undefined;
    this.entries.delete(id);
    this.unindex(entry);
    this.moving.delete(entry);
    this.hud.delete(entry);
    this.shown.delete(entry);
    return entry.drawable;
  }

  /** Re-indexes a static drawable after its bounds changed. */
  moved(id: string): void {
    const entry = this.entries.get(id);
    if (entry === undefined || entry.item === null) return;
    this.unindex(entry);
    this.index(entry);
  }

  /** Shows exactly the world drawables that intersect the viewport. */
  cull(viewport: Rect): void {
    const next = this.scratch;
    next.clear();
    for (const item of this.tree.search(viewport)) next.add(item.entry);
    for (const entry of this.moving) {
      if (intersects(entry.drawable.bounds(), viewport)) next.add(entry);
    }
    for (const entry of next) {
      if (!this.shown.has(entry)) entry.drawable.view.visible = true;
    }
    for (const entry of this.shown) {
      if (!next.has(entry)) entry.drawable.view.visible = false;
    }
    this.scratch = this.shown;
    this.shown = next;
  }

  /**
   * The id of the interactive drawable drawn topmost at a point, or null.
   * `screen` is used for the hud and `world` for everything else.
   */
  hit(screen: Vec, world: Vec): string | null {
    let best: Entry | null = null;
    const consider = (entry: Entry): void => {
      if (best === null || entry.layerIndex > best.layerIndex) {
        best = entry;
      } else if (entry.layerIndex === best.layerIndex && entry.seq > best.seq) {
        best = entry;
      }
    };

    for (const entry of this.hud) {
      if (entry.drawable.interactive && contains(entry.drawable.bounds(), screen)) consider(entry);
    }
    if (best === null) {
      const probe: Rect = { minX: world.x, minY: world.y, maxX: world.x, maxY: world.y };
      for (const item of this.tree.search(probe)) {
        if (item.entry.drawable.interactive) consider(item.entry);
      }
      for (const entry of this.moving) {
        if (entry.drawable.interactive && contains(entry.drawable.bounds(), world)) consider(entry);
      }
    }
    return (best as Entry | null)?.drawable.id ?? null;
  }

  private index(entry: Entry): void {
    const b = entry.drawable.bounds();
    const item: Item = { minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY, entry };
    entry.item = item;
    this.tree.insert(item);
  }

  private unindex(entry: Entry): void {
    if (entry.item === null) return;
    this.tree.remove(entry.item);
    entry.item = null;
  }
}

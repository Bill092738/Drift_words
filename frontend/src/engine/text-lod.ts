import { type Container, Text, type TextOptions } from 'pixi.js';
import type { Engine } from './api.ts';
import { quality } from './config.ts';
import { internalsOf } from './internals.ts';
import { chooseTier } from './lod-tier.ts';

export { chooseTier } from './lod-tier.ts';

/** Whether a display object and all its ancestors are visible, so it will be drawn. */
function isShown(node: Container | null): boolean {
  for (let n = node; n !== null; n = n.parent) {
    if (!n.visible) return false;
  }
  return true;
}

export interface LodText {
  /** The Pixi text to put in a drawable's view. Change `text.text` and `text.style` as usual. */
  readonly text: Text;
  /** The resolution tier the text is rasterized at. */
  readonly tier: number;
  /** Stops tracking and destroys the text, releasing its texture. */
  destroy(): void;
}

class LodTextImpl implements LodText {
  readonly text: Text;
  private readonly manager: TextLodManager;

  constructor(text: Text, manager: TextLodManager) {
    this.text = text;
    this.manager = manager;
  }

  get tier(): number {
    return this.text.resolution;
  }

  destroy(): void {
    this.manager.unregister(this);
    this.text.destroy();
  }
}

/**
 * One per engine. Watches the camera zoom and, when the tier changes,
 * re-rasterizes the texts that are on screen, a few per frame. Texts that are
 * culled away are brought up to date when they next appear, so nothing
 * off-screen is rebuilt, and nothing is rebuilt on a frame where the tier did
 * not change.
 */
class TextLodManager {
  private tier: number;
  private readonly engine: Engine;
  private readonly onEmpty: () => void;
  private readonly texts = new Set<LodTextImpl>();
  private readonly stale = new Set<LodTextImpl>();
  private off: (() => void) | null = null;

  constructor(engine: Engine, onEmpty: () => void) {
    this.engine = engine;
    this.onEmpty = onEmpty;
    this.tier = chooseTier(null, this.needed());
  }

  create(options: TextOptions): LodText {
    const text = new Text({ ...options, resolution: this.tier });
    const lod = new LodTextImpl(text, this);
    this.texts.add(lod);
    this.off ??= this.engine.onFrame(() => this.step());
    return lod;
  }

  unregister(lod: LodTextImpl): void {
    this.texts.delete(lod);
    this.stale.delete(lod);
    if (this.texts.size === 0) {
      this.off?.();
      this.off = null;
      this.onEmpty();
    }
  }

  private needed(): number {
    return this.engine.camera.zoom * internalsOf(this.engine).resolution;
  }

  private step(): void {
    const next = chooseTier(this.tier, this.needed());
    if (next !== this.tier) {
      this.tier = next;
      for (const lod of this.texts) if (lod.text.resolution !== next) this.stale.add(lod);
    }
    if (this.stale.size === 0) return;
    let budget = quality.text.rebuildsPerFrame;
    for (const lod of this.stale) {
      if (lod.text.resolution === this.tier) {
        this.stale.delete(lod);
        continue;
      }
      if (!isShown(lod.text)) continue;
      lod.text.resolution = this.tier;
      this.stale.delete(lod);
      if (--budget === 0) break;
    }
  }
}

const managers = new WeakMap<Engine, TextLodManager>();

/**
 * Creates a Pixi `Text` whose sharpness follows the camera zoom. Use it
 * wherever the desk shows words, so text stays crisp when zoomed in without
 * paying for large textures when zoomed out, or for a rebuild every frame.
 * Works through the public `Engine` interface only.
 */
export function createLodText(engine: Engine, options: TextOptions): LodText {
  let manager = managers.get(engine);
  if (manager === undefined) {
    manager = new TextLodManager(engine, () => managers.delete(engine));
    managers.set(engine, manager);
  }
  return manager.create(options);
}

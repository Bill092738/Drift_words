import { Container, Graphics, Text } from 'pixi.js';
import type { Drawable, Rect, SpringConfig, Vec } from '../engine/api.ts';
import { springs } from '../engine/api.ts';
import { SpringValue } from '../motion/spring.ts';
import type { DeskTheme } from './theme.ts';

/**
 * How a word appears on the desk:
 * - `cloud`: a word of the initial cloud, pickable, drifting
 * - `candidate`: a branch word orbiting the current node, pickable
 * - `node`: a chosen word on the tree; tapping it backtracks
 * - `current`: the node the user is growing from
 * - `faded`: a word that was offered but not chosen, or the cloud after the
 *   first pick; it keeps drifting, dimmed, and cannot be picked
 */
export type TileVariant = 'cloud' | 'candidate' | 'node' | 'current' | 'faded';

const PAD_X = 14;
const PAD_Y = 8;
const RADIUS = 10;

const style = {
  cloud: { size: 15, weight: '500', alpha: 1, scale: 1 },
  candidate: { size: 15, weight: '500', alpha: 1, scale: 1 },
  node: { size: 16, weight: '600', alpha: 1, scale: 1 },
  current: { size: 17, weight: '700', alpha: 1, scale: 1.12 },
  faded: { size: 15, weight: '500', alpha: 0.28, scale: 0.92 },
} as const satisfies Record<TileVariant, { size: number; weight: string; alpha: number; scale: number }>;

export class WordTile implements Drawable {
  /** Mutable: a candidate keeps its tile when it becomes a node. */
  id: string;
  readonly view = new Container();
  readonly word: string;
  variant: TileVariant;
  /** Revisited nodes get a small marker: they become section headings later. */
  revisited = false;
  /** Offset added on top of the spring position, for drifting. */
  readonly drift: Vec = { x: 0, y: 0 };
  readonly noiseSeed = Math.random() * 1000;

  readonly x: SpringValue;
  readonly y: SpringValue;
  private readonly scale = new SpringValue(0, springs.snappy, 0.0005);
  private readonly alpha = new SpringValue(0, springs.snappy, 0.002);
  private readonly shadow = new Graphics();
  private readonly bg = new Graphics();
  private readonly label: Text;
  private width = 0;
  private height = 0;
  private theme: DeskTheme;
  private delay = 0;
  /** The dimness asked for by {@link dim}, before the high-contrast floor. */
  private dimAlpha = 1;

  constructor(id: string, word: string, variant: TileVariant, at: Vec, theme: DeskTheme) {
    this.id = id;
    this.word = word;
    this.variant = variant;
    this.theme = theme;
    this.x = new SpringValue(at.x, springs.smooth, 0.05);
    this.y = new SpringValue(at.y, springs.smooth, 0.05);
    this.label = new Text({ text: word, resolution: Math.min(window.devicePixelRatio || 1, 2) * 2 });
    this.label.anchor.set(0.5);
    this.view.addChild(this.shadow, this.bg, this.label);
    this.view.scale.set(0);
    this.view.alpha = 0;
    this.redraw();
    this.setVariant(variant);
  }

  get interactive(): boolean {
    return this.variant !== 'faded';
  }

  get moving(): boolean {
    return this.variant === 'cloud' || this.variant === 'candidate' || this.variant === 'faded';
  }

  /** Still moving to its target, changing size, or waiting to appear. */
  get animating(): boolean {
    return this.delay > 0 || !(this.x.settled && this.y.settled && this.scale.settled);
  }

  /** Where the tile is heading, without drift. */
  get target(): Vec {
    return { x: this.x.target, y: this.y.target };
  }

  /** Where the tile is drawn right now. */
  get position(): Vec {
    return { x: this.view.position.x, y: this.view.position.y };
  }

  bounds(): Rect {
    const s = this.view.scale.x;
    const { x, y } = this.view.position;
    return { minX: x - (this.width / 2) * s, maxX: x + (this.width / 2) * s, minY: y - (this.height / 2) * s, maxY: y + (this.height / 2) * s };
  }

  setVariant(variant: TileVariant): void {
    const changedSize = style[variant].size !== style[this.variant].size || style[variant].weight !== style[this.variant].weight;
    this.variant = variant;
    if (changedSize) this.redraw();
    else this.paint();
    this.scale.target = style[variant].scale;
    this.dimAlpha = style[variant].alpha;
    this.alpha.target = variant === 'faded' ? this.fadedAlpha(this.dimAlpha) : style[variant].alpha;
    this.view.zIndex = variant === 'current' ? 3 : variant === 'faded' ? 0 : variant === 'node' ? 2 : 1;
  }

  setTheme(theme: DeskTheme): void {
    this.theme = theme;
    this.redraw();
    if (this.variant === 'faded' && this.alpha.target > 0) this.alpha.target = this.fadedAlpha(this.dimAlpha);
  }

  /** Moves toward `to` with the given spring. */
  moveTo(to: Vec, config: SpringConfig = springs.smooth): void {
    this.x.configure(config);
    this.y.configure(config);
    this.x.target = to.x;
    this.y.target = to.y;
  }

  /** Starts growing in after `delaySeconds` (staggered appearance). */
  appear(delaySeconds = 0): void {
    this.delay = delaySeconds;
  }

  /** Sets how visible a faded tile is (it fades further as the user moves on). */
  dim(alpha: number): void {
    if (this.variant !== 'faded') return;
    this.dimAlpha = alpha;
    this.alpha.target = this.fadedAlpha(alpha);
  }

  /** With high contrast, passed-over words stay readable, though still dimmer. */
  private fadedAlpha(alpha: number): number {
    return this.theme.highContrast ? Math.max(alpha * 2, 0.45) : alpha;
  }

  /** Shrinks the tile away; {@link gone} turns true once it has. */
  vanish(): void {
    this.scale.target = 0;
    this.alpha.target = 0;
  }

  get gone(): boolean {
    return this.alpha.target === 0 && this.alpha.value === 0;
  }

  update(dt: number): void {
    if (this.delay > 0) {
      this.delay -= dt;
      return;
    }
    this.x.step(dt);
    this.y.step(dt);
    this.scale.step(dt);
    this.alpha.step(dt);
    this.view.position.set(this.x.value + this.drift.x, this.y.value + this.drift.y);
    this.view.scale.set(Math.max(0, this.scale.value));
    this.view.alpha = Math.min(1, Math.max(0, this.alpha.value));
    // Words that stop drifting settle back to level.
    if (!this.moving || this.variant === 'candidate') this.view.rotation *= Math.exp(-dt * 8);
  }

  private redraw(): void {
    const s = style[this.variant];
    this.label.style = {
      fontFamily: this.theme.font,
      fontSize: Math.round(s.size * this.theme.textScale),
      fontWeight: s.weight,
      fill: this.theme.fg,
    };
    this.width = Math.ceil(this.label.width) + PAD_X * 2;
    this.height = Math.ceil(this.label.height) + PAD_Y * 2;
    this.paint();
  }

  private paint(): void {
    const { width: w, height: h, theme } = this;
    const current = this.variant === 'current';
    const candidate = this.variant === 'candidate' || this.variant === 'cloud';
    this.shadow
      .clear()
      .roundRect(-w / 2, -h / 2 + 2, w, h, RADIUS)
      .fill({ color: theme.shadow, alpha: theme.dark ? 0.35 : candidate ? 0.05 : 0.08 });
    this.bg
      .clear()
      .roundRect(-w / 2, -h / 2, w, h, RADIUS)
      .fill({ color: theme.surface })
      .stroke({
        width: current ? (theme.highContrast ? 3 : 2) : theme.highContrast ? 1.5 : 1,
        color: current ? theme.accent : theme.line,
        alignment: 1,
      });
    if (this.revisited && !current) {
      // A small dot on the left marks a revisited node.
      this.bg.circle(-w / 2 + 7, 0, 2.5).fill({ color: theme.accent });
    }
    this.label.style.fill = current ? theme.accent : this.variant === 'faded' ? theme.muted : theme.fg;
  }

  markRevisited(): void {
    if (this.revisited) return;
    this.revisited = true;
    this.paint();
  }

  destroy(): void {
    this.view.destroy({ children: true });
  }
}

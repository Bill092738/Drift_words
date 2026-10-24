import { Container, Graphics, Sprite, Text, Texture } from 'pixi.js';
import { sourceKindLabel } from '../chrome/icons.tsx';
import type { Drawable, Rect, SpringConfig, Vec } from '../engine/api.ts';
import { springs } from '../engine/api.ts';
import { SpringValue } from '../motion/spring.ts';
import type { Source } from '../protocol/index.ts';
import type { DeskTheme } from './theme.ts';

/** How much a focused object is enlarged. */
const FOCUS_SCALE = 1.9;
/** A dropping object starts this much larger, as if held above the desk. */
const DROP_SCALE = 1.45;
/** Extra spin a dropping object starts with, radians; it settles onto its tilt. */
const DROP_SPIN = 0.45;
const CAPTION_WIDTH = 104;
const CAPTION_LINES = 2;
const FOCUS_CAPTION_WIDTH = 150;
const FOCUS_CAPTION_LINES = 4;
const CAPTION_GAP = 8;
const PDF_RED = 0xe5484d;
const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
/** Springs for landing: a little bounce on scale, a little more on rotation. */
const LAND: SpringConfig = { response: 0.55, dampingFraction: 0.62 };
const LAND_SPIN: SpringConfig = { response: 0.7, dampingFraction: 0.5 };

/** The object's icon, drawn around its center, and how tall it is. */
interface Glyph {
  view: Container;
  height: number;
  width: number;
  /** Corner radius of the outline, for a matching shadow. */
  radius: number;
  /** Optional per-frame animation (the audio player's level bars). */
  tick?: (time: number, focus: number) => void;
}

/**
 * A source on the desk: a flat icon with a line of small text underneath,
 * styled by the kind of material (file, web card, thumbnail, speaker).
 * It drops in with a little physical weight, settles at a slight angle, and
 * enlarges when focused. All motion is springs advanced in {@link update}.
 */
export class SourceObject implements Drawable {
  readonly id: string;
  readonly view = new Container();
  readonly source: Source;
  readonly interactive = true;

  readonly x: SpringValue;
  readonly y: SpringValue;
  private readonly rotation: SpringValue;
  private readonly scale: SpringValue;
  private readonly alpha: SpringValue;
  /** 0 resting on the desk, 1 lifted (focused or still falling). */
  private readonly lift: SpringValue;
  private readonly shadow = new Graphics();
  /** A card behind icon and text while focused, so the enlarged text stays legible. */
  private readonly plate = new Graphics();
  private readonly body = new Container();
  private readonly caption: Text;
  private readonly detail: Text;
  private glyph: Glyph;
  private theme: DeskTheme;
  private tilt: number;
  private delay = 0;
  private time = 0;
  private texture: Texture | null = null;
  focused = false;

  constructor(id: string, source: Source, at: Vec, tilt: number, theme: DeskTheme, drop: boolean, reducedMotion: boolean) {
    this.id = id;
    this.source = source;
    this.theme = theme;
    this.tilt = tilt;
    const resolution = Math.min(window.devicePixelRatio || 1, 2) * 2;
    this.caption = new Text({ text: '', resolution });
    this.caption.anchor.set(0.5, 0);
    this.detail = new Text({ text: '', resolution });
    this.detail.anchor.set(0.5, 0);
    this.detail.alpha = 0;
    this.view.addChild(this.shadow, this.plate, this.body, this.caption, this.detail);
    this.glyph = this.drawGlyph();
    this.body.addChild(this.glyph.view);
    this.layoutText();
    this.loadThumbnail();

    const landing = reducedMotion ? springs.smooth : LAND;
    this.x = new SpringValue(at.x, springs.smooth, 0.05);
    this.y = new SpringValue(at.y, springs.smooth, 0.05);
    this.rotation = new SpringValue(tilt, reducedMotion ? springs.smooth : LAND_SPIN, 0.0005);
    this.scale = new SpringValue(1, landing, 0.0005);
    this.alpha = new SpringValue(1, springs.snappy, 0.002);
    this.lift = new SpringValue(0, landing, 0.001);
    if (drop) {
      // Start held above the desk: larger, transparent, spun, its shadow far below.
      const spin = reducedMotion ? 0 : (tilt >= 0 ? 1 : -1) * DROP_SPIN;
      this.rotation.snap(tilt + spin);
      this.rotation.target = tilt;
      this.scale.snap(reducedMotion ? 1 : DROP_SCALE);
      this.scale.target = 1;
      this.alpha.snap(0);
      this.alpha.target = 1;
      this.lift.snap(1);
      this.lift.target = 0;
      this.y.snap(at.y - (reducedMotion ? 0 : 36));
      this.y.target = at.y;
    } else {
      // Restored from a recorded placement: fade in where it already lay.
      this.alpha.snap(0);
      this.alpha.target = 1;
    }
    this.apply();
  }

  /** Static once it has landed; moving while it falls or changes focus. */
  get moving(): boolean {
    return !(this.x.settled && this.y.settled && this.scale.settled && this.rotation.settled);
  }

  /** Where the object rests, without motion. */
  get target(): Vec {
    return { x: this.x.target, y: this.y.target };
  }

  get position(): Vec {
    return { x: this.view.position.x, y: this.view.position.y };
  }

  get angle(): number {
    return this.tilt;
  }

  bounds(): Rect {
    // The icon and caption box, scaled; rotation is small enough to ignore.
    const s = this.view.scale.x;
    const { x, y } = this.view.position;
    const half = (Math.max(this.glyph.width, this.textWidth()) / 2) * s;
    const top = (this.glyph.height / 2) * s;
    const bottom = (this.glyph.height / 2 + CAPTION_GAP + this.textHeight()) * s;
    return { minX: x - half, maxX: x + half, minY: y - top, maxY: y + bottom };
  }

  /** Starts landing after `delaySeconds`, for several objects arriving together. */
  appear(delaySeconds: number): void {
    this.delay = delaySeconds;
  }

  moveTo(to: Vec, angle: number): void {
    this.x.target = to.x;
    this.y.target = to.y;
    this.tilt = angle;
    if (!this.focused) this.rotation.target = angle;
  }

  /** Lifts the object toward the viewer and enlarges it, or puts it back. */
  setFocused(focused: boolean): void {
    if (this.focused === focused) return;
    this.focused = focused;
    this.scale.configure(focused ? springs.snappy : springs.bouncy);
    this.scale.target = focused ? FOCUS_SCALE : 1;
    this.rotation.configure(springs.snappy);
    this.rotation.target = focused ? 0 : this.tilt;
    this.lift.configure(springs.snappy);
    this.lift.target = focused ? 1 : 0;
    this.view.zIndex = focused ? 10 : 0;
    this.layoutText();
  }

  setTheme(theme: DeskTheme): void {
    this.theme = theme;
    this.glyph.view.destroy({ children: true });
    this.glyph = this.drawGlyph();
    this.body.addChild(this.glyph.view);
    this.layoutText();
  }

  update(dt: number): void {
    if (this.delay > 0) {
      this.delay -= dt;
      return;
    }
    this.time += dt;
    this.x.step(dt);
    this.y.step(dt);
    this.rotation.step(dt);
    this.scale.step(dt);
    this.alpha.step(dt);
    this.lift.step(dt);
    this.apply();
  }

  destroy(): void {
    this.view.destroy({ children: true });
    this.texture?.destroy(true);
  }

  // ---------------------------------------------------------------------------

  private apply(): void {
    const lift = Math.max(0, this.lift.value);
    this.view.position.set(this.x.value, this.y.value);
    this.view.rotation = this.rotation.value;
    this.view.scale.set(Math.max(0, this.scale.value));
    this.view.alpha = Math.min(1, Math.max(0, this.alpha.value));
    const focus = Math.min(1, Math.max(0, (this.scale.value - 1) / (FOCUS_SCALE - 1)));
    const shown = this.focused ? focus : 0;
    // The shadow falls further away and softens as the object rises.
    const { width: w, height: h, radius } = this.glyph;
    const shadowAlpha = (this.theme.dark ? 0.4 : 0.1) * (1 - lift * 0.45);
    this.shadow
      .clear()
      .roundRect(-w / 2 + 1, -h / 2 + 2 + lift * 10, w - 2, h, radius)
      .fill({ color: this.theme.shadow, alpha: shadowAlpha * (1 - shown) });
    this.plate.clear();
    if (shown > 0.01) {
      const pw = Math.max(w, this.caption.width, this.detail.width) + 24;
      const top = -h / 2 - 12;
      const bottom = this.detail.position.y + this.detail.height + 10;
      this.plate
        .roundRect(-pw / 2, top + 4, pw, bottom - top, 12)
        .fill({ color: this.theme.shadow, alpha: (this.theme.dark ? 0.35 : 0.08) * shown })
        .roundRect(-pw / 2, top, pw, bottom - top, 12)
        .fill({ color: this.theme.surface, alpha: 0.97 * shown })
        .stroke({ width: 0.75, color: this.theme.line, alpha: shown });
    }
    this.detail.alpha = shown;
    this.glyph.tick?.(this.time, focus);
  }

  private textWidth(): number {
    return Math.max(this.caption.width, this.detail.alpha > 0 ? this.detail.width : 0);
  }

  private textHeight(): number {
    return this.caption.height + (this.focused ? 4 + this.detail.height : 0);
  }

  /** The line under the icon: the site for web pages, otherwise the title. */
  private captionText(): string {
    const { kind, site, title, url } = this.source;
    if (kind === 'webPage' && !this.focused) return site ?? hostOf(url);
    return title;
  }

  private layoutText(): void {
    const width = this.focused ? FOCUS_CAPTION_WIDTH : CAPTION_WIDTH;
    this.caption.style = {
      fontFamily: FONT,
      fontSize: this.focused ? 9 : 11,
      fontWeight: this.focused ? '600' : '500',
      fill: this.focused ? this.theme.fg : this.theme.muted,
      align: 'center',
      wordWrap: true,
      breakWords: true,
      wordWrapWidth: width,
      lineHeight: this.focused ? 12 : 14,
    };
    fitLines(this.caption, this.captionText(), this.focused ? FOCUS_CAPTION_LINES : CAPTION_LINES);
    this.caption.position.set(0, this.glyph.height / 2 + CAPTION_GAP);

    const tap = window.matchMedia('(pointer: coarse)').matches ? 'Tap' : 'Click';
    const site = this.source.site ?? hostOf(this.source.url);
    this.detail.style = { fontFamily: FONT, fontSize: 7.5, fill: this.theme.muted, align: 'center', lineHeight: 11 };
    this.detail.text = `${sourceKindLabel[this.source.kind]} · ${site}\n${tap} again to open`;
    this.detail.position.set(0, this.caption.position.y + this.caption.height + 4);
  }

  private drawGlyph(): Glyph {
    switch (this.source.kind) {
      case 'article':
      case 'paper':
      case 'pdf':
        return this.fileGlyph();
      case 'webPage':
        return this.webGlyph();
      case 'image':
        return this.imageGlyph();
      case 'audio':
        return this.audioGlyph();
    }
  }

  /** A sheet of paper with a folded corner; the kind decides what is printed on it. */
  private fileGlyph(): Glyph {
    const t = this.theme;
    const w = 42;
    const h = 54;
    const fold = 12;
    const l = -w / 2;
    const top = -h / 2;
    const g = new Graphics();
    g.poly([l, top, w / 2 - fold, top, w / 2, top + fold, w / 2, h / 2, l, h / 2])
      .fill({ color: t.surface })
      .stroke({ width: 1.5, color: t.line, alignment: 1 });
    g.poly([w / 2 - fold, top, w / 2 - fold, top + fold, w / 2, top + fold]).fill({ color: t.line });
    const line = (y: number, len: number, width = 1.5, color = t.muted, alpha = 0.55) =>
      g.moveTo(l + 8, y).lineTo(l + 8 + len, y).stroke({ width, color, alpha, cap: 'round' });
    const view = new Container();
    view.addChild(g);
    if (this.source.kind === 'paper') {
      // A journal page: a bold title line and two columns of text.
      line(top + 13, 16, 2.5, t.fg, 0.7);
      for (let i = 0; i < 6; i++) {
        g.moveTo(l + 8, top + 22 + i * 4.5).lineTo(l + 19, top + 22 + i * 4.5);
        g.moveTo(l + 23, top + 22 + i * 4.5).lineTo(l + 34, top + 22 + i * 4.5);
      }
      g.stroke({ width: 1.2, color: t.muted, alpha: 0.5, cap: 'round' });
    } else if (this.source.kind === 'pdf') {
      line(top + 14, 18);
      line(top + 20, 24);
      line(top + 26, 14);
      g.roundRect(l - 4, h / 2 - 20, 26, 12, 3).fill({ color: PDF_RED });
      const label = new Text({
        text: 'PDF',
        resolution: Math.min(window.devicePixelRatio || 1, 2) * 2,
        style: { fontFamily: FONT, fontSize: 7.5, fontWeight: '700', fill: 0xffffff },
      });
      label.anchor.set(0.5);
      label.position.set(l + 9, h / 2 - 14);
      view.addChild(label);
    } else {
      // An article: a picture block and lines of text.
      g.roundRect(l + 8, top + 10, 14, 10, 2).fill({ color: t.accent, alpha: 0.18 });
      line(top + 13, 6);
      line(top + 18, 6);
      for (let i = 0; i < 4; i++) line(top + 26 + i * 5.5, i === 3 ? 14 : 26);
    }
    return { view, width: w, height: h, radius: 3 };
  }

  /** A small browser window with a globe. */
  private webGlyph(): Glyph {
    const t = this.theme;
    const w = 60;
    const h = 46;
    const g = new Graphics();
    g.roundRect(-w / 2, -h / 2, w, h, 7).fill({ color: t.surface }).stroke({ width: 1.5, color: t.line, alignment: 1 });
    g.moveTo(-w / 2, -h / 2 + 11).lineTo(w / 2, -h / 2 + 11).stroke({ width: 1, color: t.line });
    for (let i = 0; i < 3; i++) g.circle(-w / 2 + 7 + i * 5, -h / 2 + 5.5, 1.6).fill({ color: t.muted, alpha: 0.5 });
    const cy = 5.5;
    const r = 11;
    g.circle(0, cy, r).stroke({ width: 1.5, color: t.accent });
    g.ellipse(0, cy, r * 0.42, r).stroke({ width: 1.2, color: t.accent });
    g.moveTo(-r, cy).lineTo(r, cy).stroke({ width: 1.2, color: t.accent });
    const view = new Container();
    view.addChild(g);
    return { view, width: w, height: h, radius: 7 };
  }

  /** A framed thumbnail; a flat landscape stands in until (or unless) the image loads. */
  private imageGlyph(): Glyph {
    const t = this.theme;
    const w = 70;
    const h = 52;
    const border = 3;
    const g = new Graphics();
    g.roundRect(-w / 2, -h / 2, w, h, 4).fill({ color: t.surface }).stroke({ width: 1, color: t.line, alignment: 1 });
    const iw = w - border * 2;
    const ih = h - border * 2;
    const ix = -iw / 2;
    const iy = -ih / 2;
    const view = new Container();
    view.addChild(g);
    if (this.texture) {
      const sprite = new Sprite(this.texture);
      // Cover the frame, cropping the longer side.
      const k = Math.max(iw / this.texture.width, ih / this.texture.height);
      sprite.scale.set(k);
      sprite.anchor.set(0.5);
      const mask = new Graphics().rect(ix, iy, iw, ih).fill({ color: 0xffffff });
      sprite.mask = mask;
      view.addChild(sprite, mask);
    } else {
      g.rect(ix, iy, iw, ih).fill({ color: t.accent, alpha: 0.12 });
      g.circle(ix + iw * 0.72, iy + ih * 0.3, 5).fill({ color: t.accent, alpha: 0.45 });
      g.poly([ix, iy + ih, ix + iw * 0.35, iy + ih * 0.45, ix + iw * 0.6, iy + ih * 0.78, ix + iw * 0.75, iy + ih * 0.62, ix + iw, iy + ih])
        .fill({ color: t.accent, alpha: 0.35 });
    }
    return { view, width: w, height: h, radius: 4 };
  }

  /** A small speaker player: a pill with a speaker and level bars that move when focused. */
  private audioGlyph(): Glyph {
    const t = this.theme;
    const w = 78;
    const h = 34;
    const g = new Graphics();
    g.roundRect(-w / 2, -h / 2, w, h, h / 2).fill({ color: t.surface }).stroke({ width: 1.5, color: t.line, alignment: 1 });
    const sx = -w / 2 + 14;
    g.poly([sx - 5, -3.5, sx - 1, -3.5, sx + 4, -8, sx + 4, 8, sx - 1, 3.5, sx - 5, 3.5]).fill({ color: t.accent });
    g.moveTo(sx + 6 + 5 * Math.cos(-0.9), 5 * Math.sin(-0.9))
      .arc(sx + 6, 0, 5, -0.9, 0.9)
      .stroke({ width: 1.5, color: t.accent, cap: 'round' });
    const bars = new Graphics();
    const view = new Container();
    view.addChild(g, bars);
    const heights = [0.45, 0.8, 0.6, 1, 0.55, 0.75, 0.4];
    const tick = (time: number, focus: number) => {
      bars.clear();
      heights.forEach((base, i) => {
        // Bars rest at their base height and come alive while focused.
        const wave = 0.5 + 0.5 * Math.sin(time * 7 + i * 1.3);
        const k = base * (1 - focus) + (0.25 + 0.75 * wave) * focus;
        const bh = 4 + 14 * k;
        bars.roundRect(-6 + i * 6, -bh / 2, 3, bh, 1.5);
      });
      bars.fill({ color: t.muted, alpha: 0.7 });
    };
    tick(0, 0);
    return { view, width: w, height: h, radius: h / 2, tick };
  }

  private loadThumbnail(): void {
    const url = this.source.thumbnailUrl;
    if (this.source.kind !== 'image' || !url) return;
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.src = url;
    img
      .decode()
      .then(() => {
        if (this.view.destroyed) return;
        this.texture = Texture.from(img);
        this.setTheme(this.theme);
      })
      .catch(() => {
        // Keep the placeholder landscape; a missing thumbnail is not an error.
      });
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return url;
  }
}

/** Sets `text`, shortening it with an ellipsis until it fits in `maxLines` lines. */
function fitLines(label: Text, text: string, maxLines: number): void {
  label.text = text;
  const lineHeight = Number(label.style.lineHeight) || label.height;
  const fits = () => label.height <= lineHeight * maxLines + 1;
  if (fits()) return;
  let words = text.split(/\s+/);
  while (words.length > 1) {
    words = words.slice(0, -1);
    label.text = `${words.join(' ')}…`;
    if (fits()) return;
  }
  // A single long word: cut characters instead.
  let chars = text;
  while (chars.length > 1 && !fits()) {
    chars = chars.slice(0, -1);
    label.text = `${chars}…`;
  }
}

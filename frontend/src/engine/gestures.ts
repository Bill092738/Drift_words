import type { Vec } from './api.ts';

/** Movement beyond this many pixels turns a press into a drag. */
export const TAP_SLOP = 8;
/** Presses held longer than this are not taps. */
export const TAP_MAX_MS = 500;

export interface GestureHandlers {
  /** Drag delta in screen pixels. */
  pan(dx: number, dy: number): void;
  /** Zoom multiplier around a screen point. */
  zoom(factor: number, at: Vec): void;
  tap(at: Vec): void;
}

const distance = (a: Vec, b: Vec): number => Math.hypot(a.x - b.x, a.y - b.y);
const midpoint = (a: Vec, b: Vec): Vec => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });

/**
 * Turns raw pointer streams into pan, pinch-zoom and tap. It knows nothing
 * about the DOM, so it is tested with plain numbers. Positions are screen
 * pixels and times are milliseconds.
 */
export class GestureRecognizer {
  private readonly pointers = new Map<number, Vec>();
  private start: { at: Vec; time: number } | null = null;
  private dragging = false;
  /** A second pointer joined at some point; the gesture can no longer be a tap. */
  private multi = false;

  private readonly handlers: GestureHandlers;

  constructor(handlers: GestureHandlers) {
    this.handlers = handlers;
  }

  pointerDown(id: number, at: Vec, time: number): void {
    this.pointers.set(id, at);
    if (this.pointers.size === 1) {
      this.start = { at, time };
      this.dragging = false;
      this.multi = false;
    } else {
      this.multi = true;
    }
  }

  pointerMove(id: number, at: Vec): void {
    const prev = this.pointers.get(id);
    if (prev === undefined) return;

    if (this.pointers.size === 1) {
      this.pointers.set(id, at);
      if (!this.dragging && this.start !== null && !this.multi) {
        if (distance(at, this.start.at) < TAP_SLOP) return;
        this.dragging = true;
        // Catch up on the movement spent inside the slop.
        this.handlers.pan(at.x - this.start.at.x, at.y - this.start.at.y);
        return;
      }
      this.dragging = true;
      this.handlers.pan(at.x - prev.x, at.y - prev.y);
      return;
    }

    if (this.pointers.size === 2) {
      const [idA, idB] = [...this.pointers.keys()];
      const before = [this.pointers.get(idA!)!, this.pointers.get(idB!)!] as const;
      this.pointers.set(id, at);
      const after = [this.pointers.get(idA!)!, this.pointers.get(idB!)!] as const;
      const c0 = midpoint(before[0], before[1]);
      const c1 = midpoint(after[0], after[1]);
      const d0 = distance(before[0], before[1]);
      const d1 = distance(after[0], after[1]);
      this.dragging = true;
      this.handlers.pan(c1.x - c0.x, c1.y - c0.y);
      if (d0 > 0 && d1 > 0) this.handlers.zoom(d1 / d0, c1);
      return;
    }

    // Three or more fingers: track but do nothing.
    this.pointers.set(id, at);
  }

  pointerUp(id: number, at: Vec, time: number): void {
    if (!this.pointers.has(id)) return;
    const wasSingle = this.pointers.size === 1;
    this.pointers.delete(id);
    if (!wasSingle) return;
    const start = this.start;
    this.start = null;
    if (
      start !== null &&
      !this.dragging &&
      !this.multi &&
      time - start.time <= TAP_MAX_MS &&
      distance(at, start.at) < TAP_SLOP
    ) {
      this.handlers.tap(at);
    }
  }

  pointerCancel(id: number): void {
    this.pointers.delete(id);
    if (this.pointers.size === 0) this.start = null;
  }
}

/** Zoom multiplier for a wheel event. Trackpad pinch arrives as `ctrlKey` with small deltas. */
export function wheelZoomFactor(deltaY: number, deltaMode: number, ctrlKey: boolean): number {
  const pixels = deltaMode === 1 ? deltaY * 16 : deltaMode === 2 ? deltaY * 400 : deltaY;
  const sensitivity = ctrlKey ? 0.01 : 0.0015;
  return Math.exp(-pixels * sensitivity);
}

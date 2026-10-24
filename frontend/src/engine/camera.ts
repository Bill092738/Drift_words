import { type Camera, type Rect, type SpringConfig, type Vec, springs } from './api.ts';
import { SpringImpl } from './spring.ts';

export const MIN_ZOOM = 0.05;
export const MAX_ZOOM = 8;
/** Exponential decay rate of a fling, per second. Velocity halves about every 0.17 s. */
export const FLING_FRICTION = 4;
/** A fling ends when it is slower than this (pixels per second). */
const FLING_REST_SPEED = 8;
/** Wheel zoom eases with this spring; critically damped so it never overshoots. */
const WHEEL_ZOOM: SpringConfig = { response: 0.22, dampingFraction: 1 };

const clampZoom = (z: number): number => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z));

/**
 * The desk camera. Position is a world point at the center of the screen.
 * Zoom is springed in log space so that glides feel even at any scale.
 *
 * Direct manipulation (`panBy`, `zoomAt`) snaps the springs, which also cancels
 * a glide in progress. Only `glideTo` animates.
 */
export class CameraImpl implements Camera {
  private readonly x = new SpringImpl(0, springs.smooth);
  private readonly y = new SpringImpl(0, springs.smooth);
  private readonly logZoom = new SpringImpl(0, springs.smooth);
  private width = 1;
  private height = 1;
  /** Pan velocity in screen pixels per second while a fling is coasting. */
  private flingX = 0;
  private flingY = 0;
  /** While a wheel zoom eases, this world point is kept under this screen point. */
  private anchor: { world: Vec; screen: Vec } | null = null;

  /** With reduced motion, glides and wheel zoom jump instead of animating, and there is no fling. */
  reducedMotion = false;

  get center(): Vec {
    return { x: this.x.value, y: this.y.value };
  }

  get zoom(): number {
    return Math.exp(this.logZoom.value);
  }

  get viewport(): Rect {
    const halfW = this.width / 2 / this.zoom;
    const halfH = this.height / 2 / this.zoom;
    return {
      minX: this.x.value - halfW,
      minY: this.y.value - halfH,
      maxX: this.x.value + halfW,
      maxY: this.y.value + halfH,
    };
  }

  get animating(): boolean {
    return (
      !(this.x.settled && this.y.settled && this.logZoom.settled) ||
      this.flingX !== 0 ||
      this.flingY !== 0
    );
  }

  /** Screen size in CSS pixels. */
  resize(width: number, height: number): void {
    this.width = Math.max(1, width);
    this.height = Math.max(1, height);
  }

  step(dt: number): void {
    if (this.flingX !== 0 || this.flingY !== 0) {
      const z = this.zoom;
      this.snapTo(
        this.x.value - (this.flingX * dt) / z,
        this.y.value - (this.flingY * dt) / z,
        this.logZoom.value,
      );
      const decay = Math.exp(-FLING_FRICTION * dt);
      this.flingX *= decay;
      this.flingY *= decay;
      if (Math.hypot(this.flingX, this.flingY) < FLING_REST_SPEED) this.stopFling();
      return;
    }
    this.x.step(dt);
    this.y.step(dt);
    this.logZoom.step(dt);
    if (this.anchor !== null) {
      // Keep the world point under the pointer while the zoom eases.
      const { world, screen } = this.anchor;
      const z = this.zoom;
      this.x.snap(world.x - (screen.x - this.width / 2) / z);
      this.y.snap(world.y - (screen.y - this.height / 2) / z);
      if (this.logZoom.settled) this.anchor = null;
    }
  }

  /** Coasts after a drag release, with a screen-space velocity in pixels per second. */
  fling(vx: number, vy: number): void {
    if (this.reducedMotion) return;
    this.anchor = null;
    this.flingX = vx;
    this.flingY = vy;
  }

  stopFling(): void {
    this.flingX = 0;
    this.flingY = 0;
  }

  /**
   * Eases the zoom by `factor` around a screen point (the mouse wheel).
   * Repeated calls accumulate on the target, so fast scrolling stays responsive.
   */
  zoomAtSmooth(at: Vec, factor: number): void {
    if (this.reducedMotion) {
      this.zoomAt(at, factor);
      return;
    }
    this.stopFling();
    this.x.snap(this.x.value);
    this.y.snap(this.y.value);
    // Chain onto the running wheel zoom's target; otherwise start from where the zoom is now.
    const from = this.anchor !== null ? this.logZoom.target : this.logZoom.value;
    const target = Math.log(clampZoom(Math.exp(from) * factor));
    this.anchor = { world: this.screenToWorld(at), screen: at };
    this.logZoom.to(target, WHEEL_ZOOM);
  }

  glideTo(center: Vec, zoom?: number, config: SpringConfig = springs.smooth): void {
    this.stopFling();
    this.anchor = null;
    if (this.reducedMotion) {
      this.snapTo(center.x, center.y, zoom === undefined ? this.logZoom.value : Math.log(clampZoom(zoom)));
      return;
    }
    this.x.to(center.x, config);
    this.y.to(center.y, config);
    if (zoom !== undefined) this.logZoom.to(Math.log(clampZoom(zoom)), config);
  }

  worldToScreen(p: Vec): Vec {
    const z = this.zoom;
    return {
      x: (p.x - this.x.value) * z + this.width / 2,
      y: (p.y - this.y.value) * z + this.height / 2,
    };
  }

  screenToWorld(p: Vec): Vec {
    const z = this.zoom;
    return {
      x: (p.x - this.width / 2) / z + this.x.value,
      y: (p.y - this.height / 2) / z + this.y.value,
    };
  }

  /** Drags the desk by a screen-space delta. */
  panBy(dxScreen: number, dyScreen: number): void {
    const z = this.zoom;
    this.snapTo(this.x.value - dxScreen / z, this.y.value - dyScreen / z, this.logZoom.value);
  }

  /** Multiplies the zoom, keeping the world point under `at` (screen space) fixed. */
  zoomAt(at: Vec, factor: number): void {
    const anchor = this.screenToWorld(at);
    const logZoom = Math.log(clampZoom(this.zoom * factor));
    const z = Math.exp(logZoom);
    this.snapTo(
      anchor.x - (at.x - this.width / 2) / z,
      anchor.y - (at.y - this.height / 2) / z,
      logZoom,
    );
  }

  private snapTo(x: number, y: number, logZoom: number): void {
    this.anchor = null;
    this.x.snap(x);
    this.y.snap(y);
    this.logZoom.snap(logZoom);
  }
}

import { type Camera, type Rect, type SpringConfig, type Vec, springs } from './api.ts';
import { SpringImpl } from './spring.ts';

export const MIN_ZOOM = 0.05;
export const MAX_ZOOM = 8;

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
    return !(this.x.settled && this.y.settled && this.logZoom.settled);
  }

  /** Screen size in CSS pixels. */
  resize(width: number, height: number): void {
    this.width = Math.max(1, width);
    this.height = Math.max(1, height);
  }

  step(dt: number): void {
    this.x.step(dt);
    this.y.step(dt);
    this.logZoom.step(dt);
  }

  glideTo(center: Vec, zoom?: number, config: SpringConfig = springs.smooth): void {
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
    this.x.snap(x);
    this.y.snap(y);
    this.logZoom.snap(logZoom);
  }
}

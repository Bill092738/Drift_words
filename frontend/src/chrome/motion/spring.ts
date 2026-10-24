// A damped spring for DOM chrome (sidebar, sheets). It uses the same
// SpringConfig as the canvas engine, so chrome and desk motion feel alike.
import type { SpringConfig } from '../../engine/api.ts';

const MAX_SUBSTEP = 1 / 240;

/**
 * A unit-mass spring integrated with semi-implicit Euler in fixed substeps,
 * so it is stable at any frame rate. Retargeting keeps the velocity, which is
 * what makes interrupted motion feel continuous.
 */
export class SpringValue {
  value: number;
  velocity = 0;
  target: number;
  private stiffness = 0;
  private damping = 0;
  /** Distance and speed below which the spring snaps to rest. */
  private readonly precision: number;

  constructor(value: number, config: SpringConfig, precision = 0.001) {
    this.value = value;
    this.target = value;
    this.precision = precision;
    this.configure(config);
  }

  configure({ response, dampingFraction }: SpringConfig): void {
    const omega = (2 * Math.PI) / Math.max(response, 0.01);
    this.stiffness = omega * omega;
    this.damping = 2 * dampingFraction * omega;
  }

  get settled(): boolean {
    return this.value === this.target && this.velocity === 0;
  }

  snap(value: number): void {
    this.value = value;
    this.target = value;
    this.velocity = 0;
  }

  /** Advances by `dt` seconds; returns true while still moving. */
  step(dt: number): boolean {
    let remaining = Math.min(dt, 0.1);
    while (remaining > 0) {
      const h = Math.min(remaining, MAX_SUBSTEP);
      const force = -this.stiffness * (this.value - this.target) - this.damping * this.velocity;
      this.velocity += force * h;
      this.value += this.velocity * h;
      remaining -= h;
    }
    if (Math.abs(this.value - this.target) < this.precision && Math.abs(this.velocity) < this.precision * 10) {
      this.value = this.target;
      this.velocity = 0;
      return false;
    }
    return true;
  }
}

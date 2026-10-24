import { type Spring, type SpringConfig, springs } from './api.ts';
import { motion } from './config.ts';

/** Integration step. Springs are advanced in fixed steps so dropped frames do not change the motion. */
const STEP = 1 / 240;
const REST_DISTANCE = 1e-3;
const REST_VELOCITY = 1e-3;
/** Upper bound on steps per call, so a long stall cannot freeze the page. */
const MAX_STEPS = 240;

/**
 * Spring with the parameters of {@link SpringConfig}. `response` is the period
 * (stiffness = (2π / response)²) and `dampingFraction` 1 is critical damping.
 */
export class SpringImpl implements Spring {
  value: number;
  velocity = 0;
  target: number;
  private config: SpringConfig;
  private remainder = 0;
  /** Reduced motion: twice as fast and never overshooting. */
  reducedMotion = false;

  constructor(initial: number, config: SpringConfig = springs.smooth) {
    this.value = initial;
    this.target = initial;
    this.config = config;
  }

  get settled(): boolean {
    return (
      Math.abs(this.value - this.target) < REST_DISTANCE && Math.abs(this.velocity) < REST_VELOCITY
    );
  }

  to(target: number, config?: SpringConfig): void {
    this.target = target;
    if (config !== undefined) this.config = config;
  }

  snap(value: number): void {
    this.value = value;
    this.target = value;
    this.velocity = 0;
    this.remainder = 0;
  }

  /** Advances by `dt` seconds. */
  step(dt: number): void {
    if (this.settled) {
      this.value = this.target;
      this.velocity = 0;
      this.remainder = 0;
      return;
    }
    const response = this.reducedMotion
      ? this.config.response * motion.reduced.responseScale
      : this.config.response;
    const fraction = this.reducedMotion
      ? Math.max(1, this.config.dampingFraction)
      : this.config.dampingFraction;
    const omega = (2 * Math.PI) / response;
    const stiffness = omega * omega;
    const damping = 2 * fraction * omega;
    this.remainder += dt;
    let steps = 0;
    while (this.remainder >= STEP && steps < MAX_STEPS) {
      // Semi-implicit Euler: stable for the stiffness range used here.
      this.velocity += (stiffness * (this.target - this.value) - damping * this.velocity) * STEP;
      this.value += this.velocity * STEP;
      this.remainder -= STEP;
      steps++;
    }
    if (steps === MAX_STEPS) this.remainder = 0;
    if (this.settled) {
      this.value = this.target;
      this.velocity = 0;
    }
  }
}

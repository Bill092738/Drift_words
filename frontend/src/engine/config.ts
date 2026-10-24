// Tunable engine parameters in one place. The values are the shipped defaults
// that the feel was approved with; change them here, not at the use sites.
// Spring presets (camera glide, selection, drops) live in api.ts as `springs`.
import type { SpringConfig } from './api.ts';

/** Gesture recognition and motion feel. */
export const motion = {
  zoom: {
    min: 0.05,
    max: 8,
  },
  tap: {
    /** Movement beyond this many pixels turns a press into a drag. */
    slopPx: 8,
    /** Presses held longer than this are not taps. */
    maxMs: 500,
  },
  fling: {
    /** Release velocity is measured over this many milliseconds before the release. */
    windowMs: 100,
    /** Slower releases do not fling (pixels per second). */
    minSpeed: 100,
    maxSpeed: 6000,
    /** Exponential decay rate per second. Velocity halves about every 0.17 s. */
    friction: 4,
    /** A fling ends when it is slower than this (pixels per second). */
    restSpeed: 8,
  },
  wheel: {
    /** Zoom exponent per wheel pixel. */
    sensitivity: 0.0015,
    /** Trackpad pinch arrives as ctrlKey with small deltas. */
    pinchSensitivity: 0.01,
    /** Wheel zoom eases with this spring; critically damped so it never overshoots. */
    spring: { response: 0.22, dampingFraction: 1 } satisfies SpringConfig,
  },
  reduced: {
    /** With reduced motion, springs use `response * responseScale` and never overshoot. */
    responseScale: 0.5,
  },
  /** Frames longer than this many seconds are treated as this long, so a background tab does not cause a jump. */
  maxFrameSeconds: 0.1,
};

/** Rendering quality. */
export const quality = {
  /** Device pixel ratio cap. */
  maxResolution: 2,
  /** World units per cell of the host's CSS dot grid (the desk background). */
  gridCell: 24,
  antialias: true,
  text: {
    /** Text texture resolution tiers are powers of two within this range. */
    minTier: 0.25,
    maxTier: 8,
    /** A tier may be this much lower than the screen needs (1.25 = up to 25% soft) before the next tier up is used. */
    upscaleTolerance: 1.25,
    /** A text re-rasterizes down only when it needs less than this fraction of its tier. */
    downscaleBelow: 0.35,
    /** At most this many texts are re-rasterized per frame after a tier change. */
    rebuildsPerFrame: 24,
  },
  perfOverlay: {
    /** Seconds between overlay refreshes; statistics cover the same window. */
    refreshSeconds: 0.5,
  },
};

import { useEffect, useRef, useSyncExternalStore } from 'react';
import {
  getPreferences,
  onReducedMotionChange,
  type Preferences,
  reducedMotion,
  subscribePreferences,
} from '../../a11y/preferences.ts';
import type { SpringConfig } from '../../engine/api.ts';
import { SpringValue } from '../../motion/spring.ts';

export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const mql = window.matchMedia(query);
      mql.addEventListener('change', onChange);
      return () => mql.removeEventListener('change', onChange);
    },
    () => window.matchMedia(query).matches,
    () => false,
  );
}

/** Reduced motion from the system or from the app's "Reduce motion" setting. */
export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(onReducedMotionChange, reducedMotion, () => false);
}

/** The accessibility settings, re-rendering when one changes. */
export function usePreferences(): Preferences {
  return useSyncExternalStore(subscribePreferences, getPreferences, getPreferences);
}

/**
 * Runs a spring toward `target` and calls `render` with its value on every
 * animation frame, outside React rendering. `render` should write styles to
 * DOM refs directly; it is also called once on mount.
 *
 * Returns the spring so gestures can drive it (`snap` while dragging, then
 * set a target and velocity on release) and call `kick` to resume animating.
 */
export function useSpring(
  target: number,
  config: SpringConfig,
  render: (value: number) => void,
  precision?: number,
): { spring: SpringValue; kick: () => void } {
  const reduced = usePrefersReducedMotion();
  const springRef = useRef<SpringValue | null>(null);
  springRef.current ??= new SpringValue(target, config, precision);
  const spring = springRef.current;
  const renderRef = useRef(render);
  renderRef.current = render;
  const frame = useRef<number | null>(null);
  const kickRef = useRef<() => void>(() => {});

  kickRef.current = () => {
    if (frame.current !== null) return;
    let last = performance.now();
    const tick = (now: number) => {
      const moving = reduced ? (spring.snap(spring.target), false) : spring.step((now - last) / 1000);
      last = now;
      renderRef.current(spring.value);
      frame.current = moving ? requestAnimationFrame(tick) : null;
    };
    frame.current = requestAnimationFrame(tick);
  };

  useEffect(() => {
    spring.configure(config);
  }, [spring, config]);

  useEffect(() => {
    spring.target = target;
    kickRef.current();
  }, [spring, target]);

  useEffect(() => {
    renderRef.current(spring.value);
    return () => {
      if (frame.current !== null) cancelAnimationFrame(frame.current);
      frame.current = null;
    };
  }, [spring]);

  return { spring, kick: () => kickRef.current() };
}

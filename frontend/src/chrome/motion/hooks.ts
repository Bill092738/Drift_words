import { useEffect, useRef, useSyncExternalStore } from 'react';
import type { SpringConfig } from '../../engine/api.ts';
import { SpringValue } from './spring.ts';

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

export function usePrefersReducedMotion(): boolean {
  return useMediaQuery('(prefers-reduced-motion: reduce)');
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

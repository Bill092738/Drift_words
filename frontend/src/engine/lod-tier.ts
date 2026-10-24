import { quality } from './config.ts';

type TextConfig = typeof quality.text;

/**
 * The texture resolution tier for text that needs `needed` screen pixels per
 * text pixel. Tiers are powers of two, so zooming re-rasterizes only when a
 * boundary is crossed, and a dead band stops it flip-flopping near one.
 *
 * @param current the tier in use, or null for text that has none yet
 */
export function chooseTier(
  current: number | null,
  needed: number,
  config: TextConfig = quality.text,
): number {
  const clamp = (t: number): number => Math.min(config.maxTier, Math.max(config.minTier, t));
  const ideal = clamp(2 ** Math.ceil(Math.log2(Math.max(needed / config.upscaleTolerance, 1e-6))));
  if (current === null) return ideal;
  if (ideal > current) return ideal;
  if (ideal < current && needed < current * config.downscaleBelow) return ideal;
  return current;
}

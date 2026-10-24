import { describe, expect, it } from 'vitest';
import { quality } from './config.ts';
import { chooseTier } from './lod-tier.ts';

describe('chooseTier', () => {
  it('picks a power of two that is sharp enough', () => {
    expect(chooseTier(null, 1)).toBe(1);
    expect(chooseTier(null, 2)).toBe(2);
    expect(chooseTier(null, 3)).toBe(4);
    expect(chooseTier(null, 0.4)).toBe(0.5);
  });

  it('tolerates slightly soft text instead of jumping to the next tier', () => {
    expect(chooseTier(null, 2 * quality.text.upscaleTolerance)).toBe(2);
    expect(chooseTier(null, 2 * quality.text.upscaleTolerance + 0.01)).toBe(4);
  });

  it('stays within the configured range', () => {
    expect(chooseTier(null, 1e-9)).toBe(quality.text.minTier);
    expect(chooseTier(null, 1e9)).toBe(quality.text.maxTier);
  });

  it('goes up as soon as the screen needs it', () => {
    expect(chooseTier(1, 2.5)).toBe(2);
    expect(chooseTier(1, 7)).toBe(8);
  });

  it('does not flip-flop when zoom hovers near a boundary', () => {
    let tier = chooseTier(null, 2.6); // 4
    expect(tier).toBe(4);
    for (const needed of [2.4, 2.1, 2.6, 2.0, 1.8, 2.5]) {
      tier = chooseTier(tier, needed);
      expect(tier).toBe(4);
    }
  });

  it('goes down only once the screen needs much less', () => {
    expect(chooseTier(4, 1.5)).toBe(4);
    expect(chooseTier(4, 1.3)).toBe(2);
    expect(chooseTier(4, 0.2)).toBe(0.25);
  });

  it('settles: repeated calls at one zoom are stable', () => {
    for (const needed of [0.1, 0.7, 1, 1.6, 2, 5, 9]) {
      const once = chooseTier(null, needed);
      expect(chooseTier(once, needed)).toBe(once);
    }
  });
});

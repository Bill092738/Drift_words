import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ServerMsg, Stamped } from '../protocol/index.ts';
import { MockTransport } from './mock.ts';

const log: Stamped[] = [
  { seq: 1, atMs: 1000, event: { type: 'DivergenceSet', divergence: 0.1 } },
  { seq: 2, atMs: 1500, event: { type: 'DivergenceSet', divergence: 0.2 } },
  { seq: 3, atMs: 60000, event: { type: 'WrappedUp' } },
];

function seqs(msgs: ServerMsg[]): number[] {
  return msgs.flatMap((m) => (m.type === 'Events' ? m.events.map((e) => e.seq) : []));
}

describe('MockTransport', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('replays events with their recorded gaps, scaled by speed', () => {
    const got: ServerMsg[] = [];
    new MockTransport(log, { speed: 2 }).subscribe((m) => got.push(m));

    vi.advanceTimersByTime(0);
    expect(seqs(got)).toEqual([1]);
    vi.advanceTimersByTime(249);
    expect(seqs(got)).toEqual([1]);
    vi.advanceTimersByTime(1);
    expect(seqs(got)).toEqual([1, 2]);
  });

  it('caps long gaps', () => {
    const got: ServerMsg[] = [];
    new MockTransport(log, { maxGapMs: 3000 }).subscribe((m) => got.push(m));
    vi.advanceTimersByTime(500 + 3000);
    expect(seqs(got)).toEqual([1, 2, 3]);
  });

  it('stops delivering after close', () => {
    const got: ServerMsg[] = [];
    const t = new MockTransport(log);
    t.subscribe((m) => got.push(m));
    vi.advanceTimersByTime(0);
    t.close();
    vi.advanceTimersByTime(10_000);
    expect(seqs(got)).toEqual([1]);
  });

  it('hands commands to onCommand with increasing request ids', () => {
    const sent: [string, number][] = [];
    const t = new MockTransport(log, { onCommand: (c, req) => sent.push([c.type, req]) });
    t.send({ type: 'WrapUp' });
    t.send({ type: 'Strike', entryId: 4 });
    expect(sent).toEqual([
      ['WrapUp', 1],
      ['Strike', 2],
    ]);
  });
});

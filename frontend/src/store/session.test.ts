import { describe, expect, it } from 'vitest';
import type { Event, Stamped } from '../protocol/index.ts';
import { fixtures } from '../transport/fixtures.ts';
import { applyEvent, applyEvents, emptySession } from './session.ts';

function stamp(events: Event[]): Stamped[] {
  return events.map((event, i) => ({ seq: i + 1, atMs: i, event }));
}

const entry = (entryId: number, node: number) => ({
  entryId,
  node,
  relation: 'r',
  explanation: 'e',
  cites: [],
});

describe('applyEvents', () => {
  it('builds the tree with parents, order and the current node', () => {
    const s = applyEvents(
      emptySession,
      stamp([
        { type: 'NodeChosen', node: 1, parent: null, word: 'a', origin: 'cloud', fromCandidate: 1 },
        { type: 'NodeChosen', node: 2, parent: 1, word: 'b', origin: 'branch', fromCandidate: 7 },
        { type: 'NodeRevisited', node: 1 },
      ]),
    );
    expect(s.nodes.get(2)).toMatchObject({ parent: 1, order: 1, revisited: false });
    expect(s.nodes.get(1)?.revisited).toBe(true);
    expect(s.current).toBe(1);
  });

  it('collects streamed candidates until the ring is sealed', () => {
    const c = (candidateId: number, word: string) => ({ candidateId, word });
    const streamed = applyEvents(
      emptySession,
      stamp([
        { type: 'CandidateStreamed', node: 1, candidate: c(1, 'x') },
        { type: 'CandidateStreamed', node: 1, candidate: c(2, 'y') },
      ]),
    );
    expect(streamed.streaming.get(1)?.map((x) => x.word)).toEqual(['x', 'y']);

    const sealed = applyEvent(streamed, { seq: 3, atMs: 3, event: { type: 'BranchesOffered', node: 1, candidates: [c(1, 'x')] } });
    expect(sealed.streaming.has(1)).toBe(false);
    expect(sealed.offers.get(1)).toHaveLength(1);
  });

  it('accumulates priority, strikes and restores, and keeps it across revisions', () => {
    const s = applyEvents(
      emptySession,
      stamp([
        { type: 'EntryWritten', entry: entry(1, 2) },
        { type: 'EntryPromoted', entryId: 1, levels: 2 },
        { type: 'EntryPromoted', entryId: 1, levels: 3 },
        { type: 'EntryStruck', entryId: 1 },
        { type: 'EntryRevised', entry: { ...entry(1, 2), cites: [4] } },
      ]),
    );
    expect(s.entries.get(1)).toMatchObject({ priority: 5, struck: true, writtenSeq: 1 });
    expect(s.entries.get(1)?.entry.cites).toEqual([4]);

    const restored = applyEvent(s, { seq: 6, atMs: 6, event: { type: 'EntryRestored', entryId: 1 } });
    expect(restored.entries.get(1)?.struck).toBe(false);
  });

  it('skips events it has already applied', () => {
    const once = applyEvents(emptySession, stamp([{ type: 'EntryWritten', entry: entry(1, 2) }, { type: 'EntryPromoted', entryId: 1, levels: 1 }]));
    const again = applyEvents(once, stamp([{ type: 'EntryWritten', entry: entry(1, 2) }, { type: 'EntryPromoted', entryId: 1, levels: 1 }]));
    expect(again).toBe(once);
    expect(again.entries.get(1)?.priority).toBe(1);
  });

  it('ignores events about unknown entries and nodes', () => {
    const s = applyEvents(emptySession, stamp([{ type: 'EntryStruck', entryId: 9 }, { type: 'NodeRevisited', node: 9 }]));
    expect(s.entries.size).toBe(0);
    expect(s.lastSeq).toBe(2);
  });

  it('folds the exploration fixture', () => {
    const log = fixtures.get('exploration') ?? [];
    const s = applyEvents(emptySession, log);
    expect(s.nodes.size).toBe(6);
    expect(s.entries.size).toBe(5);
    expect(s.sources.size).toBe(5);
    expect(s.divergence).toBe(0.8);
    expect([...s.entries.values()].filter((e) => e.struck)).toHaveLength(1);
    expect(s.outputs).not.toBeNull();
    expect(s.lastSeq).toBe(log.length);
  });
});

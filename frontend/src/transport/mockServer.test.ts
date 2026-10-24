import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Event, ServerMsg } from '../protocol/index.ts';
import { applyEvents, emptySession, type SessionState } from '../store/session.ts';
import { isSingleWord, MockServer, repeatCap } from './mockServer.ts';

function harness(options = {}) {
  const server = new MockServer({ seed: 1, notes: false, ...options });
  const msgs: ServerMsg[] = [];
  let state: SessionState = emptySession;
  server.subscribe((m) => {
    msgs.push(m);
    if (m.type === 'Events') state = applyEvents(state, m.events);
  });
  const events = (): Event[] => msgs.flatMap((m) => (m.type === 'Events' ? m.events.map((s) => s.event) : []));
  const settle = async () => {
    await vi.runAllTimersAsync();
  };
  return { server, msgs, events, settle, state: () => state };
}

describe('MockServer', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('spawns a cloud, then grows a streamed, sealed ring for a picked word', async () => {
    const h = harness();
    await h.settle();
    const cloud = h.state().cloud;
    expect(cloud).toHaveLength(12);

    h.server.send({ type: 'Pick', candidateId: cloud[0]!.candidateId });
    await h.settle();
    const s = h.state();
    expect(s.nodes.get(1)).toMatchObject({ word: cloud[0]!.word, origin: 'cloud', parent: null });
    expect(s.offers.get(1)).toHaveLength(6);
    expect(h.events().filter((e) => e.type === 'CandidateStreamed')).toHaveLength(6);
    expect(s.streaming.size).toBe(0);
  });

  it('never offers a chosen word again', async () => {
    const h = harness({ ringSize: 8 });
    await h.settle();
    let pick = h.state().cloud[0]!;
    for (let i = 0; i < 12; i++) {
      h.server.send({ type: 'Pick', candidateId: pick.candidateId });
      await h.settle();
      const s = h.state();
      const chosen = new Set([...s.nodes.values()].map((n) => n.word.toLowerCase()));
      const ring = s.offers.get(s.current!) ?? [];
      expect(ring.filter((c) => chosen.has(c.word.toLowerCase()))).toEqual([]);
      pick = ring[0]!;
    }
  });

  it('caps how often an unchosen word reappears', async () => {
    const h = harness();
    await h.settle();
    h.server.send({ type: 'SetDivergence', divergence: 1 });
    h.server.send({ type: 'Pick', candidateId: h.state().cloud[0]!.candidateId });
    await h.settle();
    // Backtracking repeatedly to the same node re-offers its neighborhood.
    h.server.send({ type: 'Pick', candidateId: h.state().offers.get(1)![0]!.candidateId });
    await h.settle();
    for (let i = 0; i < 6; i++) {
      h.server.send({ type: 'Backtrack', node: i % 2 === 0 ? 1 : 2 });
      await h.settle();
    }
    const counts = new Map<string, number>();
    for (const e of h.events()) {
      if (e.type === 'BranchesOffered') for (const c of e.candidates) counts.set(c.word, (counts.get(c.word) ?? 0) + 1);
    }
    expect(Math.max(...counts.values())).toBeLessThanOrEqual(repeatCap(1));
  });

  it('inserts single words and rejects anything else', async () => {
    const h = harness();
    await h.settle();
    h.server.send({ type: 'InsertWord', word: 'early' });
    h.server.send({ type: 'StartWithWord', word: 'two words' });
    h.server.send({ type: 'StartWithWord', word: 'moss' });
    await h.settle();
    h.server.send({ type: 'InsertWord', word: 'velvet' });
    await h.settle();
    const rejections = h.msgs.flatMap((m) => (m.type === 'Rejected' ? [m.reason] : []));
    expect(rejections).toEqual(['pick or type a starting word first', 'one word only']);
    expect([...h.state().nodes.values()].map((n) => [n.word, n.origin, n.parent])).toEqual([
      ['moss', 'startWord', null],
      ['velvet', 'insert', 1],
    ]);
  });

  it('rejects picks of words that are no longer on offer', async () => {
    const h = harness();
    await h.settle();
    const [a, b] = h.state().cloud;
    h.server.send({ type: 'Pick', candidateId: a!.candidateId });
    h.server.send({ type: 'Pick', candidateId: b!.candidateId });
    await h.settle();
    expect(h.msgs.some((m) => m.type === 'Rejected')).toBe(true);
    expect(h.state().nodes.size).toBe(1);
  });

  it('writes a note for each new edge when notes are on', async () => {
    const h = harness({ notes: true });
    await h.settle();
    h.server.send({ type: 'Pick', candidateId: h.state().cloud[0]!.candidateId });
    await h.settle();
    h.server.send({ type: 'Pick', candidateId: h.state().offers.get(1)![0]!.candidateId });
    await h.settle();
    expect(h.state().entries.size).toBe(1);
    expect([...h.state().entries.values()][0]?.entry.node).toBe(2);
  });
});

describe('isSingleWord', () => {
  it('accepts one word of up to 40 characters', () => {
    expect(isSingleWord('serendipity')).toBe(true);
    expect(isSingleWord('\u6f02\u8bcd')).toBe(true); // CJK word
    expect(isSingleWord('two words')).toBe(false);
    expect(isSingleWord('')).toBe(false);
    expect(isSingleWord('x'.repeat(41))).toBe(false);
  });
});

import { describe, expect, it } from 'vitest';
import type { Event, Stamped } from '../protocol/index.ts';
import { applyEvents, emptySession } from '../store/session.ts';
import { announcements } from './announce.ts';

let seq = 0;
const stamp = (events: Event[]): Stamped[] => events.map((event) => ({ seq: ++seq, atMs: 0, event }));
const apply = (s: typeof emptySession, events: Event[]) => applyEvents(s, stamp(events));

const cloud = apply(emptySession, [
  {
    type: 'CloudSpawned',
    lang: 'en',
    candidates: [
      { candidateId: 1, word: 'tide' },
      { candidateId: 2, word: 'moon' },
    ],
  },
]);

describe('announcements', () => {
  it('reads the starting cloud', () => {
    expect(announcements(emptySession, cloud)).toEqual(['2 words are drifting: tide, moon. Pick one to begin.']);
  });

  it('says which word was chosen, then reads the new ring', () => {
    const chosen = apply(cloud, [
      { type: 'NodeChosen', node: 1, parent: null, word: 'tide', origin: 'cloud', fromCandidate: 1 },
    ]);
    expect(announcements(cloud, chosen)).toEqual(['You chose tide.']);
    const offered = apply(chosen, [
      {
        type: 'BranchesOffered',
        node: 1,
        candidates: [
          { candidateId: 3, word: 'gravity' },
          { candidateId: 4, word: 'salt' },
        ],
      },
    ]);
    expect(announcements(chosen, offered)).toEqual(['New words: gravity, salt.']);
  });

  it('says when nothing came up, and when the user goes back', () => {
    const a = apply(cloud, [
      { type: 'NodeChosen', node: 1, parent: null, word: 'tide', origin: 'cloud', fromCandidate: 1 },
      { type: 'NodeChosen', node: 2, parent: 1, word: 'gravity', origin: 'branch', fromCandidate: 3 },
    ]);
    const empty = apply(a, [{ type: 'BranchesOffered', node: 2, candidates: [] }]);
    expect(announcements(a, empty)).toEqual(['No new words came up.']);
    const back = apply(empty, [{ type: 'NodeRevisited', node: 1 }]);
    expect(announcements(empty, back)).toEqual(['Back at tide.']);
  });

  it('counts notes and sources, and reports the wrap-up and the outputs', () => {
    const a = apply(cloud, [
      { type: 'NodeChosen', node: 1, parent: null, word: 'tide', origin: 'cloud', fromCandidate: 1 },
      { type: 'NodeChosen', node: 2, parent: 1, word: 'moon', origin: 'branch', fromCandidate: 2 },
    ]);
    const b = apply(a, [
      {
        type: 'SourceFound',
        source: {
          sourceId: 1,
          node: 2,
          kind: 'webPage',
          title: 'Tide',
          site: 'Wikipedia',
          url: 'https://en.wikipedia.org/wiki/Tide',
          thumbnailUrl: null,
          csl: null,
        },
      },
      { type: 'EntryWritten', entry: { entryId: 1, node: 2, relation: 'pull', explanation: '', cites: [1] } },
    ]);
    expect(announcements(a, b)).toEqual(['A source landed: Tide.', 'A note was added.']);
    const wrapped = apply(b, [{ type: 'WrappedUp' }]);
    expect(announcements(b, wrapped)).toEqual(['Wrapped up. Writing your outputs.']);
    const done = apply(wrapped, [{ type: 'OutputsReady', outputs: { decisionTree: 't', draft: 'd', final: 'f' } }]);
    expect(announcements(wrapped, done)).toEqual(['Your outputs are ready.']);
  });

  it('says nothing when nothing a person would notice changed', () => {
    const placed = apply(cloud, [{ type: 'DivergenceSet', divergence: 0.7 }]);
    expect(announcements(cloud, placed)).toEqual([]);
  });
});

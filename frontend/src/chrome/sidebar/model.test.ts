import { describe, expect, it } from 'vitest';
import { applyEvents, emptySession } from '../../store/session.ts';
import { fixtures } from '../../transport/fixtures.ts';
import { sidebarModel } from './model.ts';

const session = applyEvents(emptySession, fixtures.get('exploration') ?? []);

describe('sidebarModel', () => {
  it('lists entries in path order with the words they connect', () => {
    const { entries } = sidebarModel(session, 'path');
    expect(entries.map((e) => `${e.from} -> ${e.to}`)).toEqual([
      'entropy -> information',
      'information -> noise',
      'noise -> creativity',
      'information -> attention',
      'attention -> flow',
    ]);
  });

  it('orders by priority, keeping struck entries last', () => {
    const { entries } = sidebarModel(session, 'priority');
    expect(entries.map((e) => [e.to, e.priority, e.struck])).toEqual([
      ['information', 2, false],
      ['flow', 2, false],
      ['attention', 1, false],
      ['noise', 0, false],
      ['creativity', 0, true],
    ]);
  });

  it('numbers references by first citation and maps citations to numbers', () => {
    const { entries, references } = sidebarModel(session, 'path');
    expect(references.map((r) => [r.number, r.source.title])).toEqual([
      [1, 'Entropy (information theory)'],
      [2, 'A Mathematical Theory of Communication'],
      [3, 'White noise'],
      [4, 'Attention Is All You Need'],
      [5, 'Flow (psychology)'],
    ]);
    expect(entries[0]?.cites).toEqual([1, 2]);
    expect(entries[2]?.cites).toEqual([]);
  });

  it('keeps sources that no entry cites out of the references but in the source list', () => {
    const s = applyEvents(emptySession, fixtures.get('sources-heavy') ?? []);
    const model = sidebarModel(s, 'path');
    expect(model.references).toEqual([]);
    expect(model.sources).toHaveLength(8);
  });
});

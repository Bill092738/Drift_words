import { describe, expect, it } from 'vitest';
import { fixtures } from './fixtures.ts';
import { mockOutputs } from './mockOutputs.ts';
import { applyEvents, emptySession } from '../store/session.ts';

function stateOf(name: string) {
  const log = fixtures.get(name);
  if (log === undefined) throw new Error(`no fixture ${name}`);
  // Without the recorded outputs, which are what the mock stands in for.
  return applyEvents(
    emptySession,
    log.filter((s) => s.event.type !== 'OutputsReady' && s.event.type !== 'WrappedUp'),
  );
}

describe('mockOutputs', () => {
  const state = stateOf('exploration');

  it('draws the same decision tree as the recorded one', () => {
    const recorded = fixtures.get('exploration')!.flatMap((s) => (s.event.type === 'OutputsReady' ? [s.event.outputs] : []))[0]!;
    expect(mockOutputs(state).decisionTree).toBe(recorded.decisionTree);
  });

  it('lists every entry in order, with the struck one crossed out', () => {
    const lines = mockOutputs(state)
      .draft.split('\n')
      .filter((l) => /^\d+\. /u.test(l));
    expect(lines).toHaveLength(5);
    expect(lines.filter((l) => l.includes('~~'))).toHaveLength(1);
    expect(lines[2]!.startsWith('3. ~~')).toBe(true);
  });

  it('keeps every un-struck entry in the final document, promoted or not', () => {
    const final = mockOutputs(state).final;
    expect(final.startsWith('# From entropy to flow')).toBe(true);
    const all = [...state.entries.values()];
    const kept = all.filter((e) => !e.struck).map((e) => e.entry.relation);
    const struck = all.filter((e) => e.struck).map((e) => e.entry.relation);
    expect(all.some((e) => !e.struck && e.priority === 0)).toBe(true);
    for (const relation of kept) expect(final).toContain(relation.replace(/[.]$/u, ''));
    expect(struck.length).toBeGreaterThan(0);
    for (const relation of struck) expect(final).not.toContain(relation.replace(/[.]$/u, ''));
  });

  it('says so when there is nothing yet', () => {
    const empty = mockOutputs(emptySession);
    expect(empty.draft).toContain('_No entries yet._');
    expect(empty.final).toContain('_No entries were kept._');
    expect(empty.decisionTree).toBe('```mermaid\nflowchart TD\n```');
  });

  it('escapes what it prints', () => {
    const hostile = applyEvents(emptySession, [
      { seq: 1, atMs: 0, event: { type: 'NodeChosen', node: 1, parent: null, word: 'a]b', origin: 'cloud', fromCandidate: null } },
      {
        seq: 2,
        atMs: 0,
        event: {
          type: 'EntryWritten',
          entry: { entryId: 1, node: 1, relation: '*x*', explanation: '<script>alert(1)</script> [l](http://e)', cites: [] },
        },
      },
    ]);
    const out = mockOutputs(hostile);
    expect(out.draft).not.toContain('<script>');
    expect(out.draft).not.toContain('[l]');
    expect(out.decisionTree).toContain('n1["a]b"]');
  });
});

import { describe, expect, it } from 'vitest';
import { fixtures } from '../transport/fixtures.ts';
import { isEventType, parseEventLog } from './index.ts';

describe('parseEventLog', () => {
  it('parses one stamped event per line and skips blank lines', () => {
    const log = parseEventLog(
      '{"seq":1,"atMs":0,"event":{"type":"WrappedUp"}}\n\n' +
        '{"seq":2,"atMs":5,"event":{"type":"DivergenceSet","divergence":0.5}}\n',
    );
    expect(log.map((s) => s.event.type)).toEqual(['WrappedUp', 'DivergenceSet']);
  });

  it('rejects unknown event types with the line number', () => {
    expect(() => parseEventLog('{"seq":1,"atMs":0,"event":{"type":"Nope"}}')).toThrow('line 1');
  });

  it('knows every event tag', () => {
    expect(isEventType('NodeChosen')).toBe(true);
    expect(isEventType('toString')).toBe(false);
  });
});

describe('fixtures', () => {
  it('are loaded', () => {
    expect([...fixtures.keys()]).toEqual(expect.arrayContaining(['exploration', 'sources-heavy']));
  });

  for (const [name, log] of fixtures) {
    it(`${name}: starts with CloudSpawned and numbers events from 1`, () => {
      expect(log[0]?.event.type).toBe('CloudSpawned');
      expect(log.map((s) => s.seq)).toEqual(log.map((_, i) => i + 1));
    });
  }
});

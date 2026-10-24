import { useEffect, useState } from 'react';
import type { Event, Stamped } from '../protocol/index.ts';
import { fixtures } from '../transport/fixtures.ts';
import { MockTransport } from '../transport/mock.ts';

const SPEEDS = [1, 4, 20] as const;

/**
 * M0 developer view: replays a fixture through MockTransport and lists the
 * events as they arrive. Replaced by the desk in M4.
 */
export function EventLogView() {
  const names = [...fixtures.keys()];
  const [fixture, setFixture] = useState(names[0] ?? '');
  const [speed, setSpeed] = useState<number>(4);
  const [run, setRun] = useState(0);
  const [received, setReceived] = useState<Stamped[]>([]);
  const total = fixtures.get(fixture)?.length ?? 0;

  useEffect(() => {
    const log = fixtures.get(fixture);
    if (log === undefined) return;
    setReceived([]);
    const transport = new MockTransport(log, { speed });
    transport.subscribe((msg) => {
      if (msg.type === 'Events') setReceived((prev) => [...prev, ...msg.events]);
    });
    return () => transport.close();
  }, [fixture, speed, run]);

  const start = received[0]?.atMs ?? 0;

  return (
    <main className="devlog">
      <header>
        <h1>Driftwords · event log</h1>
        <p className="muted">Replaying protocol fixtures through MockTransport (milestone M0).</p>
        <div className="controls">
          <label>
            Fixture{' '}
            <select value={fixture} onChange={(e) => setFixture(e.target.value)}>
              {names.map((n) => (
                <option key={n}>{n}</option>
              ))}
            </select>
          </label>
          <label>
            Speed{' '}
            <select value={speed} onChange={(e) => setSpeed(Number(e.target.value))}>
              {SPEEDS.map((s) => (
                <option key={s} value={s}>
                  {s}×
                </option>
              ))}
            </select>
          </label>
          <button onClick={() => setRun((r) => r + 1)}>Restart</button>
          <span className="muted">
            {received.length} / {total} events
          </span>
        </div>
      </header>
      <ol className="events">
        {received.map((s) => (
          <li key={s.seq}>
            <span className="seq">{s.seq}</span>
            <span className="time">+{((s.atMs - start) / 1000).toFixed(1)}s</span>
            <span className="tag">{s.event.type}</span>
            <span className="summary">{summarize(s.event)}</span>
          </li>
        ))}
      </ol>
    </main>
  );
}

function words(cs: { word: string }[]): string {
  return cs.map((c) => c.word).join(', ');
}

function summarize(e: Event): string {
  switch (e.type) {
    case 'CloudSpawned':
      return `${e.lang}: ${words(e.candidates)}`;
    case 'NodeChosen':
      return `#${e.node} "${e.word}" (${e.origin}${e.parent === null ? ', root' : `, parent #${e.parent}`})`;
    case 'CandidateStreamed':
      return `#${e.node} → ${e.candidate.word}`;
    case 'BranchesOffered':
      return `#${e.node} → ${words(e.candidates)}`;
    case 'NodeRevisited':
      return `back to #${e.node}`;
    case 'DivergenceSet':
      return e.divergence.toFixed(2);
    case 'SourceFound':
      return `${e.source.kind} for #${e.source.node}: ${e.source.title}`;
    case 'EntryWritten':
    case 'EntryRevised':
      return `entry ${e.entry.entryId} on #${e.entry.node}: ${e.entry.relation}`;
    case 'EntryPromoted':
      return `entry ${e.entryId} +${e.levels}`;
    case 'EntryStruck':
    case 'EntryRestored':
      return `entry ${e.entryId}`;
    case 'NodePlaced':
      return `#${e.node} at (${e.pos.x.toFixed(0)}, ${e.pos.y.toFixed(0)})`;
    case 'SourcePlaced':
      return `source ${e.sourceId} at (${e.pos.x.toFixed(0)}, ${e.pos.y.toFixed(0)})`;
    case 'WrappedUp':
      return '';
    case 'OutputsReady':
      return `${e.outputs.final.split('\n').length} lines of final text`;
  }
}

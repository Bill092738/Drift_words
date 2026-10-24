import { useEffect, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { Sidebar } from './chrome/sidebar/Sidebar.tsx';
import { DeskPlaceholder } from './dev/DeskPlaceholder.tsx';
import { createSessionStore, type SessionStore } from './store/store.ts';
import { fixtures } from './transport/fixtures.ts';
import { answerDeterministic, MockTransport } from './transport/mock.ts';

const SPEEDS = [1, 4, 20] as const;

/**
 * The app on fixtures: replays a recorded session through MockTransport and
 * answers curation commands locally, so the chrome is fully interactive
 * without a backend. M5 switches this to WebSocketTransport.
 */
export function App() {
  const names = [...fixtures.keys()];
  const [fixture, setFixture] = useState(names.includes('exploration') ? 'exploration' : (names[0] ?? ''));
  const [speed, setSpeed] = useState<number>(4);
  const [run, setRun] = useState(0);
  const [store, setStore] = useState<StoreApi<SessionStore> | null>(null);

  useEffect(() => {
    const log = fixtures.get(fixture);
    if (log === undefined) return;
    const transport = new MockTransport(log, { speed, respond: answerDeterministic });
    const [s, detach] = createSessionStore(transport);
    setStore(s);
    return () => {
      detach();
      transport.close();
    };
  }, [fixture, speed, run]);

  return (
    <>
      {store && <DeskPlaceholder key={`desk-${run}`} store={store} />}
      {store && <Sidebar key={`sidebar-${fixture}-${speed}-${run}`} store={store} />}
      <div className="dev-toolbar" role="toolbar" aria-label="Fixture replay">
        <strong>Driftwords</strong>
        <select value={fixture} onChange={(e) => setFixture(e.target.value)} aria-label="Fixture">
          {names.map((n) => (
            <option key={n}>{n}</option>
          ))}
        </select>
        <select value={speed} onChange={(e) => setSpeed(Number(e.target.value))} aria-label="Speed">
          {SPEEDS.map((s) => (
            <option key={s} value={s}>
              {s}×
            </option>
          ))}
        </select>
        <button onClick={() => setRun((r) => r + 1)}>Restart</button>
        <a href="?view=log">Event log</a>
      </div>
    </>
  );
}

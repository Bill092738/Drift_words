import { useEffect, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { Controls } from './chrome/controls/Controls.tsx';
import { Sidebar } from './chrome/sidebar/Sidebar.tsx';
import { Desk } from './desk/Desk.tsx';
import type { DeskScene } from './desk/DeskScene.ts';
import { createSessionStore, type SessionStore, useSession } from './store/store.ts';
import { fixtures } from './transport/fixtures.ts';
import { answerDeterministic, MockTransport } from './transport/mock.ts';
import { MockServer } from './transport/mockServer.ts';
import type { Transport } from './transport/transport.ts';

const INTERACTIVE = 'interactive';
const SPEEDS = [1, 4, 20] as const;

function Diagnostics({ store }: { store: StoreApi<SessionStore> }) {
  const diagnostics = useSession(store, (s) => s.diagnostics);
  if (diagnostics.length === 0) return <p className="dev-diagnostics-empty">No diagnostics.</p>;
  return (
    <ol className="dev-diagnostics-list">
      {diagnostics.map((diagnostic, index) => (
        <li key={index} data-level={diagnostic.level}>
          <strong>{diagnostic.level}</strong> {diagnostic.message}
        </li>
      ))}
    </ol>
  );
}

/**
 * The app without a backend. "interactive" runs an in-browser mock session
 * that answers every command; the other modes replay recorded fixtures.
 * M5 switches this to WebSocketTransport.
 */
export function App() {
  const modes = [INTERACTIVE, ...fixtures.keys()];
  const [mode, setMode] = useState(INTERACTIVE);
  const [speed, setSpeed] = useState<number>(1);
  const [run, setRun] = useState(0);
  const [showDiagnostics, setShowDiagnostics] = useState(false);
  const [store, setStore] = useState<StoreApi<SessionStore> | null>(null);
  const desk = useRef<DeskScene | null>(null);

  useEffect(() => {
    let transport: Transport;
    if (mode === INTERACTIVE) {
      transport = new MockServer({ seed: Date.now() % 100_000 });
    } else {
      const log = fixtures.get(mode);
      if (log === undefined) return;
      transport = new MockTransport(log, { speed, respond: answerDeterministic });
    }
    const [s, detach] = createSessionStore(transport);
    setStore(s);
    return () => {
      detach();
      transport.close();
    };
  }, [mode, speed, run]);

  return (
    <>
      {store && <Desk store={store} onScene={(scene) => (desk.current = scene)} />}
      {store && <Controls store={store} />}
      {store && (
        <Sidebar key={`${mode}-${speed}-${run}`} store={store} onLocateSource={(id) => desk.current?.locateSource(id)} />
      )}
      <div className="dev-toolbar" role="toolbar" aria-label="Session source">
        <strong>Driftwords</strong>
        <select value={mode} onChange={(e) => setMode(e.target.value)} aria-label="Session source">
          {modes.map((m) => (
            <option key={m} value={m}>
              {m === INTERACTIVE ? 'Interactive (mock)' : `Replay: ${m}`}
            </option>
          ))}
        </select>
        {mode !== INTERACTIVE && (
          <select value={speed} onChange={(e) => setSpeed(Number(e.target.value))} aria-label="Speed">
            {SPEEDS.map((s) => (
              <option key={s} value={s}>
                {s}×
              </option>
            ))}
          </select>
        )}
        <button onClick={() => setRun((r) => r + 1)}>Restart</button>
        <button
          type="button"
          aria-expanded={showDiagnostics}
          aria-controls="dev-diagnostics"
          aria-label="Toggle diagnostics"
          onClick={() => setShowDiagnostics((shown) => !shown)}
        >
          &lt;&gt;
        </button>
        <a href="?view=log">Event log</a>
      </div>
      {store && showDiagnostics && (
        <aside id="dev-diagnostics" className="dev-diagnostics" aria-label="Diagnostics">
          <header>Diagnostics</header>
          <Diagnostics store={store} />
        </aside>
      )}
    </>
  );
}

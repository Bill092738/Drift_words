import { useEffect, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { Controls } from './chrome/controls/Controls.tsx';
import { Sidebar } from './chrome/sidebar/Sidebar.tsx';
import { Desk } from './desk/Desk.tsx';
import type { DeskScene } from './desk/DeskScene.ts';
import { createSessionStore, type SessionStore, useSession } from './store/store.ts';
import { fixtures } from './transport/fixtures.ts';
import { createLiveSession, sessionFromUrl, setSessionInUrl, wantsLive } from './transport/live.ts';
import { answerDeterministic, MockTransport } from './transport/mock.ts';
import { MockServer } from './transport/mockServer.ts';
import type { Transport } from './transport/transport.ts';
import { type ConnectionStatus, WebSocketTransport } from './transport/ws.ts';

const INTERACTIVE = 'interactive';
const LIVE = 'live';
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

const STATUS_LABELS: Record<ConnectionStatus, string> = {
  connecting: 'Connecting…',
  open: 'Connected',
  reconnecting: 'Reconnecting…',
};

/**
 * The app. "live" talks to drift-server over WebSocket; the session id is kept
 * in the URL (`?session=…`), so a reload resumes the same desk. "interactive"
 * runs an in-browser mock session that answers every command, and the other
 * modes replay recorded fixtures; both work without a backend.
 */
export function App() {
  const modes = [INTERACTIVE, LIVE, ...fixtures.keys()];
  const [mode, setMode] = useState(() => (wantsLive() ? LIVE : INTERACTIVE));
  const [speed, setSpeed] = useState<number>(1);
  const [run, setRun] = useState(0);
  const [showDiagnostics, setShowDiagnostics] = useState(false);
  const [store, setStore] = useState<StoreApi<SessionStore> | null>(null);
  const [liveStatus, setLiveStatus] = useState<string | null>(null);
  const desk = useRef<DeskScene | null>(null);
  // One session per live run, even when StrictMode runs the effect twice.
  const creating = useRef<{ run: number; id: Promise<string> } | null>(null);

  useEffect(() => {
    if (mode === LIVE) {
      let cancelled = false;
      let cleanup = () => {};
      setStore(null);
      setLiveStatus('Starting a session…');
      const existing = sessionFromUrl();
      if (existing === null && creating.current?.run !== run) {
        creating.current = { run, id: createLiveSession('en') };
      }
      const id = existing !== null ? Promise.resolve(existing) : creating.current!.id;
      id.then(
        (sessionId) => {
          if (cancelled) return;
          setSessionInUrl(sessionId);
          const transport = WebSocketTransport.forSession(sessionId, {
            onStatus: (status) => setLiveStatus(STATUS_LABELS[status]),
          });
          const [s, detach] = createSessionStore(transport);
          setStore(s);
          cleanup = () => {
            detach();
            transport.close();
          };
        },
        (error: unknown) => {
          if (cancelled) return;
          creating.current = null;
          const reason = error instanceof Error ? error.message : String(error);
          setLiveStatus(`Backend unavailable (${reason}). Start drift-server with make server.`);
        },
      );
      return () => {
        cancelled = true;
        cleanup();
      };
    }
    setLiveStatus(null);
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

  const chooseMode = (next: string) => {
    // Leaving live mode forgets the session, so a reload opens the mock again.
    if (next !== LIVE) setSessionInUrl(null);
    // Picking live mode in the toolbar starts a new session.
    else creating.current = null;
    setMode(next);
  };

  const restart = () => {
    // A live restart starts a new session; the old one stays in the database.
    if (mode === LIVE) setSessionInUrl(null);
    setRun((r) => r + 1);
  };

  return (
    <>
      {store && <Desk store={store} onScene={(scene) => (desk.current = scene)} />}
      {store && <Controls store={store} />}
      {store && (
        <Sidebar key={`${mode}-${speed}-${run}`} store={store} onLocateSource={(id) => desk.current?.locateSource(id)} />
      )}
      <div className="dev-toolbar" role="toolbar" aria-label="Session source">
        <strong>Driftwords</strong>
        <select value={mode} onChange={(e) => chooseMode(e.target.value)} aria-label="Session source">
          {modes.map((m) => (
            <option key={m} value={m}>
              {m === INTERACTIVE ? 'Interactive (mock)' : m === LIVE ? 'Live (backend)' : `Replay: ${m}`}
            </option>
          ))}
        </select>
        {mode !== INTERACTIVE && mode !== LIVE && (
          <select value={speed} onChange={(e) => setSpeed(Number(e.target.value))} aria-label="Speed">
            {SPEEDS.map((s) => (
              <option key={s} value={s}>
                {s}×
              </option>
            ))}
          </select>
        )}
        <button onClick={restart}>{mode === LIVE ? 'New session' : 'Restart'}</button>
        {liveStatus !== null && (
          <span className="dev-toolbar-status" role="status">
            {liveStatus}
          </span>
        )}
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

import { useEffect, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { AccessibilitySettings } from './a11y/AccessibilitySettings.tsx';
import { WordList } from './a11y/WordList.tsx';
import { Controls } from './chrome/controls/Controls.tsx';
import { DeskLoading, DeskLoadingPlaceholder } from './chrome/feedback/DeskLoading.tsx';
import { Toaster } from './chrome/feedback/Toaster.tsx';
import { OutputsHost } from './chrome/outputs/OutputsHost.tsx';
import { type Connection, ConnectionPill } from './chrome/shell/ConnectionPill.tsx';
import { HelpPopover } from './chrome/shell/HelpPopover.tsx';
import './chrome/shell/shell.css';
import { Sidebar } from './chrome/sidebar/Sidebar.tsx';
import { Desk } from './desk/Desk.tsx';
import type { DeskScene } from './desk/DeskScene.ts';
import { devMode } from './devMode.ts';
import { createSessionStore, type SessionStore, useSession } from './store/store.ts';
import { fixtures } from './transport/fixtures.ts';
import { createLiveSession, sessionFromUrl, setSessionInUrl, wantsLive } from './transport/live.ts';
import { answerDeterministic, MockTransport } from './transport/mock.ts';
import { MockServer } from './transport/mockServer.ts';
import type { Transport } from './transport/transport.ts';
import { WebSocketTransport } from './transport/ws.ts';

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

/**
 * The app. "live" talks to drift-server over WebSocket; the session id is kept
 * in the URL (`?session=…`), so a reload resumes the same desk. "interactive"
 * runs an in-browser mock session that answers every command, and the other
 * modes replay recorded fixtures; both work without a backend.
 *
 * The bar at the top left shows the name and help. In developer mode (see
 * devMode.ts) it also holds the session-source tools.
 */
export function App() {
  const modes = [INTERACTIVE, LIVE, ...fixtures.keys()];
  const [mode, setMode] = useState(() => (wantsLive() ? LIVE : INTERACTIVE));
  const [speed, setSpeed] = useState<number>(1);
  const [run, setRun] = useState(0);
  const [showDiagnostics, setShowDiagnostics] = useState(false);
  const [store, setStore] = useState<StoreApi<SessionStore> | null>(null);
  const [connection, setConnection] = useState<Connection>({ state: 'none' });
  // The live session's id, for the downloads the backend makes; null offline.
  const [liveSessionId, setLiveSessionId] = useState<string | null>(null);
  const [outputsOpen, setOutputsOpen] = useState(false);
  const [wrapRequested, setWrapRequested] = useState(false);
  const desk = useRef<DeskScene | null>(null);
  // One session per live run, even when StrictMode runs the effect twice.
  const creating = useRef<{ run: number; id: Promise<string> } | null>(null);

  useEffect(() => {
    // A new session starts without the previous one's outputs on screen.
    setOutputsOpen(false);
    setWrapRequested(false);
    setLiveSessionId(null);
    if (mode === LIVE) {
      let cancelled = false;
      let cleanup = () => {};
      setStore(null);
      setConnection({ state: 'starting' });
      const existing = sessionFromUrl();
      if (existing === null && creating.current?.run !== run) {
        creating.current = { run, id: createLiveSession('en') };
      }
      const id = existing !== null ? Promise.resolve(existing) : creating.current!.id;
      id.then(
        (sessionId) => {
          if (cancelled) return;
          setSessionInUrl(sessionId);
          setLiveSessionId(sessionId);
          const transport = WebSocketTransport.forSession(sessionId, {
            onStatus: (status) => setConnection({ state: status }),
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
          setConnection({ state: 'failed', reason: `(${reason})` });
        },
      );
      return () => {
        cancelled = true;
        cleanup();
      };
    }
    setConnection({ state: 'none' });
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

  // After a failed start, try the same session again (or a new one).
  const retry = () => setRun((r) => r + 1);

  return (
    <>
      {store && <Desk store={store} onScene={(scene) => (desk.current = scene)} />}
      {store ? (
        <DeskLoading store={store} />
      ) : (
        connection.state !== 'failed' && <DeskLoadingPlaceholder />
      )}
      {store && <Toaster store={store} />}
      {store && <WordList store={store} />}
      {store && <Controls store={store} onWrapUp={() => setWrapRequested(true)} onViewOutputs={() => setOutputsOpen(true)} />}
      {store && (
        <OutputsHost
          store={store}
          sessionId={liveSessionId}
          open={outputsOpen}
          onOpenChange={setOutputsOpen}
          autoOpen={wrapRequested}
        />
      )}
      {store && (
        <Sidebar key={`${mode}-${speed}-${run}`} store={store} onLocateSource={(id) => desk.current?.locateSource(id)} />
      )}
      <ConnectionPill connection={connection} onRetry={retry} />
      <header className="app-bar material" role="toolbar" aria-label="Driftwords">
        <span className="brand">
          <img className="brand-mark" src="/favicon.svg" alt="" />
          Driftwords
        </span>
        <HelpPopover>
          <AccessibilitySettings />
        </HelpPopover>
        {devMode && (
          <>
            <span className="app-bar-divider" aria-hidden="true" />
            <div className="dev-tools" aria-label="Developer tools">
              <span className="dev-badge" title="Developer mode: the Vite dev server or ?dev">
                DEV
              </span>
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
              <button type="button" className="btn btn-secondary btn-sm" onClick={restart}>
                {mode === LIVE ? 'New session' : 'Restart'}
              </button>
              <button
                type="button"
                className="btn btn-secondary btn-sm"
                aria-expanded={showDiagnostics}
                aria-controls="dev-diagnostics"
                onClick={() => setShowDiagnostics((shown) => !shown)}
              >
                Diagnostics
              </button>
              <a className="btn btn-secondary btn-sm" href="?view=log">
                Event log
              </a>
            </div>
          </>
        )}
      </header>
      {devMode && store && showDiagnostics && (
        <aside id="dev-diagnostics" className="dev-diagnostics" aria-label="Diagnostics">
          <header>Diagnostics</header>
          <Diagnostics store={store} />
        </aside>
      )}
    </>
  );
}

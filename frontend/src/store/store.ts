import { useStore } from 'zustand';
import { createStore, type StoreApi } from 'zustand/vanilla';
import type { Command, DiagnosticLevel } from '../protocol/index.ts';
import type { Transport } from '../transport/transport.ts';
import { applyEvents, emptySession, type SessionState } from './session.ts';

export interface SessionStore {
  state: SessionState;
  /** The most recent rejection from the server, for a transient notice. */
  lastRejection: { req: number; reason: string } | null;
  /** Ephemeral developer diagnostics; these are never part of session replay. */
  diagnostics: ReadonlyArray<{ level: DiagnosticLevel; message: string }>;
  send: (command: Command) => number;
}

/**
 * Binds a session store to a transport. The canvas engine subscribes to the
 * vanilla store directly; React components use {@link useSession}.
 * Returns the store and a function that detaches it from the transport.
 */
export function createSessionStore(transport: Transport): [StoreApi<SessionStore>, () => void] {
  const store = createStore<SessionStore>()(() => ({
    state: emptySession,
    lastRejection: null,
    diagnostics: [],
    send: (command) => transport.send(command),
  }));
  const detach = transport.subscribe((msg) => {
    if (msg.type === 'Events') {
      store.setState((s) => ({ state: applyEvents(s.state, msg.events) }));
    } else if (msg.type === 'Rejected') {
      store.setState({ lastRejection: { req: msg.req, reason: msg.reason } });
    } else {
      store.setState((s) => ({
        diagnostics: [...s.diagnostics, { level: msg.level, message: msg.message }],
      }));
    }
  });
  return [store, detach];
}

export function useSession<T>(store: StoreApi<SessionStore>, selector: (s: SessionStore) => T): T {
  return useStore(store, selector);
}

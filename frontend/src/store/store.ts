import { useStore } from 'zustand';
import { createStore, type StoreApi } from 'zustand/vanilla';
import type { Command } from '../protocol/index.ts';
import type { Transport } from '../transport/transport.ts';
import { applyEvents, emptySession, type SessionState } from './session.ts';

export interface SessionStore {
  state: SessionState;
  /** The most recent rejection from the server, for a transient notice. */
  lastRejection: { req: number; reason: string } | null;
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
    send: (command) => transport.send(command),
  }));
  const detach = transport.subscribe((msg) => {
    if (msg.type === 'Events') {
      store.setState((s) => ({ state: applyEvents(s.state, msg.events) }));
    } else {
      store.setState({ lastRejection: { req: msg.req, reason: msg.reason } });
    }
  });
  return [store, detach];
}

export function useSession<T>(store: StoreApi<SessionStore>, selector: (s: SessionStore) => T): T {
  return useStore(store, selector);
}

import type { StoreApi } from 'zustand/vanilla';
import { useSession, type SessionStore } from '../../store/store.ts';
import './feedback.css';

/** Shown while there is no session yet (a live session starting). */
export function DeskLoadingPlaceholder() {
  return (
    <div className="desk-loading" role="status">
      <span className="spinner spinner-lg" aria-hidden="true" />
      Gathering words…
    </div>
  );
}

/** Shown until the session's first words arrive, so the desk is never just empty. */
export function DeskLoading({ store }: { store: StoreApi<SessionStore> }) {
  const empty = useSession(store, (s) => s.state.cloud.length === 0 && s.state.nodes.size === 0 && !s.state.wrappedUp);
  return empty ? <DeskLoadingPlaceholder /> : null;
}

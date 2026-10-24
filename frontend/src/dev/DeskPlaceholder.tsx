import type { StoreApi } from 'zustand/vanilla';
import type { NodeId } from '../protocol/index.ts';
import type { SessionState } from '../store/session.ts';
import { useSession, type SessionStore } from '../store/store.ts';

function pathToCurrent(s: SessionState): { id: NodeId; word: string }[] {
  const path: { id: NodeId; word: string }[] = [];
  let id = s.current;
  while (id !== null) {
    const node = s.nodes.get(id);
    if (node === undefined) break;
    path.unshift({ id, word: node.word });
    id = node.parent;
  }
  return path;
}

/** Stands in for the desk until the M3 engine and M4 word tree land. */
export function DeskPlaceholder({ store }: { store: StoreApi<SessionStore> }) {
  const state = useSession(store, (s) => s.state);
  const path = pathToCurrent(state);
  const words = path.length > 0 ? path : state.cloud.map((c) => ({ id: -c.candidateId, word: c.word }));

  return (
    <div className="desk-placeholder">
      <div className="desk-path">
        {words.map((w, i) => (
          <span key={w.id} className="desk-word" data-current={(path.length > 0 && i === path.length - 1) || undefined}>
            {w.word}
          </span>
        ))}
      </div>
      <p className="desk-note">Desk placeholder: the infinite desk arrives with M3 and M4.</p>
    </div>
  );
}

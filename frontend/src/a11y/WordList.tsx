import { useEffect, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { useSession, type SessionStore } from '../store/store.ts';
import type { SessionState } from '../store/session.ts';
import { announcements } from './announce.ts';
import './a11y.css';

/** The words that can be picked right now: the cloud before the first pick, then the current ring. */
function choices(state: SessionState) {
  if (state.nodes.size === 0) return state.cloud;
  if (state.current === null) return [];
  return state.offers.get(state.current) ?? state.streaming.get(state.current) ?? [];
}

/**
 * The desk as a list, for the keyboard and screen readers: the words on offer,
 * and the path so far to go back to. It is visible while focused, and always
 * with the "Word list" setting. Next to it, a live region reads out what
 * happens on the desk (see announce.ts).
 */
export function WordList({ store }: { store: StoreApi<SessionStore> }) {
  const state = useSession(store, (s) => s.state);
  const send = useSession(store, (s) => s.send);
  const offered = choices(state);
  const path = [...state.nodes.values()].sort((a, b) => a.order - b.order);

  // What changed, as sentences, for the live region.
  const [spoken, setSpoken] = useState('');
  const prev = useRef(state);
  useEffect(() => {
    const said = announcements(prev.current, state);
    prev.current = state;
    if (said.length > 0) setSpoken(said.join(' '));
  }, [state]);

  return (
    <>
      <div className="sr-only" aria-live="polite" aria-atomic="true">
        {spoken}
      </div>
      <nav className="word-list material material-strong" aria-label="Word list">
        <h2 className="word-list-heading">{state.nodes.size === 0 ? 'Pick a word to begin' : 'Words on offer'}</h2>
        {state.wrappedUp ? (
          <p className="word-list-empty">This session is wrapped up.</p>
        ) : offered.length === 0 ? (
          <p className="word-list-empty">{state.nodes.size === 0 ? 'Gathering words…' : 'New words are on their way…'}</p>
        ) : (
          <ul className="word-list-words">
            {offered.map((c) => (
              <li key={c.candidateId}>
                <button type="button" onClick={() => send({ type: 'Pick', candidateId: c.candidateId })}>
                  {c.word}
                </button>
              </li>
            ))}
          </ul>
        )}
        {path.length > 1 && !state.wrappedUp && (
          <>
            <h2 className="word-list-heading">Your path</h2>
            <ol className="word-list-path">
              {path.map((n) => (
                <li key={n.id}>
                  {n.id === state.current ? (
                    <span aria-current="step">{n.word}</span>
                  ) : (
                    <button
                      type="button"
                      aria-label={`Go back to ${n.word}`}
                      onClick={() => send({ type: 'Backtrack', node: n.id })}
                    >
                      {n.word}
                    </button>
                  )}
                </li>
              ))}
            </ol>
          </>
        )}
      </nav>
    </>
  );
}

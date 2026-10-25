import { useEffect, useRef, useState, type CSSProperties } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { useSession, type SessionStore } from '../../store/store.ts';
import { icons } from '../icons.tsx';
import './controls.css';

/** Mirrors the backend's rule: one word, no spaces, up to 40 characters. */
const ONE_WORD = /^\S{1,40}$/u;
const DIVERGENCE_SEND_MS = 150;

/**
 * The few things the user can do besides tapping words: set divergence, and
 * type one word (a starting word before the first pick, an inserted word
 * after), and wrap up. There is no other text input anywhere.
 */
interface Props {
  store: StoreApi<SessionStore>;
  /** Called when the user confirms the wrap-up, so the outputs open when they arrive. */
  onWrapUp?: () => void;
  onViewOutputs?: () => void;
}

export function Controls({ store, onWrapUp, onViewOutputs }: Props) {
  const send = useSession(store, (s) => s.send);
  const divergence = useSession(store, (s) => s.state.divergence);
  const started = useSession(store, (s) => s.state.nodes.size > 0);
  const hasCloud = useSession(store, (s) => s.state.cloud.length > 0);
  const rejection = useSession(store, (s) => s.lastRejection);
  const wrappedUp = useSession(store, (s) => s.state.wrappedUp);
  const hasOutputs = useSession(store, (s) => s.state.outputs !== null);

  // Wrapping up ends the exploration, so it takes a second press: the first one asks.
  const [confirming, setConfirming] = useState(false);
  useEffect(() => {
    if (!confirming) return;
    const t = setTimeout(() => setConfirming(false), 4000);
    return () => clearTimeout(t);
  }, [confirming]);
  const wrapUp = () => {
    if (!confirming) {
      setConfirming(true);
      return;
    }
    setConfirming(false);
    send({ type: 'WrapUp' });
    onWrapUp?.();
  };

  // The slider moves locally at once and sends after a short pause.
  const [local, setLocal] = useState(divergence);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => setLocal(divergence), [divergence]);
  useEffect(() => () => clearTimeout(timer.current), []);
  const onSlide = (v: number) => {
    setLocal(v);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => send({ type: 'SetDivergence', divergence: v }), DIVERGENCE_SEND_MS);
  };

  const [word, setWord] = useState('');
  const [invalid, setInvalid] = useState(false);
  const submit = () => {
    const w = word.trim();
    if (!ONE_WORD.test(w)) {
      setInvalid(true);
      setTimeout(() => setInvalid(false), 400);
      return;
    }
    send(started ? { type: 'InsertWord', word: w } : { type: 'StartWithWord', word: w });
    setWord('');
  };

  // Show the latest rejection briefly.
  const [notice, setNotice] = useState<string | null>(null);
  useEffect(() => {
    if (rejection === null) return;
    setNotice(rejection.reason);
    const t = setTimeout(() => setNotice(null), 2500);
    return () => clearTimeout(t);
  }, [rejection]);

  if (!hasCloud) return null;

  if (wrappedUp) {
    return (
      <div className="controls controls-wrapped">
        {hasOutputs ? (
          <button type="button" className="outputs-open" onClick={onViewOutputs}>
            View your outputs
          </button>
        ) : (
          <span className="wrap-status" role="status">
            Wrapped up. Writing your outputs…
          </span>
        )}
      </div>
    );
  }

  return (
    <div className="controls">
      {notice && (
        <p className="notice" role="status">
          {notice}
        </p>
      )}
      <label className="divergence" title="How far new branch words jump from the current word">
        <span className="divergence-end">Close</span>
        <input
          type="range"
          min={0}
          max={1}
          step={0.01}
          value={local}
          onChange={(e) => onSlide(Number(e.target.value))}
          aria-label="Divergence"
          style={{ '--fill': `${local * 100}%` } as CSSProperties}
        />
        <span className="divergence-end">Far</span>
      </label>
      <form
        className="word-input"
        data-invalid={invalid || undefined}
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <input
          value={word}
          onChange={(e) => setWord(e.target.value.replace(/\s/gu, ''))}
          placeholder={started ? 'Add your own word' : 'Or start from a word'}
          aria-label={started ? 'Insert your own word' : 'Start from your own word'}
          maxLength={40}
          enterKeyHint="go"
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
        />
        <button type="submit" disabled={word === ''} aria-label="Add word">
          <icons.plus />
        </button>
      </form>
      {started && (
        <button
          type="button"
          className="wrap-up"
          data-confirming={confirming || undefined}
          onClick={wrapUp}
          aria-label={confirming ? 'Confirm wrap up' : 'Wrap up'}
          title="Finish and produce the decision tree, the draft and the final document"
        >
          {confirming ? 'Wrap up now?' : 'Wrap up'}
        </button>
      )}
    </div>
  );
}

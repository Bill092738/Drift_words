import { useEffect, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { useSession, type SessionStore } from '../../store/store.ts';
import { icons } from '../icons.tsx';
import { diagnosticMessage, rejectionMessage, type ToastMessage } from './messages.ts';
import './feedback.css';

/** How long a toast stays; errors stay longer, since they may need an action. */
const SHOW_MS = { info: 3200, warning: 4500, error: 7000 } as const;
const EXIT_MS = 180;
const MAX_TOASTS = 3;

interface Toast extends ToastMessage {
  id: number;
  leaving: boolean;
}

const TONE_ICON = {
  info: icons.info,
  warning: icons.warning,
  error: icons.error,
} as const;

/**
 * Short messages above the controls: rejected commands and the diagnostics a
 * person can act on, in plain words (see messages.ts). They leave on their
 * own, and errors can be dismissed.
 * Info and warnings are announced politely to screen readers, errors at once.
 */
export function Toaster({ store }: { store: StoreApi<SessionStore> }) {
  const rejection = useSession(store, (s) => s.lastRejection);
  const diagnostics = useSession(store, (s) => s.diagnostics);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);
  const seenDiagnostics = useRef(diagnostics.length);
  const timers = useRef(new Map<number, ReturnType<typeof setTimeout>>());

  const dismiss = (id: number) => {
    clearTimeout(timers.current.get(id));
    setToasts((ts) => ts.map((t) => (t.id === id ? { ...t, leaving: true } : t)));
    timers.current.set(
      id,
      setTimeout(() => {
        timers.current.delete(id);
        setToasts((ts) => ts.filter((t) => t.id !== id));
      }, EXIT_MS),
    );
  };

  const push = (message: ToastMessage | null) => {
    if (message === null) return;
    const id = nextId.current++;
    setToasts((ts) => {
      // The same message twice in a row only refreshes the first.
      const rest = ts.filter((t) => !(t.text === message.text && !t.leaving));
      return [...rest, { ...message, id, leaving: false }].slice(-MAX_TOASTS);
    });
    timers.current.set(
      id,
      setTimeout(() => dismiss(id), SHOW_MS[message.tone]),
    );
  };

  useEffect(() => {
    if (rejection !== null) push(rejectionMessage(rejection.reason));
  }, [rejection]);

  useEffect(() => {
    const fresh = diagnostics.slice(seenDiagnostics.current);
    seenDiagnostics.current = diagnostics.length;
    for (const d of fresh) push(diagnosticMessage(d.level, d.message));
  }, [diagnostics]);

  useEffect(() => {
    const all = timers.current;
    return () => all.forEach((t) => clearTimeout(t));
  }, []);

  return (
    <div className="toaster" aria-live="polite" aria-relevant="additions">
      {toasts.map((t) => {
        const Icon = TONE_ICON[t.tone];
        return (
          <div
            key={t.id}
            className="toast material material-strong"
            data-tone={t.tone}
            data-leaving={t.leaving || undefined}
            role={t.tone === 'error' ? 'alert' : 'status'}
          >
            <Icon size={18} />
            <span className="toast-text">{t.text}</span>
            {t.tone === 'error' && (
              <button type="button" className="icon-button toast-close" aria-label="Dismiss" onClick={() => dismiss(t.id)}>
                <icons.close size={14} />
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}

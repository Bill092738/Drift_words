import { useCallback, useEffect, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { type SessionStore, useSession } from '../../store/store.ts';
import { usePrefersReducedMotion } from '../motion/hooks.ts';
import { OutputsView } from './OutputsView.tsx';

/** Matches --dur-exit in styles.css: how long the dialog takes to leave. */
const EXIT_MS = 180;

interface Props {
  store: StoreApi<SessionStore>;
  sessionId: string | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** True once the user pressed wrap-up in this page: the outputs then open by themselves when they arrive. */
  autoOpen: boolean;
}

/**
 * Shows the outputs view, and opens it when the outputs arrive after a wrap-up
 * the user asked for here. A session that already had its outputs when the page
 * loaded stays closed until the user asks for them. On close the view stays
 * mounted for its exit animation.
 */
export function OutputsHost({ store, sessionId, open, onOpenChange, autoOpen }: Props) {
  const outputs = useSession(store, (s) => s.state.outputs);
  const reduced = usePrefersReducedMotion();
  const hadOutputs = useRef(outputs !== null);
  useEffect(() => {
    if (outputs !== null && !hadOutputs.current && autoOpen) onOpenChange(true);
    hadOutputs.current = outputs !== null;
  }, [outputs, autoOpen, onOpenChange]);

  const [mounted, setMounted] = useState(open);
  useEffect(() => {
    if (open) {
      setMounted(true);
      return;
    }
    const t = setTimeout(() => setMounted(false), reduced ? 0 : EXIT_MS);
    return () => clearTimeout(t);
  }, [open, reduced]);

  // Stable, so the view's focus handling is not restarted by every render.
  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  if (!(open || mounted) || outputs === null) return null;
  return <OutputsView store={store} sessionId={sessionId} onClose={close} closing={!open} />;
}

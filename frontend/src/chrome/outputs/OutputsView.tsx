import { useEffect, useMemo, useRef, useState } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { type SessionStore, useSession } from '../../store/store.ts';
import { buildTreeRows, countRows } from '../../store/tree.ts';
import { DecisionTree } from './DecisionTree.tsx';
import {
  DOC_KINDS,
  DOC_LABELS,
  type DocKind,
  downloadFromServer,
  downloadMarkdown,
  type FileFormat,
  markdownOf,
} from './download.ts';
import { icons } from '../icons.tsx';
import { MarkdownView } from './MarkdownView.tsx';
import './outputs.css';

const FOCUSABLE = 'button:not([disabled]), a[href], summary, [tabindex]:not([tabindex="-1"])';

interface Props {
  store: StoreApi<SessionStore>;
  /** The live session's id, for the server-made downloads; null offline. */
  sessionId: string | null;
  onClose: () => void;
}

const SERVER_FORMATS: { format: Exclude<FileFormat, 'md'>; label: string }[] = [
  { format: 'html', label: 'HTML' },
  { format: 'docx', label: 'Word' },
];

/**
 * The three wrap-up outputs: the decision tree, the draft and the final
 * document, with downloads. Markdown is saved from the text on screen; HTML and
 * Word are made by the backend, so they need a live session.
 */
export function OutputsView({ store, sessionId, onClose }: Props) {
  const outputs = useSession(store, (s) => s.state.outputs);
  const nodes = useSession(store, (s) => s.state.nodes);
  const [tab, setTab] = useState<DocKind>('final');
  const [busy, setBusy] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const dialog = useRef<HTMLDivElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);

  const rows = useMemo(() => buildTreeRows(nodes), [nodes]);

  // Focus moves into the dialog and returns to what opened it; Esc closes; Tab stays inside.
  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButton.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      } else if (e.key === 'Tab' && dialog.current !== null) {
        const items = [...dialog.current.querySelectorAll<HTMLElement>(FOCUSABLE)];
        const first = items[0];
        const last = items[items.length - 1];
        if (first === undefined || last === undefined) return;
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => {
      window.removeEventListener('keydown', onKey, true);
      opener?.focus();
    };
  }, [onClose]);

  if (outputs === null) return null;

  const download = async (format: FileFormat) => {
    setProblem(null);
    if (format === 'md') {
      downloadMarkdown(outputs, tab);
      return;
    }
    if (sessionId === null) return;
    setBusy(format);
    try {
      await downloadFromServer(sessionId, tab, format);
    } catch (e) {
      setProblem(e instanceof Error ? e.message : 'The download failed.');
    } finally {
      setBusy(null);
    }
  };

  return (
    <div
      className="outputs-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="outputs" role="dialog" aria-modal="true" aria-labelledby="outputs-title" ref={dialog}>
        <header className="outputs-head">
          <h2 id="outputs-title">Your outputs</h2>
          <button type="button" className="outputs-close" onClick={onClose} ref={closeButton} aria-label="Close">
            <icons.close />
          </button>
        </header>

        <div className="outputs-tabs" role="tablist" aria-label="Outputs">
          {DOC_KINDS.map((kind) => (
            <button
              key={kind}
              type="button"
              role="tab"
              id={`outputs-tab-${kind}`}
              aria-selected={tab === kind}
              aria-controls="outputs-panel"
              tabIndex={tab === kind ? 0 : -1}
              onClick={() => {
                setTab(kind);
                setProblem(null);
              }}
              onKeyDown={(e) => {
                const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
                if (step === 0) return;
                e.preventDefault();
                const next = DOC_KINDS[(DOC_KINDS.indexOf(kind) + step + DOC_KINDS.length) % DOC_KINDS.length]!;
                setTab(next);
                document.getElementById(`outputs-tab-${next}`)?.focus();
              }}
            >
              {DOC_LABELS[kind]}
            </button>
          ))}
        </div>

        <div className="outputs-body" id="outputs-panel" role="tabpanel" aria-labelledby={`outputs-tab-${tab}`}>
          {tab === 'tree' ? (
            <>
              <p className="muted outputs-hint">
                {countRows(rows)} {countRows(rows) === 1 ? 'word' : 'words'}. Dashed branches were taken after going back.
              </p>
              <DecisionTree rows={rows} />
              <details className="outputs-source">
                <summary>Diagram source (Mermaid)</summary>
                <pre>
                  <code>{outputs.decisionTree}</code>
                </pre>
              </details>
            </>
          ) : (
            <MarkdownView text={markdownOf(outputs, tab)} />
          )}
        </div>

        <footer className="outputs-foot">
          <span className="muted">Download {DOC_LABELS[tab].toLowerCase()}:</span>
          <button type="button" onClick={() => void download('md')}>
            Markdown
          </button>
          {SERVER_FORMATS.map(({ format, label }) => (
            <button
              key={format}
              type="button"
              disabled={sessionId === null || busy !== null}
              title={sessionId === null ? 'Made by the backend: open a live session to use it' : undefined}
              onClick={() => void download(format)}
            >
              {busy === format ? 'Preparing…' : label}
            </button>
          ))}
          {problem !== null && (
            <span className="outputs-problem" role="alert">
              {problem}
            </span>
          )}
        </footer>
      </div>
    </div>
  );
}

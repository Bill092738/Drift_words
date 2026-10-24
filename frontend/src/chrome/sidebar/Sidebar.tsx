import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { springs } from '../../engine/api.ts';
import type { SourceId } from '../../protocol/index.ts';
import { useSession, type SessionStore } from '../../store/store.ts';
import { icons, SourceKindIcon, sourceKindLabel } from '../icons.tsx';
import { useMediaQuery, useSpring } from '../motion/hooks.ts';
import { EntryItem } from './EntryItem.tsx';
import { sidebarModel, type EntryOrder } from './model.ts';
import { formatReference } from './reference.ts';
import { BottomSheet } from './BottomSheet.tsx';
import './sidebar.css';

interface Props {
  store: StoreApi<SessionStore>;
  /** Asks the desk to bring a source object into view. Wired up in M4/M6. */
  onLocateSource?: (id: SourceId) => void;
}

/**
 * The organizing sidebar: entries with priorities and strike-through, the
 * reference list, and a low-emphasis list of sources on the desk. It updates
 * silently and never opens itself; while closed, its tab shows a count of
 * entries the user has not seen yet.
 */
export function Sidebar({ store, onLocateSource }: Props) {
  const state = useSession(store, (s) => s.state);
  const send = useSession(store, (s) => s.send);
  const mobile = useMediaQuery('(max-width: 720px)');
  const [open, setOpen] = useState(false);
  const [order, setOrder] = useState<EntryOrder>('path');
  const model = useMemo(() => sidebarModel(state, order), [state, order]);

  // Entries written after the user last looked at the sidebar.
  const [seenSeq, setSeenSeq] = useState(0);
  const latestWritten = model.entries.reduce((m, e) => Math.max(m, e.writtenSeq), 0);
  useEffect(() => {
    if (open) setSeenSeq(latestWritten);
  }, [open, latestWritten]);
  const unseen = model.entries.filter((e) => e.writtenSeq > seenSeq).length;

  const content = (
    <SidebarContent
      model={model}
      order={order}
      onOrder={setOrder}
      send={send}
      onLocateSource={onLocateSource}
      onClose={mobile ? undefined : () => setOpen(false)}
    />
  );

  return mobile ? (
    <BottomSheet unseen={unseen} entryCount={model.entries.length} onOpenChange={setOpen}>
      {content}
    </BottomSheet>
  ) : (
    <SidePanel open={open} onOpen={() => setOpen(true)} unseen={unseen} entryCount={model.entries.length}>
      {content}
    </SidePanel>
  );
}

/** Desktop: a floating panel that swings in from the right edge, and a tab when closed. */
function SidePanel(props: {
  open: boolean;
  onOpen: () => void;
  unseen: number;
  entryCount: number;
  children: ReactNode;
}) {
  const panel = useRef<HTMLElement>(null);
  const tab = useRef<HTMLButtonElement>(null);

  useSpring(props.open ? 1 : 0, springs.smooth, (p) => {
    const el = panel.current;
    const t = tab.current;
    if (el !== null) {
      // Slides in with a slight tilt and scale, settling flat, like a sheet of paper landing.
      el.style.transform = `translateX(calc(${(1 - p) * 100}% + ${(1 - p) * 32}px)) rotate(${(1 - p) * 3}deg) scale(${0.97 + 0.03 * p})`;
      el.style.opacity = String(Math.min(1, p * 1.6));
      el.style.visibility = p < 0.01 ? 'hidden' : 'visible';
    }
    if (t !== null) {
      t.style.transform = `translateX(${p * 80}px)`;
      t.style.opacity = String(1 - p);
    }
  });

  return (
    <>
      <button
        ref={tab}
        className="sidebar-tab"
        onClick={props.onOpen}
        aria-expanded={props.open}
        aria-controls="sidebar-panel"
        tabIndex={props.open ? -1 : 0}
      >
        <icons.notes />
        <span>Notes</span>
        {props.entryCount > 0 && <span className="tab-count">{props.entryCount}</span>}
        {props.unseen > 0 && <span className="tab-badge" aria-label={`${props.unseen} new`} />}
      </button>
      <aside ref={panel} id="sidebar-panel" className="sidebar-panel" aria-hidden={!props.open} inert={!props.open}>
        {props.children}
      </aside>
    </>
  );
}

function SidebarContent(props: {
  model: ReturnType<typeof sidebarModel>;
  order: EntryOrder;
  onOrder: (o: EntryOrder) => void;
  send: SessionStore['send'];
  onLocateSource: ((id: SourceId) => void) | undefined;
  onClose: (() => void) | undefined;
}) {
  const { model } = props;
  const [highlight, setHighlight] = useState<number | null>(null);
  const [sourcesOpen, setSourcesOpen] = useState(false);
  const refs = useRef(new Map<number, HTMLLIElement>());

  const showReference = (n: number) => {
    refs.current.get(n)?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    setHighlight(n);
    setTimeout(() => setHighlight((h) => (h === n ? null : h)), 1600);
  };

  return (
    <div className="sidebar">
      <header className="sidebar-header">
        <h2>Notes</h2>
        <div className="segmented" role="radiogroup" aria-label="Order entries by">
          {(['path', 'priority'] as const).map((o) => (
            <button key={o} role="radio" aria-checked={props.order === o} onClick={() => props.onOrder(o)}>
              {o === 'path' ? 'Path' : 'Priority'}
            </button>
          ))}
        </div>
        {props.onClose && (
          <button className="icon-button" onClick={props.onClose} aria-label="Close notes" title="Close">
            <icons.chevronRight />
          </button>
        )}
      </header>

      <div className="sidebar-scroll">
        {model.entries.length === 0 ? (
          <p className="empty">Notes appear here as you choose words. Keep exploring.</p>
        ) : (
          <ol className="entries">
            {model.entries.map((e) => (
              <EntryItem key={e.id} entry={e} send={props.send} onCiteClick={showReference} />
            ))}
          </ol>
        )}

        {model.references.length > 0 && (
          <section className="references" aria-labelledby="references-heading">
            <h3 id="references-heading">References</h3>
            <ol>
              {model.references.map(({ number, source }) => (
                <li
                  key={number}
                  ref={(el) => {
                    if (el) refs.current.set(number, el);
                    else refs.current.delete(number);
                  }}
                  data-highlight={highlight === number || undefined}
                >
                  <span className="ref-number">{number}.</span>
                  <span className="ref-text">
                    {formatReference(source).map((seg, i) => (seg.italic ? <i key={i}>{seg.text}</i> : <span key={i}>{seg.text}</span>))}
                  </span>
                </li>
              ))}
            </ol>
          </section>
        )}

        {model.sources.length > 0 && (
          <section className="sources">
            <button className="sources-toggle" aria-expanded={sourcesOpen} onClick={() => setSourcesOpen((o) => !o)}>
              <span>Sources on the desk</span>
              <span className="muted">{model.sources.length}</span>
              <icons.chevronDown />
            </button>
            {sourcesOpen && (
              <ul>
                {model.sources.map(({ source }) => (
                  <li key={source.sourceId}>
                    <button
                      className="source-locate"
                      onClick={() => props.onLocateSource?.(source.sourceId)}
                      title={`${sourceKindLabel[source.kind]}: show on the desk`}
                    >
                      <SourceKindIcon kind={source.kind} />
                      <span className="source-title">{source.title}</span>
                      {source.site && <span className="source-site">{source.site}</span>}
                    </button>
                    <a
                      className="icon-button"
                      href={source.url}
                      target="_blank"
                      rel="noreferrer"
                      aria-label={`Open ${source.title}`}
                      title="Open the original"
                    >
                      <icons.external />
                    </a>
                  </li>
                ))}
              </ul>
            )}
          </section>
        )}
      </div>
    </div>
  );
}

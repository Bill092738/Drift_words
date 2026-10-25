import { useEffect, useRef, useState, type CSSProperties } from 'react';
import type { Command, EntryId } from '../../protocol/index.ts';
import { icons } from '../icons.tsx';
import type { EntryView } from './model.ts';

/** Clicks on "promote" within this window are sent as one multi-level promotion. */
const PROMOTE_BATCH_MS = 450;

interface Props {
  entry: EntryView;
  send: (command: Command) => void;
  onCiteClick: (referenceNumber: number) => void;
}

/** Pending promotion clicks, sent as one `Promote` once the user pauses. */
function useBatchedPromote(id: EntryId, send: (c: Command) => void): [number, () => void] {
  const [pending, setPending] = useState(0);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const count = useRef(0);

  useEffect(() => () => clearTimeout(timer.current), []);

  const click = () => {
    count.current += 1;
    setPending(count.current);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => {
      send({ type: 'Promote', entryId: id, levels: count.current });
      count.current = 0;
      setPending(0);
    }, PROMOTE_BATCH_MS);
  };
  return [pending, click];
}

export function EntryItem({ entry, send, onCiteClick }: Props) {
  const [pending, promote] = useBatchedPromote(entry.id, send);
  const priority = entry.priority + pending;

  return (
    <li
      className="entry"
      data-struck={entry.struck || undefined}
      style={{ '--level': Math.min(priority, 6) } as CSSProperties}
    >
      <div className="entry-path">
        {entry.from !== null && (
          <>
            <span>{entry.from}</span>
            <span className="arrow" aria-label="to">
              →
            </span>
          </>
        )}
        <span className="to">{entry.to}</span>
        {priority > 0 && (
          <span className="level" title={`Priority ${priority}`} data-pending={pending > 0 || undefined}>
            ↑{priority}
          </span>
        )}
      </div>

      <div className="entry-body">
        {entry.showRelation &&
          (entry.struck ? <s className="relation">{entry.relation}</s> : <p className="relation">{entry.relation}</p>)}
        {entry.explanation.trim() !== '' ? (
          <p className="explanation">
            {entry.explanation}
            {entry.cites.map((n) => (
              <button key={n} className="cite" onClick={() => onCiteClick(n)} aria-label={`Reference ${n}`}>
                {n}
              </button>
            ))}
          </p>
        ) : (
          // Without text, bare numbers read as noise: name the source instead.
          entry.cites.length > 0 && (
            <p className="cite-chips">
              {entry.cites.map((n, i) => (
                <button key={n} className="cite-chip" onClick={() => onCiteClick(n)} aria-label={`Reference ${n}`}>
                  <span className="cite-number">{n}</span>
                  {entry.citeLabels[i]}
                </button>
              ))}
            </p>
          )
        )}
      </div>

      <div className="entry-actions">
        {entry.struck ? (
          <button
            className="icon-button"
            onClick={() => send({ type: 'Restore', entryId: entry.id })}
            title="Restore"
            aria-label="Restore entry"
          >
            <icons.restore />
          </button>
        ) : (
          <>
            <button className="icon-button" onClick={promote} title="Promote (click again for more levels)" aria-label="Promote entry">
              <icons.promote />
            </button>
            <button
              className="icon-button"
              onClick={() => send({ type: 'Strike', entryId: entry.id })}
              title="Strike through"
              aria-label="Strike through entry"
            >
              <icons.strike />
            </button>
          </>
        )}
      </div>
    </li>
  );
}

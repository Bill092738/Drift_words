import type { Origin } from '../../protocol/index.ts';
import type { TreeRow } from '../../store/tree.ts';
import { icons } from '../icons.tsx';

const ORIGIN_NOTE: Partial<Record<Origin, string>> = {
  startWord: 'typed to start',
  insert: 'your own word',
};

function Row({ row, depth }: { row: TreeRow; depth: number }) {
  const label = (
    <>
      <span className="tree-word">{row.word}</span>
      {ORIGIN_NOTE[row.origin] !== undefined && <span className="tree-note">{ORIGIN_NOTE[row.origin]}</span>}
      {row.afterBacktrack && <span className="tree-note">after going back</span>}
    </>
  );
  if (row.children.length === 0) {
    return (
      <li data-back={row.afterBacktrack || undefined}>
        <div className="tree-leaf">{label}</div>
      </li>
    );
  }
  return (
    <li data-back={row.afterBacktrack || undefined}>
      <details open={depth < 6}>
        <summary>
          <span className="tree-fold">
            <icons.chevronRight size={12} />
          </span>
          {label}
        </summary>
        <ul>
          {row.children.map((child) => (
            <Row key={child.id} row={child} depth={depth + 1} />
          ))}
        </ul>
      </details>
    </li>
  );
}

/**
 * How the user got here, word by word. A word's later branches are drawn
 * dashed: they were taken after going back. Branches fold with the keyboard
 * or the pointer.
 */
export function DecisionTree({ rows }: { rows: readonly TreeRow[] }) {
  if (rows.length === 0) return <p className="muted">No words were chosen.</p>;
  return (
    <ul className="decision-tree" aria-label="Decision tree">
      {rows.map((row) => (
        <Row key={row.id} row={row} depth={0} />
      ))}
    </ul>
  );
}

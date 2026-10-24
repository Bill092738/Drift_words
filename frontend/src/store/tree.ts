import type { NodeId, Origin } from '../protocol/index.ts';
import type { NodeState } from './session.ts';

/** One word of the walk, with the words chosen from it. */
export interface TreeRow {
  id: NodeId;
  word: string;
  origin: Origin;
  /**
   * True for a branch taken after the user went back: a word's second and later
   * children, since the first is the one that was chosen on the way forward.
   */
  afterBacktrack: boolean;
  children: TreeRow[];
}

/**
 * The decision tree as nested rows, built from the session's nodes: roots in
 * the order they were chosen, and every word's children in the order they were
 * chosen. The backend's Mermaid source says the same; this is what the
 * outputs view draws and lets the user fold.
 */
export function buildTreeRows(nodes: ReadonlyMap<NodeId, NodeState>): TreeRow[] {
  const byParent = new Map<NodeId | null, NodeState[]>();
  for (const node of nodes.values()) {
    // A parent that is not in the map is treated as a root, so a partial log still draws.
    const parent = node.parent !== null && nodes.has(node.parent) ? node.parent : null;
    byParent.set(parent, [...(byParent.get(parent) ?? []), node]);
  }
  const rowsOf = (parent: NodeId | null): TreeRow[] =>
    (byParent.get(parent) ?? [])
      .sort((a, b) => a.order - b.order)
      .map((node, index) => ({
        id: node.id,
        word: node.word,
        origin: node.origin,
        afterBacktrack: parent !== null && index > 0,
        children: rowsOf(node.id),
      }));
  return rowsOf(null);
}

/** How many words a row stands for, itself included. */
export function countRows(rows: readonly TreeRow[]): number {
  return rows.reduce((n, row) => n + 1 + countRows(row.children), 0);
}

import { describe, expect, it } from 'vitest';
import type { NodeId, Origin } from '../../protocol/index.ts';
import type { NodeState } from '../../store/session.ts';
import { exportUrl, fileName, markdownOf } from './download.ts';
import { buildTreeRows, countRows } from '../../store/tree.ts';

function node(id: number, parent: number | null, word: string, order: number, origin: Origin = 'branch'): NodeState {
  return { id, parent, word, origin, fromCandidate: null, order, revisited: false, placement: null };
}

const nodes = (...ns: NodeState[]): ReadonlyMap<NodeId, NodeState> => new Map(ns.map((n) => [n.id, n]));

describe('buildTreeRows', () => {
  it('nests children under their parents in the order they were chosen', () => {
    // The shape of exploration.jsonl: 1 > 2 > 3 > 4, then back to 2 and 5 > 6.
    const rows = buildTreeRows(
      nodes(
        node(1, null, 'entropy', 0, 'cloud'),
        node(2, 1, 'information', 1),
        node(3, 2, 'noise', 2),
        node(4, 3, 'creativity', 3),
        node(5, 2, 'attention', 4),
        node(6, 5, 'flow', 5, 'insert'),
      ),
    );
    expect(rows).toHaveLength(1);
    const information = rows[0]!.children[0]!;
    expect(information.word).toBe('information');
    expect(information.children.map((c) => c.word)).toEqual(['noise', 'attention']);
    expect(information.children.map((c) => c.afterBacktrack)).toEqual([false, true]);
    expect(information.children[1]!.children[0]).toMatchObject({ word: 'flow', origin: 'insert', afterBacktrack: false });
    expect(countRows(rows)).toBe(6);
  });

  it('is empty for no nodes and treats an unknown parent as a root', () => {
    expect(buildTreeRows(new Map())).toEqual([]);
    const rows = buildTreeRows(nodes(node(2, 99, 'orphan', 0)));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ word: 'orphan', afterBacktrack: false });
  });

  it('orders by choice, whatever order the map holds them in', () => {
    const rows = buildTreeRows(nodes(node(3, 1, 'later', 2), node(1, null, 'root', 0), node(2, 1, 'sooner', 1)));
    expect(rows[0]!.children.map((c) => c.word)).toEqual(['sooner', 'later']);
  });
});

describe('downloads', () => {
  const outputs = { decisionTree: 'tree', draft: 'draft', final: 'final' };

  it('names files like the backend does', () => {
    expect(fileName('tree', 'md')).toBe('decision-tree.md');
    expect(fileName('draft', 'html')).toBe('draft.html');
    expect(fileName('final', 'docx')).toBe('final.docx');
  });

  it('builds the export route and escapes the session id', () => {
    expect(exportUrl('session-1-2', 'final', 'docx')).toBe('/api/sessions/session-1-2/export/final/docx');
    expect(exportUrl('a/b?c', 'draft', 'md')).toBe('/api/sessions/a%2Fb%3Fc/export/draft/md');
  });

  it('picks the Markdown of each output', () => {
    expect(markdownOf(outputs, 'tree')).toBe('tree');
    expect(markdownOf(outputs, 'draft')).toBe('draft');
    expect(markdownOf(outputs, 'final')).toBe('final');
  });
});

// Derives what the sidebar shows from the session state.
import type { EntryId, Source, SourceId } from '../../protocol/index.ts';
import type { SessionState, SourceState } from '../../store/session.ts';

export interface EntryView {
  id: EntryId;
  /** The previous word on the path, or null for an entry on the root. */
  from: string | null;
  to: string;
  relation: string;
  explanation: string;
  priority: number;
  struck: boolean;
  /** Reference numbers, in the order the entry cites them. */
  cites: number[];
  writtenSeq: number;
}

export interface ReferenceView {
  number: number;
  source: Source;
}

export interface SidebarModel {
  entries: EntryView[];
  /** Every source cited by any entry, struck ones included, numbered by first citation. */
  references: ReferenceView[];
  /** Every source on the desk, in the order they arrived. */
  sources: SourceState[];
}

export type EntryOrder = 'path' | 'priority';

export function sidebarModel(s: SessionState, order: EntryOrder): SidebarModel {
  const written = [...s.entries.values()].sort((a, b) => a.writtenSeq - b.writtenSeq);

  const numbers = new Map<SourceId, number>();
  for (const { entry } of written) {
    for (const id of entry.cites) {
      if (!numbers.has(id) && s.sources.has(id)) numbers.set(id, numbers.size + 1);
    }
  }

  const entries = written.map(({ entry, priority, struck, writtenSeq }): EntryView => {
    const node = s.nodes.get(entry.node);
    const parent = node?.parent == null ? undefined : s.nodes.get(node.parent);
    return {
      id: entry.entryId,
      from: parent?.word ?? null,
      to: node?.word ?? '?',
      relation: entry.relation,
      explanation: entry.explanation,
      priority,
      struck,
      cites: entry.cites.flatMap((id) => numbers.get(id) ?? []),
      writtenSeq,
    };
  });

  if (order === 'priority') {
    entries.sort(
      (a, b) => Number(a.struck) - Number(b.struck) || b.priority - a.priority || a.writtenSeq - b.writtenSeq,
    );
  }

  const references = [...numbers].flatMap(([id, number]) => {
    const source = s.sources.get(id)?.source;
    return source === undefined ? [] : [{ number, source }];
  });

  const sources = [...s.sources.values()].sort((a, b) => a.source.sourceId - b.source.sourceId);

  return { entries, references, sources };
}

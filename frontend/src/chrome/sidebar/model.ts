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
  /** A short label for each cited source (its site, else its kind), aligned with {@link cites}. */
  citeLabels: string[];
  /** False when the relation only repeats the "from → to" header, as template notes do. */
  showRelation: boolean;
  writtenSeq: number;
}

const kindLabels: Record<Source['kind'], string> = {
  article: 'Article',
  paper: 'Paper',
  pdf: 'PDF',
  webPage: 'Web page',
  image: 'Image',
  audio: 'Audio',
};

/** The header line as the sidebar shows it, for comparing with a relation. */
export function pathLabel(from: string | null, to: string): string {
  return from === null ? to : `${from} \u2192 ${to}`;
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
    const from = parent?.word ?? null;
    const to = node?.word ?? '?';
    const cited = entry.cites.filter((id) => numbers.has(id));
    return {
      id: entry.entryId,
      from,
      to,
      relation: entry.relation,
      showRelation: entry.relation.trim() !== '' && entry.relation.trim() !== pathLabel(from, to),
      citeLabels: cited.map((id) => {
        const source = s.sources.get(id)?.source;
        return source === undefined ? '' : (source.site ?? kindLabels[source.kind]);
      }),
      explanation: entry.explanation,
      priority,
      struck,
      cites: cited.map((id) => numbers.get(id) ?? 0),
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

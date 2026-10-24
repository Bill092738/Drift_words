// Stand-in wrap-up outputs for the offline mock, so the outputs view can be
// built and shown without the backend. The real ones come from drift-server
// (backend `Drift.Output.*`): APA references rendered by citeproc and a final
// document written by a model. These only look like them, and say so.
import type { Outputs, Source, SourceId } from '../protocol/index.ts';
import type { EntryState, SessionState } from '../store/session.ts';
import { buildTreeRows, type TreeRow } from '../store/tree.ts';

const plainWord = /^[\p{L}\p{N}\-_' ]+$/u;

/** A label Mermaid cannot misread; anything unusual is quoted. */
function mermaidLabel(word: string): string {
  if (word !== '' && plainWord.test(word) && word.trim().toLowerCase() !== 'end') return word;
  return `"${word.trim().replaceAll('"', '#quot;').replaceAll('\n', ' ')}"`;
}

function mermaid(rows: readonly TreeRow[]): string {
  const lines: string[] = ['flowchart TD'];
  const declared = new Set<number>();
  const name = (row: TreeRow): string => {
    if (declared.has(row.id)) return `n${row.id}`;
    declared.add(row.id);
    return `n${row.id}[${mermaidLabel(row.word)}]`;
  };
  const walk = (row: TreeRow) => {
    for (const child of row.children) {
      lines.push(`  ${name(row)}${child.afterBacktrack ? ' -. revisited .-> ' : ' --> '}${name(child)}`);
      walk(child);
    }
  };
  for (const root of rows) {
    if (root.children.length === 0) lines.push(`  ${name(root)}`);
    walk(root);
  }
  return lines.join('\n');
}

const escapeMd = (s: string): string => s.replace(/[\\`*_[\]<>~|]/gu, (c) => `\\${c}`).replace(/\s+/gu, ' ').trim();

function sentence(s: string): string {
  const t = s.trim();
  return /[.!?]$/u.test(t) ? t : `${t}.`;
}

function ordered(entries: SessionState['entries']): EntryState[] {
  return [...entries.values()].sort((a, b) => a.writtenSeq - b.writtenSeq);
}

function title(state: SessionState): string {
  const words = [...state.nodes.values()].sort((a, b) => a.order - b.order).map((n) => escapeMd(n.word));
  const first = words[0];
  const last = words[words.length - 1];
  if (first === undefined || last === undefined) return '';
  return words.length === 1 ? first : `from ${first} to ${last}`;
}

function references(cited: Iterable<SourceId>, sources: SessionState['sources']): string[] {
  const out: string[] = [];
  for (const id of new Set(cited)) {
    const source: Source | undefined = sources.get(id)?.source;
    if (source === undefined) continue;
    const site = source.site === null ? '' : ` ${escapeMd(source.site)}.`;
    out.push(`${escapeMd(source.title)}.${site} <${source.url}>`);
  }
  return out;
}

export function mockOutputs(state: SessionState): Outputs {
  const entries = ordered(state.entries);
  const heading = title(state);

  const draftLines = entries.map((e, i) => {
    const text = `**${sentence(escapeMd(e.entry.relation))}** ${escapeMd(e.entry.explanation)}`.trim();
    return `${i + 1}. ${e.struck ? `~~${text}~~` : text}`;
  });
  const draftRefs = references(
    entries.flatMap((e) => e.entry.cites),
    state.sources,
  );
  const draft = [
    heading === '' ? '# Draft' : `# Draft: ${heading}`,
    entries.length === 0 ? '_No entries yet._' : draftLines.join('\n'),
    ...(draftRefs.length > 0 ? ['## References', draftRefs.join('\n\n')] : []),
    '_Offline mock: references are listed, not formatted._',
  ].join('\n\n');

  const kept = entries.filter((e) => !e.struck && e.priority >= 1);
  const finalRefs = references(
    kept.flatMap((e) => e.entry.cites),
    state.sources,
  );
  const final = [
    heading === '' ? '# Final' : `# ${heading.charAt(0).toUpperCase()}${heading.slice(1)}`,
    kept.length === 0
      ? '_No entries were kept at high priority._'
      : kept.map((e) => `${sentence(escapeMd(e.entry.relation))} ${escapeMd(e.entry.explanation)}`.trim()).join(' '),
    ...(finalRefs.length > 0 ? ['## References', finalRefs.join('\n\n')] : []),
    '_Offline mock: the real final document is written by a model._',
  ].join('\n\n');

  return { decisionTree: `\`\`\`mermaid\n${mermaid(buildTreeRows(state.nodes))}\n\`\`\``, draft, final };
}

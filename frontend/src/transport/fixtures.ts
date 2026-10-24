import { parseEventLog, type Stamped } from '../protocol/index.ts';

const raw = import.meta.glob<string>('../../../protocol/fixtures/*.jsonl', {
  query: '?raw',
  import: 'default',
  eager: true,
});

/** Fixture name (file name without extension) to its parsed event log. */
export const fixtures: ReadonlyMap<string, Stamped[]> = new Map(
  Object.entries(raw)
    .map(([path, text]) => [path.replace(/^.*\/|\.jsonl$/g, ''), parseEventLog(text)] as const)
    .sort(([a], [b]) => a.localeCompare(b)),
);

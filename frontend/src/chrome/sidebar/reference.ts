// A lightweight APA-style formatter for CSL-JSON, used to preview references
// in the sidebar while exploring. The authoritative reference lists in the
// draft and final outputs are rendered by citeproc on the backend (M8).
import type { Source } from '../../protocol/index.ts';

/** A run of reference text; italic runs are rendered in <i>. */
export interface Segment {
  text: string;
  italic?: boolean;
}

interface CslName {
  family?: string;
  given?: string;
  literal?: string;
}

type Csl = Record<string, unknown>;

function str(csl: Csl, key: string): string | undefined {
  const v = csl[key];
  return typeof v === 'string' && v.trim() !== '' ? v.trim() : typeof v === 'number' ? String(v) : undefined;
}

function initials(given: string): string {
  return given
    .split(/[\s.]+/)
    .filter((part) => part !== '')
    .map((part) =>
      part
        .split('-')
        .map((p) => `${p.charAt(0).toUpperCase()}.`)
        .join('-'),
    )
    .join(' ');
}

function formatName(n: CslName): string | undefined {
  if (n.literal) return n.literal;
  if (!n.family) return undefined;
  return n.given ? `${n.family}, ${initials(n.given)}` : n.family;
}

/** APA author list: "A", "A, & B", "A, B, & C"; 21+ authors: first 19, ..., last. */
export function formatAuthors(names: readonly CslName[]): string | undefined {
  const all = names.flatMap((n) => formatName(n) ?? []);
  if (all.length === 0) return undefined;
  if (all.length === 1) return all[0];
  if (all.length > 20) return `${all.slice(0, 19).join(', ')}, . . . ${all[all.length - 1]}`;
  return `${all.slice(0, -1).join(', ')}, & ${all[all.length - 1]}`;
}

function year(csl: Csl): string {
  const issued = csl['issued'] as { 'date-parts'?: unknown[][] } | undefined;
  const y = issued?.['date-parts']?.[0]?.[0];
  return typeof y === 'number' || typeof y === 'string' ? String(y) : 'n.d.';
}

function endWithPeriod(s: string): string {
  return /[.?!]$/.test(s) ? s : `${s}.`;
}

/** Formats a source as an APA-style reference, falling back to its title and URL. */
export function formatReference(source: Source): Segment[] {
  const csl: Csl = typeof source.csl === 'object' && source.csl !== null ? (source.csl as Csl) : {};
  const title = str(csl, 'title') ?? source.title;
  const authors = formatAuthors(Array.isArray(csl['author']) ? (csl['author'] as CslName[]) : []);
  const container = str(csl, 'container-title') ?? source.site ?? undefined;
  const doi = str(csl, 'DOI');
  const link = doi ? `https://doi.org/${doi}` : (str(csl, 'URL') ?? source.url);
  const date = `(${year(csl)}).`;

  const out: Segment[] = [];
  const text = (t: string) => out.push({ text: t });
  const italic = (t: string) => out.push({ text: t, italic: true });

  switch (str(csl, 'type')) {
    case 'article-journal': {
      text(authors ? `${authors} ${date} ${endWithPeriod(title)} ` : `${endWithPeriod(title)} ${date} `);
      if (container) {
        italic(container);
        const volume = str(csl, 'volume');
        const issue = str(csl, 'issue');
        const page = str(csl, 'page')?.replace('-', '–');
        if (volume) {
          text(', ');
          italic(volume);
        }
        if (issue) text(`(${issue})`);
        text(page ? `, ${page}. ` : '. ');
      }
      break;
    }
    case 'entry-encyclopedia':
      text(`${endWithPeriod(title)} ${date} `);
      if (container) {
        text('In ');
        italic(container);
        text('. ');
      }
      break;
    default: {
      // Reports, preprints, web pages, media: Author (Year). *Title* [number]. Publisher.
      if (authors) text(`${authors} ${date} `);
      italic(title);
      const number = str(csl, 'number');
      text(number ? ` (${number}). ` : authors ? '. ' : `. ${date} `);
      const publisher = str(csl, 'publisher') ?? container;
      if (publisher && publisher !== title) text(`${endWithPeriod(publisher)} `);
    }
  }
  text(link);
  return out;
}

export function referenceText(source: Source): string {
  return formatReference(source)
    .map((s) => s.text)
    .join('');
}

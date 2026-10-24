// A reader for the small Markdown subset the backend writes the outputs in:
// headings, paragraphs, numbered lines, bold, italic, strike-through, links in
// angle brackets and a fenced code block. It produces a tree, and the view turns
// that into React elements, so nothing in a document can become markup: text is
// always text, and only http and https links are kept.
//
// It mirrors `Drift.Output.Export` on the backend, which writes HTML and DOCX
// from the same subset.

export type Inline =
  | { type: 'text'; text: string }
  | { type: 'bold' | 'italic' | 'strike'; children: Inline[] }
  | { type: 'link'; url: string };

export type Block =
  | { type: 'heading'; level: 1 | 2 | 3; children: Inline[] }
  | { type: 'paragraph'; children: Inline[] }
  | { type: 'code'; text: string };

const isBlank = (line: string): boolean => line.trim() === '';
const isFence = (line: string): boolean => line.startsWith('```');
const isNumbered = (line: string): boolean => /^\d+\. /u.test(line);

function headingOf(line: string): { level: 1 | 2 | 3; text: string } | null {
  const m = /^(#{1,3}) (.*)$/u.exec(line);
  return m === null ? null : { level: m[1]!.length as 1 | 2 | 3, text: m[2]!.trim() };
}

export function parseMarkdown(text: string): Block[] {
  const lines = text.split(/\r?\n/u);
  const blocks: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i]!;
    if (isFence(line)) {
      const code: string[] = [];
      i++;
      while (i < lines.length && !isFence(lines[i]!)) code.push(lines[i++]!);
      i++; // the closing fence, if there is one
      blocks.push({ type: 'code', text: code.join('\n') });
    } else if (isBlank(line)) {
      i++;
    } else {
      // A chunk runs to the next blank line or fence. Headings and numbered
      // lines stand alone; other lines of a chunk join into one paragraph.
      const chunk: string[] = [];
      while (i < lines.length && !isBlank(lines[i]!) && !isFence(lines[i]!)) chunk.push(lines[i++]!);
      let plain: string[] = [];
      const flush = () => {
        if (plain.length > 0) {
          blocks.push({ type: 'paragraph', children: parseInlines(plain.map((l) => l.trim()).join(' ')) });
          plain = [];
        }
      };
      for (const l of chunk) {
        const h = headingOf(l);
        if (h !== null) {
          flush();
          blocks.push({ type: 'heading', level: h.level, children: parseInlines(h.text) });
        } else if (isNumbered(l)) {
          flush();
          blocks.push({ type: 'paragraph', children: parseInlines(l.trim()) });
        } else {
          plain.push(l);
        }
      }
      flush();
    }
  }
  return blocks;
}

/** Only web links: the text of a document came from a model or the network. */
export function isWebUrl(url: string): boolean {
  return /^https?:\/\//iu.test(url) && !/[\s"<>]/u.test(url);
}

/** The text up to the next unescaped marker, and what follows it, if the run is tight. */
function closing(marker: string, text: string): { inner: string; after: string } | null {
  let i = 0;
  while (i < text.length) {
    if (text[i] === '\\' && i + 1 < text.length) {
      i += 2;
    } else if (text.startsWith(marker, i)) {
      const inner = text.slice(0, i);
      // As in CommonMark, an emphasis run does not start or end with a space.
      if (inner === '' || /^\s/u.test(inner) || /\s$/u.test(inner)) return null;
      return { inner, after: text.slice(i + marker.length) };
    } else {
      i++;
    }
  }
  return null;
}

const SPECIAL = /[\\*_~<]/u;

export function parseInlines(text: string): Inline[] {
  const out: Inline[] = [];
  const push = (t: string) => {
    const last = out[out.length - 1];
    if (last?.type === 'text') last.text += t;
    else out.push({ type: 'text', text: t });
  };
  let rest = text;
  while (rest !== '') {
    if (rest[0] === '\\' && rest.length > 1) {
      push(rest[1]!);
      rest = rest.slice(2);
      continue;
    }
    const pairs: [string, 'bold' | 'italic' | 'strike'][] = [
      ['**', 'bold'],
      ['~~', 'strike'],
      ['*', 'italic'],
      ['_', 'italic'],
    ];
    const matched = pairs.find(([marker]) => rest.startsWith(marker) && closing(marker, rest.slice(marker.length)) !== null);
    if (matched !== undefined) {
      const [marker, type] = matched;
      const { inner, after } = closing(marker, rest.slice(marker.length))!;
      out.push({ type, children: parseInlines(inner) });
      rest = after;
      continue;
    }
    if (rest[0] === '<') {
      const end = rest.indexOf('>');
      const url = end > 0 ? rest.slice(1, end) : '';
      if (end > 0 && isWebUrl(url)) {
        out.push({ type: 'link', url });
        rest = rest.slice(end + 1);
        continue;
      }
    }
    // Plain text up to the next special character, or the special character itself.
    const next = rest.slice(1).search(SPECIAL);
    const stop = next === -1 ? rest.length : next + 1;
    push(rest.slice(0, stop));
    rest = rest.slice(stop);
  }
  return out;
}

/** The text of inline content, without any formatting. */
export function plainText(inlines: readonly Inline[]): string {
  return inlines
    .map((x) => (x.type === 'text' ? x.text : x.type === 'link' ? x.url : plainText(x.children)))
    .join('');
}

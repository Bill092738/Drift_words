import { describe, expect, it } from 'vitest';
import { isWebUrl, parseInlines, parseMarkdown, plainText } from './markdown.ts';

const draft = [
  '# Draft: from entropy to flow',
  '',
  '1. **Entropy measures information.** Shannon borrowed the word (Shannon, 1948).',
  '2. ~~**Noise as a source.** A struck thought.~~',
  '',
  '## References',
  '',
  'Shannon, C. E. (1948). *Bell System Technical Journal*, *27*(3), 379–423. <https://doi.org/10.1002/j.1538-7305.1948.tb01338.x>',
].join('\n');

describe('parseMarkdown', () => {
  it('reads headings, numbered lines, paragraphs and a code block', () => {
    const blocks = parseMarkdown(draft + '\n\n```mermaid\nflowchart TD\n  n1[a] --> n2[b]\n```');
    expect(blocks.filter((b) => b.type === 'heading').map((b) => (b.type === 'heading' ? b.level : 0))).toEqual([1, 2]);
    expect(blocks.filter((b) => b.type === 'paragraph')).toHaveLength(3);
    expect(blocks.filter((b) => b.type === 'code')).toEqual([{ type: 'code', text: 'flowchart TD\n  n1[a] --> n2[b]' }]);
  });

  it('keeps each numbered line as its own paragraph and joins wrapped lines', () => {
    expect(parseMarkdown('1. one\n2. two\n3. three')).toHaveLength(3);
    expect(parseMarkdown('one\ntwo\n\nthree')).toEqual([
      { type: 'paragraph', children: [{ type: 'text', text: 'one two' }] },
      { type: 'paragraph', children: [{ type: 'text', text: 'three' }] },
    ]);
  });

  it('handles CRLF line endings and an unclosed fence', () => {
    expect(parseMarkdown('# A\r\n\r\ntext')).toHaveLength(2);
    expect(parseMarkdown('```\ncode')).toEqual([{ type: 'code', text: 'code' }]);
  });

  it('returns nothing for empty text', () => {
    expect(parseMarkdown('')).toEqual([]);
    expect(parseMarkdown('\n\n  \n')).toEqual([]);
  });
});

describe('parseInlines', () => {
  it('reads bold, italic, strike-through, escapes and links', () => {
    expect(parseInlines('a **b** *c* _d_ ~~e~~ \\*f\\* <https://x.org/a_b>')).toEqual([
      { type: 'text', text: 'a ' },
      { type: 'bold', children: [{ type: 'text', text: 'b' }] },
      { type: 'text', text: ' ' },
      { type: 'italic', children: [{ type: 'text', text: 'c' }] },
      { type: 'text', text: ' ' },
      { type: 'italic', children: [{ type: 'text', text: 'd' }] },
      { type: 'text', text: ' ' },
      { type: 'strike', children: [{ type: 'text', text: 'e' }] },
      { type: 'text', text: ' *f* ' },
      { type: 'link', url: 'https://x.org/a_b' },
    ]);
  });

  it('leaves unmatched markers and loose asterisks as text', () => {
    expect(plainText(parseInlines('5 * 3 and **open'))).toBe('5 * 3 and **open');
    expect(parseInlines('2 * 3 * 4')).toEqual([{ type: 'text', text: '2 * 3 * 4' }]);
  });

  it('never makes a link of an address that is not http or https', () => {
    for (const bad of ['<javascript:alert(1)>', '<file:///etc/passwd>', '<data:text/html,x>', '<https://a b>']) {
      expect(parseInlines(bad).some((x) => x.type === 'link')).toBe(false);
    }
    expect(isWebUrl('http://example.org')).toBe(true);
    expect(isWebUrl('HTTPS://example.org/x')).toBe(true);
    expect(isWebUrl('ftp://example.org')).toBe(false);
  });

  it('keeps markup-looking text as plain text: React renders it escaped', () => {
    const inlines = parseInlines('<script>alert(1)</script> <img src=x onerror=alert(1)> & more');
    expect(inlines.every((x) => x.type === 'text')).toBe(true);
    expect(plainText(inlines)).toBe('<script>alert(1)</script> <img src=x onerror=alert(1)> & more');
  });

  it('terminates on every input', () => {
    for (const s of ['*', '**', '~~', '_', '\\', '<', '<>', '<https://', '***a***', '__a__', '*a**b*', '\\\\\\', '**a* b**']) {
      expect(() => parseInlines(s)).not.toThrow();
    }
  });
});

describe('plainText', () => {
  it('drops formatting and keeps link addresses', () => {
    expect(plainText(parseInlines('**Bold** and *it* <https://x.org>'))).toBe('Bold and it https://x.org');
  });
});

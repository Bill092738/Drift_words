import { describe, expect, it } from 'vitest';
import type { Source } from '../../protocol/index.ts';
import { formatAuthors, formatReference, referenceText } from './reference.ts';

const base: Source = {
  sourceId: 1,
  node: 2,
  kind: 'paper',
  title: 'Fallback title',
  site: null,
  url: 'https://example.org/x',
  thumbnailUrl: null,
  csl: null,
};

describe('formatAuthors', () => {
  it('follows APA joining rules', () => {
    expect(formatAuthors([{ family: 'Shannon', given: 'Claude Elwood' }])).toBe('Shannon, C. E.');
    expect(formatAuthors([{ family: 'A', given: 'Bo' }, { family: 'C', given: 'Di' }])).toBe('A, B., & C, D.');
    expect(formatAuthors([{ family: 'A' }, { family: 'B' }, { family: 'C' }])).toBe('A, B, & C');
    expect(formatAuthors([{ literal: 'LIGO Collaboration' }])).toBe('LIGO Collaboration');
    expect(formatAuthors([{ family: 'Smith', given: 'Jean-Paul' }])).toBe('Smith, J.-P.');
    expect(formatAuthors([])).toBeUndefined();
  });
});

describe('formatReference', () => {
  it('formats a journal article with italic container and volume, and a DOI link', () => {
    const segs = formatReference({
      ...base,
      csl: {
        type: 'article-journal',
        title: 'A Mathematical Theory of Communication',
        author: [{ family: 'Shannon', given: 'C. E.' }],
        'container-title': 'Bell System Technical Journal',
        volume: '27',
        issue: '3',
        page: '379-423',
        issued: { 'date-parts': [[1948]] },
        DOI: '10.1002/j.1538-7305.1948.tb01338.x',
      },
    });
    expect(segs.map((s) => s.text).join('')).toBe(
      'Shannon, C. E. (1948). A Mathematical Theory of Communication. Bell System Technical Journal, 27(3), 379–423. https://doi.org/10.1002/j.1538-7305.1948.tb01338.x',
    );
    expect(segs.filter((s) => s.italic).map((s) => s.text)).toEqual(['Bell System Technical Journal', '27']);
  });

  it('formats an encyclopedia entry without a date as n.d.', () => {
    expect(
      referenceText({
        ...base,
        csl: { type: 'entry-encyclopedia', title: 'Tide', 'container-title': 'Wikipedia', URL: 'https://en.wikipedia.org/wiki/Tide' },
      }),
    ).toBe('Tide. (n.d.). In Wikipedia. https://en.wikipedia.org/wiki/Tide');
  });

  it('formats a preprint with its number and publisher', () => {
    expect(
      referenceText({
        ...base,
        csl: {
          type: 'article',
          title: 'Attention Is All You Need',
          author: [{ family: 'Vaswani', given: 'Ashish' }],
          issued: { 'date-parts': [[2017]] },
          number: 'arXiv:1706.03762',
          publisher: 'arXiv',
          URL: 'https://arxiv.org/abs/1706.03762',
        },
      }),
    ).toBe('Vaswani, A. (2017). Attention Is All You Need (arXiv:1706.03762). arXiv. https://arxiv.org/abs/1706.03762');
  });

  it('falls back to the source title and URL without CSL', () => {
    expect(referenceText(base)).toBe('Fallback title. (n.d.). https://example.org/x');
  });
});

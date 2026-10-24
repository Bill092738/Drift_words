// Writes the protocol fixtures in ../protocol/fixtures from typed scripts.
// Run with: pnpm fixtures
//
// The builders below are typed against the generated protocol, so a fixture
// that does not match the contract fails to compile; the backend test suite
// then decodes every line against the Haskell types as a second check.
import { mkdirSync, writeFileSync } from 'node:fs';
import type {
  Candidate,
  Event,
  Lang,
  NodeId,
  Origin,
  Source,
  SourceId,
  SourceKind,
  Stamped,
} from '../src/protocol/generated.ts';

const outDir = new URL('../../protocol/fixtures/', import.meta.url);

class Script {
  readonly out: Stamped[] = [];
  private t: number;
  private nextNode = 1;
  private nextCandidate = 1;
  private nextSource = 1;
  private nextEntry = 1;
  private readonly offered = new Map<NodeId | 'cloud', Candidate[]>();

  constructor(startMs: number) {
    this.t = startMs;
  }

  wait(ms: number): this {
    this.t += ms;
    return this;
  }

  emit(event: Event): void {
    this.out.push({ seq: this.out.length + 1, atMs: this.t, event });
  }

  private candidates(words: string[]): Candidate[] {
    return words.map((word) => ({ candidateId: this.nextCandidate++, word }));
  }

  cloud(lang: Lang, words: string[]): void {
    const candidates = this.candidates(words);
    this.offered.set('cloud', candidates);
    this.emit({ type: 'CloudSpawned', lang, candidates });
  }

  /** Picks a word offered by `from` (a node, or the cloud). */
  pick(from: NodeId | 'cloud', word: string): NodeId {
    const candidate = this.offered.get(from)?.find((c) => c.word === word);
    if (candidate === undefined) throw new Error(`"${word}" was not offered by ${from}`);
    const origin: Origin = from === 'cloud' ? 'cloud' : 'branch';
    return this.choose(word, from === 'cloud' ? null : from, origin, candidate.candidateId);
  }

  choose(word: string, parent: NodeId | null, origin: Origin, fromCandidate: number | null = null): NodeId {
    const node = this.nextNode++;
    this.emit({ type: 'NodeChosen', node, parent, word, origin, fromCandidate });
    return node;
  }

  /** Streams branch words one by one, then seals the ring. */
  branches(node: NodeId, words: string[], firstMs = 350, gapMs = 110): void {
    const candidates = this.candidates(words);
    this.wait(firstMs);
    candidates.forEach((candidate, i) => {
      if (i > 0) this.wait(gapMs);
      this.emit({ type: 'CandidateStreamed', node, candidate });
    });
    this.wait(20);
    this.offered.set(node, candidates);
    this.emit({ type: 'BranchesOffered', node, candidates });
  }

  source(node: NodeId, kind: SourceKind, fields: Omit<Source, 'sourceId' | 'node' | 'kind'>): SourceId {
    const sourceId = this.nextSource++;
    this.emit({ type: 'SourceFound', source: { sourceId, node, kind, ...fields } });
    return sourceId;
  }

  entry(node: NodeId, relation: string, explanation: string, cites: SourceId[] = []): number {
    const entryId = this.nextEntry++;
    this.emit({ type: 'EntryWritten', entry: { entryId, node, relation, explanation, cites } });
    return entryId;
  }

  revise(entryId: number, node: NodeId, relation: string, explanation: string, cites: SourceId[]): void {
    this.emit({ type: 'EntryRevised', entry: { entryId, node, relation, explanation, cites } });
  }

  toJsonl(): string {
    return this.out.map((s) => JSON.stringify(s)).join('\n') + '\n';
  }
}

const wiki = (title: string, page: string) =>
  ({
    title,
    site: 'Wikipedia',
    url: `https://en.wikipedia.org/wiki/${page}`,
    thumbnailUrl: null,
    csl: {
      type: 'entry-encyclopedia',
      title,
      'container-title': 'Wikipedia',
      URL: `https://en.wikipedia.org/wiki/${page}`,
    },
  }) as const;

// ---------------------------------------------------------------------------
// exploration: a whole session with streaming, sources, a backtrack, an
// inserted word, curation, wrap-up and outputs.

function exploration(): Script {
  const s = new Script(Date.UTC(2026, 9, 24, 15, 0, 0));
  s.cloud('en', [
    'tide', 'lantern', 'entropy', 'orchard', 'signal', 'glacier',
    'ritual', 'velvet', 'compass', 'fungus', 'echo', 'harbor',
  ]);

  const entropy = s.wait(5200).pick('cloud', 'entropy');
  s.branches(entropy, ['information', 'disorder', 'time', 'compression', 'Boltzmann', 'decay']);

  const information = s.wait(4100).pick(entropy, 'information');
  s.branches(information, ['Shannon', 'noise', 'meaning', 'bits', 'DNA', 'signal']);
  const e1 = s.wait(900).entry(
    information,
    'Entropy measures information',
    'Shannon borrowed the word entropy for the average surprise of a message: the less predictable a source, the more information each symbol carries.',
  );
  const wikiEntropy = s.wait(800).source(information, 'webPage', wiki('Entropy (information theory)', 'Entropy_(information_theory)'));
  const shannon = s.wait(1200).source(information, 'paper', {
    title: 'A Mathematical Theory of Communication',
    site: 'Bell System Technical Journal',
    url: 'https://doi.org/10.1002/j.1538-7305.1948.tb01338.x',
    thumbnailUrl: null,
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
  s.wait(300).revise(
    e1,
    information,
    'Entropy measures information',
    'Shannon borrowed the word entropy for the average surprise of a message: the less predictable a source, the more information each symbol carries.',
    [wikiEntropy, shannon],
  );

  const noise = s.wait(3600).pick(information, 'noise');
  s.branches(noise, ['randomness', 'static', 'music', 'silence', 'dither', 'creativity']);
  const e2 = s.wait(1100).entry(
    noise,
    'Noise is information you did not ask for',
    'In a channel, noise is the unpredictable part of the signal; maximal entropy looks like pure noise.',
  );
  const whiteNoise = s.wait(1900).source(noise, 'audio', {
    title: 'White noise',
    site: 'Wikimedia Commons',
    url: 'https://commons.wikimedia.org/wiki/File:White_noise.ogg',
    thumbnailUrl: null,
    csl: { type: 'song', title: 'White noise', publisher: 'Wikimedia Commons' },
  });
  s.wait(200).revise(
    e2,
    noise,
    'Noise is information you did not ask for',
    'In a channel, noise is the unpredictable part of the signal; maximal entropy looks like pure noise.',
    [whiteNoise],
  );

  s.wait(2400).emit({ type: 'DivergenceSet', divergence: 0.8 });

  const creativity = s.wait(2100).pick(noise, 'creativity');
  s.branches(creativity, ['jazz', 'accident', 'play', 'boredom', 'mutation', 'serendipity'], 600, 140);
  const e3 = s.wait(1000).entry(
    creativity,
    'Noise as a source of new ideas',
    'Random perturbation can knock a search out of a rut; some creative techniques inject noise on purpose.',
  );

  s.wait(4800).emit({ type: 'NodeRevisited', node: information });
  s.branches(information, ['attention', 'library', 'privacy', 'language', 'DNA', 'compression']);

  const attention = s.wait(3900).pick(information, 'attention');
  s.branches(attention, ['focus', 'scarcity', 'transformer', 'mindfulness', 'economy', 'distraction']);
  const e4 = s.wait(900).entry(
    attention,
    'Attention filters information',
    'When information is abundant, attention becomes the scarce resource that decides what is processed at all.',
  );
  const transformer = s.wait(2600).source(attention, 'pdf', {
    title: 'Attention Is All You Need',
    site: 'arXiv',
    url: 'https://arxiv.org/pdf/1706.03762',
    thumbnailUrl: null,
    csl: {
      type: 'article',
      title: 'Attention Is All You Need',
      author: [
        { family: 'Vaswani', given: 'Ashish' },
        { family: 'Shazeer', given: 'Noam' },
        { family: 'Parmar', given: 'Niki' },
      ],
      issued: { 'date-parts': [[2017]] },
      number: 'arXiv:1706.03762',
      publisher: 'arXiv',
      URL: 'https://arxiv.org/abs/1706.03762',
    },
  });
  s.wait(200).revise(
    e4,
    attention,
    'Attention filters information',
    'When information is abundant, attention becomes the scarce resource that decides what is processed at all.',
    [transformer],
  );

  const flow = s.wait(6200).choose('flow', attention, 'insert');
  s.branches(flow, ['challenge', 'immersion', 'rhythm', 'timelessness', 'mastery', 'river']);
  const e5 = s.wait(1000).entry(
    flow,
    'Flow is attention fully absorbed',
    'Flow describes total absorption in a task whose challenge matches skill; attention stops being divided.',
  );
  const flowPage = s.wait(1700).source(flow, 'webPage', wiki('Flow (psychology)', 'Flow_(psychology)'));
  s.wait(200).revise(
    e5,
    flow,
    'Flow is attention fully absorbed',
    'Flow describes total absorption in a task whose challenge matches skill; attention stops being divided.',
    [flowPage],
  );

  s.wait(3000).emit({ type: 'EntryPromoted', entryId: e1, levels: 2 });
  s.wait(1200).emit({ type: 'EntryPromoted', entryId: e4, levels: 1 });
  s.wait(900).emit({ type: 'EntryPromoted', entryId: e5, levels: 2 });
  s.wait(1500).emit({ type: 'EntryStruck', entryId: e3 });

  s.wait(4000).emit({ type: 'WrappedUp' });
  s.wait(6500).emit({
    type: 'OutputsReady',
    outputs: {
      decisionTree: [
        '```mermaid',
        'flowchart TD',
        '  n1[entropy] --> n2[information]',
        '  n2 --> n3[noise]',
        '  n3 --> n4[creativity]',
        '  n2 -. revisited .-> n5[attention]',
        '  n5 --> n6[flow]',
        '```',
      ].join('\n'),
      draft: [
        '# Draft: from entropy to flow',
        '',
        '1. **Entropy measures information.** Shannon borrowed the word entropy for the average surprise of a message [@src1; @src2].',
        '2. **Noise is information you did not ask for.** Maximal entropy looks like pure noise [@src3].',
        '3. ~~**Noise as a source of new ideas.** Random perturbation can knock a search out of a rut.~~',
        '4. **Attention filters information.** When information is abundant, attention becomes the scarce resource [@src4].',
        '5. **Flow is attention fully absorbed.** Challenge matches skill and attention stops being divided [@src5].',
      ].join('\n'),
      final: [
        '# From entropy to flow',
        '',
        '## Information',
        '',
        'Entropy, in Shannon\'s sense, is the average surprise of a message [@src2]. The less predictable a source, the more information each symbol carries [@src1].',
        '',
        '## Attention',
        '',
        'Abundant information makes attention the scarce resource [@src4]. Flow is the state in which that attention is fully absorbed by a well-matched challenge [@src5].',
      ].join('\n'),
    },
  });
  return s;
}

// ---------------------------------------------------------------------------
// sources-heavy: a short path with many sources of every kind, and recorded
// placements, for building and testing source objects on the desk.

function sourcesHeavy(): Script {
  const s = new Script(Date.UTC(2026, 9, 24, 16, 0, 0));
  s.cloud('en', ['ocean', 'clock', 'myth', 'copper', 'migration', 'paper', 'orbit', 'salt']);

  const ocean = s.wait(3000).pick('cloud', 'ocean');
  s.emit({ type: 'NodePlaced', node: ocean, pos: { x: 0, y: 0 }, angle: 0 });
  s.branches(ocean, ['tide', 'abyss', 'current', 'whale', 'storm', 'coral']);

  const tide = s.wait(2500).pick(ocean, 'tide');
  s.emit({ type: 'NodePlaced', node: tide, pos: { x: 260, y: -40 }, angle: 0 });
  s.branches(tide, ['moon', 'rhythm', 'erosion', 'harbor', 'season', 'pull']);

  const moon = s.wait(2200).pick(tide, 'moon');
  s.emit({ type: 'NodePlaced', node: moon, pos: { x: 470, y: -180 }, angle: 0 });
  s.branches(moon, ['gravity', 'phase', 'calendar', 'werewolf', 'Apollo', 'crater']);

  const gravity = s.wait(2400).pick(moon, 'gravity');
  s.emit({ type: 'NodePlaced', node: gravity, pos: { x: 720, y: -120 }, angle: 0 });
  s.branches(gravity, ['relativity', 'weight', 'apple', 'orbit', 'wave', 'falling']);

  const placed: [SourceId, number, number, number][] = [];
  const at = (id: SourceId, x: number, y: number, angle: number) => placed.push([id, x, y, angle]);

  at(s.wait(600).source(tide, 'webPage', wiki('Tide', 'Tide')), 150, 90, -0.12);
  at(s.wait(400).source(tide, 'image', {
    title: 'Low tide at the Bay of Fundy',
    site: 'Wikimedia Commons',
    url: 'https://commons.wikimedia.org/wiki/Category:Tides_of_the_Bay_of_Fundy',
    thumbnailUrl: null,
    csl: { type: 'graphic', title: 'Low tide at the Bay of Fundy', publisher: 'Wikimedia Commons' },
  }), 230, 120, 0.18);
  at(s.wait(900).source(moon, 'webPage', wiki('Moon', 'Moon')), 380, -60, 0.08);
  at(s.wait(300).source(moon, 'article', {
    title: 'Earth\'s Moon',
    site: 'NASA Science',
    url: 'https://science.nasa.gov/moon/',
    thumbnailUrl: null,
    csl: { type: 'webpage', title: 'Earth\'s Moon', 'container-title': 'NASA Science', URL: 'https://science.nasa.gov/moon/' },
  }), 440, -20, -0.2);
  at(s.wait(500).source(moon, 'audio', {
    title: 'Ocean waves',
    site: 'Wikimedia Commons',
    url: 'https://commons.wikimedia.org/wiki/Category:Audio_files_of_ocean_waves',
    thumbnailUrl: null,
    csl: { type: 'song', title: 'Ocean waves', publisher: 'Wikimedia Commons' },
  }), 520, -40, 0.14);
  at(s.wait(1100).source(gravity, 'paper', {
    title: 'Die Grundlage der allgemeinen Relativitätstheorie',
    site: 'Annalen der Physik',
    url: 'https://doi.org/10.1002/andp.19163540702',
    thumbnailUrl: null,
    csl: {
      type: 'article-journal',
      title: 'Die Grundlage der allgemeinen Relativitätstheorie',
      author: [{ family: 'Einstein', given: 'Albert' }],
      'container-title': 'Annalen der Physik',
      volume: '354',
      issue: '7',
      page: '769-822',
      issued: { 'date-parts': [[1916]] },
      DOI: '10.1002/andp.19163540702',
    },
  }), 640, -10, -0.06);
  at(s.wait(700).source(gravity, 'pdf', {
    title: 'Observation of Gravitational Waves from a Binary Black Hole Merger',
    site: 'arXiv',
    url: 'https://arxiv.org/pdf/1602.03837',
    thumbnailUrl: null,
    csl: {
      type: 'article',
      title: 'Observation of Gravitational Waves from a Binary Black Hole Merger',
      author: [{ literal: 'LIGO Scientific Collaboration and Virgo Collaboration' }],
      issued: { 'date-parts': [[2016]] },
      number: 'arXiv:1602.03837',
      publisher: 'arXiv',
      URL: 'https://arxiv.org/abs/1602.03837',
    },
  }), 720, 10, 0.1);
  at(s.wait(400).source(gravity, 'webPage', wiki('Gravity', 'Gravity')), 800, -20, -0.15);

  for (const [sourceId, x, y, angle] of placed) {
    s.wait(150).emit({ type: 'SourcePlaced', sourceId, pos: { x, y }, angle });
  }
  return s;
}

mkdirSync(outDir, { recursive: true });
for (const [name, script] of [
  ['exploration', exploration()],
  ['sources-heavy', sourcesHeavy()],
] as const) {
  writeFileSync(new URL(`${name}.jsonl`, outDir), script.toJsonl());
  console.log(`${name}.jsonl: ${script.out.length} events`);
}

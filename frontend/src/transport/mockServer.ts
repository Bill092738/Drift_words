import type {
  Candidate,
  CandidateId,
  Command,
  Event,
  Lang,
  NodeId,
  Origin,
  ServerMsg,
  SourceId,
  Stamped,
} from '../protocol/index.ts';
import { answerDeterministic } from './mock.ts';
import { Listeners, type ServerListener, type Transport } from './transport.ts';
import { relatedWords, rng, shuffle, wordBank } from './wordbank.ts';

export interface MockServerOptions {
  seed?: number;
  lang?: Lang;
  cloudSize?: number;
  ringSize?: number;
  /** Delay before the first streamed branch word, ms. */
  firstWordMs?: number;
  /** Delay between streamed branch words, ms. */
  wordGapMs?: number;
  /** Write fake sidebar entries and sources. Default true. */
  notes?: boolean;
}

/** Offered-but-unchosen words may reappear at most this many times. */
export function repeatCap(divergence: number): number {
  return Math.max(1, Math.round(3 - 2 * divergence));
}

/** A single word: no whitespace, 1 to 40 characters. */
export function isSingleWord(word: string): boolean {
  return /^\S{1,40}$/u.test(word);
}

const capitalize = (w: string) => w.charAt(0).toUpperCase() + w.slice(1);

/**
 * An interactive, in-browser stand-in for a backend session. It answers
 * picks, inserted words and backtracks with streamed branch words, follows
 * the loop-prevention rules from idea.md, and writes placeholder sidebar
 * entries and sources, so the whole frontend runs offline.
 */
export class MockServer implements Transport {
  private readonly listeners = new Listeners();
  private readonly random: () => number;
  private readonly opts: Required<Omit<MockServerOptions, 'seed'>>;
  private readonly timers = new Set<ReturnType<typeof setTimeout>>();
  private seq = 0;
  private nextReq = 1;
  private started = false;
  private closed = false;

  private nextNode = 1;
  private nextCandidate = 1;
  private nextSource = 1;
  private nextEntry = 1;
  private divergence = 0.5;
  private current: NodeId | null = null;
  private readonly words = new Map<NodeId, string>();
  private readonly parents = new Map<NodeId, NodeId | null>();
  /** Words chosen so far (normalized). */
  private readonly visited = new Set<string>();
  /** Times each unchosen word has been offered (normalized). */
  private readonly offeredCount = new Map<string, number>();
  /** Candidates the user may pick right now: the cloud before the root, then the current ring. */
  private offer = new Map<CandidateId, string>();

  constructor(options: MockServerOptions = {}) {
    this.random = rng(options.seed ?? 7);
    this.opts = {
      lang: options.lang ?? 'en',
      cloudSize: options.cloudSize ?? 12,
      ringSize: options.ringSize ?? 6,
      firstWordMs: options.firstWordMs ?? 320,
      wordGapMs: options.wordGapMs ?? 110,
      notes: options.notes ?? true,
    };
  }

  subscribe(listener: ServerListener): () => void {
    const remove = this.listeners.add(listener);
    if (!this.started) {
      this.started = true;
      this.later(0, () => this.spawnCloud());
    }
    return remove;
  }

  close(): void {
    this.closed = true;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.listeners.clear();
  }

  send(command: Command): number {
    const req = this.nextReq++;
    queueMicrotask(() => {
      if (this.closed) return;
      const reason = this.handle(command);
      if (reason !== null) this.reply({ type: 'Rejected', req, reason });
    });
    return req;
  }

  // ---------------------------------------------------------------------------

  /** Returns a rejection reason, or null when the command was accepted. */
  private handle(c: Command): string | null {
    switch (c.type) {
      case 'Pick': {
        const word = this.offer.get(c.candidateId);
        if (word === undefined) return 'that word is not on offer';
        this.choose(word, this.current, this.current === null ? 'cloud' : 'branch', c.candidateId);
        return null;
      }
      case 'StartWithWord':
        if (this.current !== null) return 'the session has already started';
        if (!isSingleWord(c.word)) return 'one word only';
        this.choose(c.word, null, 'startWord', null);
        return null;
      case 'InsertWord':
        if (this.current === null) return 'pick or type a starting word first';
        if (!isSingleWord(c.word)) return 'one word only';
        if (this.visited.has(c.word.toLowerCase())) return 'that word is already on the path';
        this.choose(c.word, this.current, 'insert', null);
        return null;
      case 'Backtrack':
        if (!this.words.has(c.node)) return 'unknown node';
        if (c.node === this.current) return 'already there';
        this.current = c.node;
        this.emit([{ type: 'NodeRevisited', node: c.node }]);
        this.grow(c.node);
        return null;
      case 'SetDivergence':
        this.divergence = Math.min(1, Math.max(0, c.divergence));
        break;
      case 'WrapUp':
        this.emit([{ type: 'WrappedUp' }]);
        return null;
      default:
        break;
    }
    const events = answerDeterministic(c);
    if (events !== undefined) this.emit(events);
    return null;
  }

  private spawnCloud(): void {
    const words = shuffle(wordBank, this.random).slice(0, this.opts.cloudSize);
    const candidates = this.candidates(words);
    this.offer = new Map(candidates.map((c) => [c.candidateId, c.word]));
    this.emit([{ type: 'CloudSpawned', lang: this.opts.lang, candidates }]);
  }

  private choose(word: string, parent: NodeId | null, origin: Origin, fromCandidate: CandidateId | null): void {
    const node = this.nextNode++;
    this.words.set(node, word);
    this.parents.set(node, parent);
    this.visited.add(word.toLowerCase());
    this.current = node;
    this.offer = new Map();
    this.emit([{ type: 'NodeChosen', node, parent, word, origin, fromCandidate }]);
    this.grow(node);
    if (parent !== null && this.opts.notes) this.writeNotes(node, this.words.get(parent) ?? '', word);
  }

  /** Streams a new ring of branch words for `node`, then seals it. */
  private grow(node: NodeId): void {
    const word = this.words.get(node) ?? '';
    const cap = repeatCap(this.divergence);
    const picked: string[] = [];
    for (const w of relatedWords(word, this.divergence, this.random)) {
      const key = w.toLowerCase();
      if (picked.length >= this.opts.ringSize) break;
      if (this.visited.has(key) || picked.some((p) => p.toLowerCase() === key)) continue;
      if ((this.offeredCount.get(key) ?? 0) >= cap) continue;
      picked.push(w);
    }
    for (const w of picked) this.offeredCount.set(w.toLowerCase(), (this.offeredCount.get(w.toLowerCase()) ?? 0) + 1);

    const candidates = this.candidates(picked);
    this.offer = new Map(candidates.map((c) => [c.candidateId, c.word]));
    candidates.forEach((candidate, i) => {
      this.later(this.opts.firstWordMs + i * this.opts.wordGapMs, () => {
        if (this.current === node) this.emit([{ type: 'CandidateStreamed', node, candidate }]);
      });
    });
    this.later(this.opts.firstWordMs + candidates.length * this.opts.wordGapMs, () => {
      if (this.current === node) this.emit([{ type: 'BranchesOffered', node, candidates }]);
    });
  }

  private writeNotes(node: NodeId, from: string, to: string): void {
    const entryId = this.nextEntry++;
    const relation = `From ${from} to ${to}`;
    const explanation = `Placeholder note from the offline mock. The writing pipeline will explain how "${from}" leads to "${to}".`;
    this.later(900 + this.random() * 600, () =>
      this.emit([{ type: 'EntryWritten', entry: { entryId, node, relation, explanation, cites: [] } }]),
    );
    if (this.random() < 0.5) {
      const sourceId: SourceId = this.nextSource++;
      const title = capitalize(to);
      const url = `https://en.wikipedia.org/wiki/${encodeURIComponent(title)}`;
      this.later(1800 + this.random() * 1500, () =>
        this.emit([
          {
            type: 'SourceFound',
            source: {
              sourceId,
              node,
              kind: 'webPage',
              title,
              site: 'Wikipedia',
              url,
              thumbnailUrl: null,
              csl: { type: 'entry-encyclopedia', title, 'container-title': 'Wikipedia', URL: url },
            },
          },
          { type: 'EntryRevised', entry: { entryId, node, relation, explanation, cites: [sourceId] } },
        ]),
      );
    }
  }

  private candidates(words: readonly string[]): Candidate[] {
    return words.map((word) => ({ candidateId: this.nextCandidate++, word }));
  }

  private emit(events: Event[]): void {
    const at = Date.now();
    const stamped: Stamped[] = events.map((event) => ({ seq: ++this.seq, atMs: at, event }));
    this.reply({ type: 'Events', events: stamped });
  }

  private reply(msg: ServerMsg): void {
    if (!this.closed) this.listeners.emit(msg);
  }

  private later(ms: number, f: () => void): void {
    const t = setTimeout(() => {
      this.timers.delete(t);
      if (!this.closed) f();
    }, ms);
    this.timers.add(t);
  }
}

// The client mirror of a session: a pure fold over the server's events,
// matching the backend's `apply`. Shared by the desk (M4) and the chrome (M7).
import type {
  Candidate,
  CandidateId,
  Entry,
  EntryId,
  Event,
  Lang,
  NodeId,
  Origin,
  Outputs,
  Source,
  SourceId,
  Stamped,
  Vec2,
} from '../protocol/index.ts';

export interface Placement {
  pos: Vec2;
  angle: number;
}

export interface NodeState {
  id: NodeId;
  parent: NodeId | null;
  word: string;
  origin: Origin;
  fromCandidate: CandidateId | null;
  /** 0 for the first chosen node, then 1, 2, ... */
  order: number;
  /** True once the user has backtracked to this node at least once. */
  revisited: boolean;
  placement: Placement | null;
}

export interface SourceState {
  source: Source;
  placement: Placement | null;
}

export interface EntryState {
  entry: Entry;
  /** 0 when written; raised by promotions, without an upper limit. */
  priority: number;
  struck: boolean;
  /** Sequence number of the event that first wrote the entry. */
  writtenSeq: number;
}

export interface SessionState {
  lang: Lang | null;
  divergence: number;
  cloud: Candidate[];
  nodes: ReadonlyMap<NodeId, NodeState>;
  /** The node the user is growing from, if any. */
  current: NodeId | null;
  /** The latest sealed ring of branch words for each node. */
  offers: ReadonlyMap<NodeId, Candidate[]>;
  /** Branch words that have streamed in for a node but are not sealed yet. */
  streaming: ReadonlyMap<NodeId, Candidate[]>;
  sources: ReadonlyMap<SourceId, SourceState>;
  entries: ReadonlyMap<EntryId, EntryState>;
  wrappedUp: boolean;
  outputs: Outputs | null;
  lastSeq: number;
}

export const DEFAULT_DIVERGENCE = 0.5;

export const emptySession: SessionState = {
  lang: null,
  divergence: DEFAULT_DIVERGENCE,
  cloud: [],
  nodes: new Map(),
  current: null,
  offers: new Map(),
  streaming: new Map(),
  sources: new Map(),
  entries: new Map(),
  wrappedUp: false,
  outputs: null,
  lastSeq: 0,
};

function withEntry<K, V>(map: ReadonlyMap<K, V>, key: K, value: V): Map<K, V> {
  return new Map(map).set(key, value);
}

function without<K, V>(map: ReadonlyMap<K, V>, key: K): Map<K, V> {
  const next = new Map(map);
  next.delete(key);
  return next;
}

function updateEntry(s: SessionState, id: EntryId, f: (e: EntryState) => EntryState): SessionState {
  const e = s.entries.get(id);
  return e === undefined ? s : { ...s, entries: withEntry(s.entries, id, f(e)) };
}

/**
 * Applies one event. Events at or below `lastSeq` were already applied and
 * are skipped, so replaying the whole log after a reconnect is harmless.
 * Events that refer to unknown nodes or entries are ignored, not thrown on.
 */
export function applyEvent(s: SessionState, stamped: Stamped): SessionState {
  if (stamped.seq <= s.lastSeq) return s;
  return { ...apply(s, stamped.event, stamped.seq), lastSeq: stamped.seq };
}

export function applyEvents(s: SessionState, events: readonly Stamped[]): SessionState {
  return events.reduce(applyEvent, s);
}

function apply(s: SessionState, e: Event, seq: number): SessionState {
  switch (e.type) {
    case 'CloudSpawned':
      return { ...s, lang: e.lang, cloud: e.candidates };

    case 'NodeChosen': {
      const node: NodeState = {
        id: e.node,
        parent: e.parent,
        word: e.word,
        origin: e.origin,
        fromCandidate: e.fromCandidate,
        order: s.nodes.size,
        revisited: false,
        placement: null,
      };
      return { ...s, nodes: withEntry(s.nodes, e.node, node), current: e.node };
    }

    case 'CandidateStreamed': {
      const sofar = s.streaming.get(e.node) ?? [];
      return { ...s, streaming: withEntry(s.streaming, e.node, [...sofar, e.candidate]) };
    }

    case 'BranchesOffered':
      return {
        ...s,
        offers: withEntry(s.offers, e.node, e.candidates),
        streaming: without(s.streaming, e.node),
      };

    case 'NodeRevisited': {
      const node = s.nodes.get(e.node);
      if (node === undefined) return s;
      return { ...s, nodes: withEntry(s.nodes, e.node, { ...node, revisited: true }), current: e.node };
    }

    case 'DivergenceSet':
      return { ...s, divergence: e.divergence };

    case 'SourceFound': {
      const prev = s.sources.get(e.source.sourceId);
      return {
        ...s,
        sources: withEntry(s.sources, e.source.sourceId, { source: e.source, placement: prev?.placement ?? null }),
      };
    }

    case 'EntryWritten':
    case 'EntryRevised': {
      const prev = s.entries.get(e.entry.entryId);
      const entry: EntryState = prev
        ? { ...prev, entry: e.entry }
        : { entry: e.entry, priority: 0, struck: false, writtenSeq: seq };
      return { ...s, entries: withEntry(s.entries, e.entry.entryId, entry) };
    }

    case 'EntryPromoted':
      return updateEntry(s, e.entryId, (x) => ({ ...x, priority: x.priority + e.levels }));

    case 'EntryStruck':
      return updateEntry(s, e.entryId, (x) => ({ ...x, struck: true }));

    case 'EntryRestored':
      return updateEntry(s, e.entryId, (x) => ({ ...x, struck: false }));

    case 'NodePlaced': {
      const node = s.nodes.get(e.node);
      if (node === undefined) return s;
      const placement = { pos: e.pos, angle: e.angle };
      return { ...s, nodes: withEntry(s.nodes, e.node, { ...node, placement }) };
    }

    case 'SourcePlaced': {
      const src = s.sources.get(e.sourceId);
      if (src === undefined) return s;
      const placement = { pos: e.pos, angle: e.angle };
      return { ...s, sources: withEntry(s.sources, e.sourceId, { ...src, placement }) };
    }

    case 'WrappedUp':
      return { ...s, wrappedUp: true };

    case 'OutputsReady':
      return { ...s, outputs: e.outputs };
  }
}

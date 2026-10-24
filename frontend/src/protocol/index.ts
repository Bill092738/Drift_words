// Public entry point for the wire protocol. Types come from the generated file;
// this module adds the small runtime helpers both transports need.
import type { Event, Stamped } from './generated.ts';

export type * from './generated.ts';

/**
 * Every event tag. Typed as a Record so the compiler fails here whenever the
 * backend adds an event that the frontend does not know about yet.
 */
const EVENT_TYPES: Record<Event['type'], true> = {
  CloudSpawned: true,
  NodeChosen: true,
  CandidateStreamed: true,
  BranchesOffered: true,
  NodeRevisited: true,
  DivergenceSet: true,
  SourceFound: true,
  EntryWritten: true,
  EntryRevised: true,
  EntryPromoted: true,
  EntryStruck: true,
  EntryRestored: true,
  NodePlaced: true,
  SourcePlaced: true,
  WrappedUp: true,
  OutputsReady: true,
};

export function isEventType(tag: unknown): tag is Event['type'] {
  return typeof tag === 'string' && Object.hasOwn(EVENT_TYPES, tag);
}

/**
 * Parses a fixture file: one {@link Stamped} event per line, blank lines ignored.
 * Only the envelope and the event tag are checked here; the backend test suite
 * decodes every fixture against the full Haskell types.
 */
export function parseEventLog(text: string): Stamped[] {
  return text
    .split('\n')
    .map((line, i) => [line.trim(), i + 1] as const)
    .filter(([line]) => line !== '')
    .map(([line, lineNo]) => {
      const value: unknown = JSON.parse(line);
      if (!isStamped(value)) throw new Error(`line ${lineNo}: not a stamped event`);
      return value;
    });
}

function isStamped(v: unknown): v is Stamped {
  if (typeof v !== 'object' || v === null) return false;
  const s = v as Record<string, unknown>;
  const event = s['event'] as Record<string, unknown> | undefined;
  return (
    typeof s['seq'] === 'number' &&
    typeof s['atMs'] === 'number' &&
    typeof event === 'object' &&
    event !== null &&
    isEventType(event['type'])
  );
}

import type { Command, Event, Stamped } from '../protocol/index.ts';
import { Listeners, type ServerListener, type Transport } from './transport.ts';

/** Turns a command into the events a server would answer with, if any. */
export type MockResponder = (command: Command) => Event[] | undefined;

export interface MockOptions {
  /** Playback speed multiplier; 2 plays twice as fast. Default 1. */
  speed?: number;
  /** Gaps between events are capped at this many milliseconds (after speed). Default 4000. */
  maxGapMs?: number;
  /** Called for every command the app sends. */
  onCommand?: (command: Command, req: number) => void;
  /** Answers commands with events, interleaved with the replay. Default: none. */
  respond?: MockResponder;
}

/**
 * Replays a recorded event log with its original timing, so the frontend can
 * be built and demonstrated without a backend. Events are delivered one per
 * message, the way the live server sends them after the initial catch-up.
 * Delivered events are renumbered, so responses can be interleaved.
 *
 * Playback starts with the first subscriber.
 */
export class MockTransport implements Transport {
  private readonly listeners = new Listeners();
  private readonly log: readonly Stamped[];
  private readonly speed: number;
  private readonly maxGapMs: number;
  private readonly onCommand: MockOptions['onCommand'];
  private readonly respond: MockResponder | undefined;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private next = 0;
  private nextReq = 1;
  private seq = 0;
  private lastAtMs = 0;
  private started = false;
  private closed = false;

  constructor(log: readonly Stamped[], options: MockOptions = {}) {
    this.log = log;
    this.speed = options.speed ?? 1;
    this.maxGapMs = options.maxGapMs ?? 4000;
    this.onCommand = options.onCommand;
    this.respond = options.respond;
  }

  send(command: Command): number {
    const req = this.nextReq++;
    this.onCommand?.(command, req);
    const events = this.respond?.(command);
    if (events !== undefined && events.length > 0) {
      // Answer asynchronously, like a real server.
      queueMicrotask(() => {
        if (!this.closed) this.emit(events.map((e) => this.stamp(e, this.lastAtMs)));
      });
    }
    return req;
  }

  subscribe(listener: ServerListener): () => void {
    const remove = this.listeners.add(listener);
    if (!this.started) {
      this.started = true;
      this.schedule(0);
    }
    return remove;
  }

  close(): void {
    this.closed = true;
    clearTimeout(this.timer);
    this.timer = undefined;
    this.listeners.clear();
  }

  private stamp(event: Event, atMs: number): Stamped {
    return { seq: ++this.seq, atMs, event };
  }

  private emit(events: Stamped[]): void {
    this.listeners.emit({ type: 'Events', events });
  }

  private schedule(delayMs: number): void {
    this.timer = setTimeout(() => this.deliver(), delayMs);
  }

  private deliver(): void {
    const current = this.log[this.next];
    if (current === undefined) return;
    this.lastAtMs = current.atMs;
    this.emit([this.stamp(current.event, current.atMs)]);
    this.next++;
    const following = this.log[this.next];
    if (following === undefined) return;
    const gap = (following.atMs - current.atMs) / this.speed;
    this.schedule(Math.min(Math.max(gap, 0), this.maxGapMs));
  }
}

/**
 * Answers the commands whose outcome needs no model or search: curation,
 * divergence and placement. Enough to make the sidebar fully interactive on
 * fixtures. Picking, inserting and backtracking are left to M4's mock.
 */
export const answerDeterministic: MockResponder = (c) => {
  switch (c.type) {
    case 'Promote':
      return [{ type: 'EntryPromoted', entryId: c.entryId, levels: c.levels }];
    case 'Strike':
      return [{ type: 'EntryStruck', entryId: c.entryId }];
    case 'Restore':
      return [{ type: 'EntryRestored', entryId: c.entryId }];
    case 'SetDivergence':
      return [{ type: 'DivergenceSet', divergence: c.divergence }];
    case 'PlaceNode':
      return [{ type: 'NodePlaced', node: c.node, pos: c.pos, angle: c.angle }];
    case 'PlaceSource':
      return [{ type: 'SourcePlaced', sourceId: c.sourceId, pos: c.pos, angle: c.angle }];
    default:
      return undefined;
  }
};

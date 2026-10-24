import type { Command, Stamped } from '../protocol/index.ts';
import { Listeners, type ServerListener, type Transport } from './transport.ts';

export interface MockOptions {
  /** Playback speed multiplier; 2 plays twice as fast. Default 1. */
  speed?: number;
  /** Gaps between events are capped at this many milliseconds (after speed). Default 4000. */
  maxGapMs?: number;
  /** Called for every command the app sends. The mock does not answer them. */
  onCommand?: (command: Command, req: number) => void;
}

/**
 * Replays a recorded event log with its original timing, so the frontend can
 * be built and demonstrated without a backend. Events are delivered one per
 * message, the way the live server sends them after the initial catch-up.
 *
 * Playback starts with the first subscriber.
 */
export class MockTransport implements Transport {
  private readonly listeners = new Listeners();
  private readonly log: readonly Stamped[];
  private readonly speed: number;
  private readonly maxGapMs: number;
  private readonly onCommand: MockOptions['onCommand'];
  private timer: ReturnType<typeof setTimeout> | undefined;
  private next = 0;
  private nextReq = 1;
  private started = false;

  constructor(log: readonly Stamped[], options: MockOptions = {}) {
    this.log = log;
    this.speed = options.speed ?? 1;
    this.maxGapMs = options.maxGapMs ?? 4000;
    this.onCommand = options.onCommand;
  }

  send(command: Command): number {
    const req = this.nextReq++;
    this.onCommand?.(command, req);
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
    clearTimeout(this.timer);
    this.timer = undefined;
    this.listeners.clear();
  }

  private schedule(delayMs: number): void {
    this.timer = setTimeout(() => this.deliver(), delayMs);
  }

  private deliver(): void {
    const current = this.log[this.next];
    if (current === undefined) return;
    this.listeners.emit({ type: 'Events', events: [current] });
    this.next++;
    const following = this.log[this.next];
    if (following === undefined) return;
    const gap = (following.atMs - current.atMs) / this.speed;
    this.schedule(Math.min(Math.max(gap, 0), this.maxGapMs));
  }
}

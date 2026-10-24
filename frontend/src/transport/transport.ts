import type { Command, ServerMsg } from '../protocol/index.ts';

export type ServerListener = (msg: ServerMsg) => void;

/**
 * The only way the app talks to a session. The store subscribes to server
 * messages; the desk and chrome send commands. Swapping the implementation
 * (WebSocket or mock replay) changes nothing above this layer.
 */
export interface Transport {
  /** Sends a command and returns the request id the server will echo on rejection. */
  send(command: Command): number;
  /** Registers a listener; returns a function that removes it. */
  subscribe(listener: ServerListener): () => void;
  close(): void;
}

/** Shared listener bookkeeping for transport implementations. */
export class Listeners {
  private readonly set = new Set<ServerListener>();

  add(listener: ServerListener): () => void {
    this.set.add(listener);
    return () => this.set.delete(listener);
  }

  emit(msg: ServerMsg): void {
    for (const listener of this.set) listener(msg);
  }

  clear(): void {
    this.set.clear();
  }
}

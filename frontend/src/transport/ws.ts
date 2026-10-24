import type { ClientMsg, Command, ServerMsg } from '../protocol/index.ts';
import { Listeners, type ServerListener, type Transport } from './transport.ts';

/**
 * Talks to a live session at `/api/sessions/:id/ws`. On connect the server
 * sends the whole log so far as one `Events` message, then live events.
 * Commands sent before the socket opens are queued.
 */
export class WebSocketTransport implements Transport {
  private readonly listeners = new Listeners();
  private readonly socket: WebSocket;
  private readonly pending: string[] = [];
  private nextReq = 1;

  constructor(url: string) {
    this.socket = new WebSocket(url);
    this.socket.addEventListener('open', () => {
      for (const frame of this.pending.splice(0)) this.socket.send(frame);
    });
    this.socket.addEventListener('message', (e: MessageEvent<string>) => {
      this.listeners.emit(JSON.parse(e.data) as ServerMsg);
    });
  }

  static forSession(sessionId: string): WebSocketTransport {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    return new WebSocketTransport(`${scheme}://${location.host}/api/sessions/${sessionId}/ws`);
  }

  send(command: Command): number {
    const req = this.nextReq++;
    const frame = JSON.stringify({ req, command } satisfies ClientMsg);
    if (this.socket.readyState === WebSocket.OPEN) this.socket.send(frame);
    else this.pending.push(frame);
    return req;
  }

  subscribe(listener: ServerListener): () => void {
    return this.listeners.add(listener);
  }

  close(): void {
    this.listeners.clear();
    this.socket.close();
  }
}

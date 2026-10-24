import type { ClientMsg, Command, DiagnosticLevel, ServerMsg } from '../protocol/index.ts';
import { Listeners, type ServerListener, type Transport } from './transport.ts';

/** Where the socket stands, for a status line in the UI. */
export type ConnectionStatus = 'connecting' | 'open' | 'reconnecting';

export interface WebSocketTransportOptions {
  onStatus?: (status: ConnectionStatus) => void;
  /** Delay before the first reconnect attempt; doubles up to {@link maxRetryMs}. */
  retryMs?: number;
  maxRetryMs?: number;
}

/**
 * Talks to a live session at `/api/sessions/:id/ws`. On connect the server
 * sends the whole log so far as one `Events` message, then live events.
 *
 * A dropped connection is reopened with backoff until {@link close}. The
 * server resends the whole log on every connect, and the store skips events
 * it already has, so a reconnect needs no bookkeeping here. Commands sent
 * while the socket is down are queued and sent once it reopens; the server
 * rejects any that no longer apply. Connection problems reach the store as
 * local `Diagnostic` messages, which are never part of the session log.
 */
export class WebSocketTransport implements Transport {
  private readonly listeners = new Listeners();
  private readonly pending: string[] = [];
  private readonly url: string;
  private readonly options: WebSocketTransportOptions;
  private readonly retryMs: number;
  private readonly maxRetryMs: number;
  private socket: WebSocket | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private failures = 0;
  private everOpened = false;
  private closed = false;
  private nextReq = 1;

  constructor(url: string, options: WebSocketTransportOptions = {}) {
    this.url = url;
    this.options = options;
    this.retryMs = options.retryMs ?? 500;
    this.maxRetryMs = options.maxRetryMs ?? 5000;
    this.connect();
  }

  static forSession(sessionId: string, options?: WebSocketTransportOptions): WebSocketTransport {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    const id = encodeURIComponent(sessionId);
    return new WebSocketTransport(`${scheme}://${location.host}/api/sessions/${id}/ws`, options);
  }

  send(command: Command): number {
    const req = this.nextReq++;
    const frame = JSON.stringify({ req, command } satisfies ClientMsg);
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(frame);
    else this.pending.push(frame);
    return req;
  }

  subscribe(listener: ServerListener): () => void {
    return this.listeners.add(listener);
  }

  close(): void {
    this.closed = true;
    if (this.retryTimer !== null) clearTimeout(this.retryTimer);
    this.listeners.clear();
    this.socket?.close();
    this.socket = null;
  }

  private connect(): void {
    this.options.onStatus?.(this.everOpened ? 'reconnecting' : 'connecting');
    const socket = new WebSocket(this.url);
    this.socket = socket;
    socket.addEventListener('open', () => {
      if (this.closed || socket !== this.socket) return;
      if (this.failures > 0) this.diagnose('info', 'Connected to the session again.');
      this.failures = 0;
      this.everOpened = true;
      this.options.onStatus?.('open');
      for (const frame of this.pending.splice(0)) socket.send(frame);
    });
    socket.addEventListener('message', (e: MessageEvent<string>) => {
      if (this.closed || socket !== this.socket) return;
      let msg: ServerMsg;
      try {
        msg = JSON.parse(e.data) as ServerMsg;
      } catch {
        this.diagnose('error', 'Ignored a server message that is not valid JSON.');
        return;
      }
      this.listeners.emit(msg);
    });
    // 'close' follows 'error', so reconnecting from 'close' alone covers both.
    socket.addEventListener('close', () => {
      if (this.closed || socket !== this.socket) return;
      this.socket = null;
      this.failures += 1;
      if (this.failures === 1) {
        this.diagnose(
          'warning',
          this.everOpened
            ? 'Lost the connection to the session; reconnecting.'
            : 'Cannot reach the session yet; retrying. Is drift-server running, and does the session exist?',
        );
      }
      const delay = Math.min(this.maxRetryMs, this.retryMs * 2 ** (this.failures - 1));
      this.options.onStatus?.('reconnecting');
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        if (!this.closed) this.connect();
      }, delay);
    });
  }

  private diagnose(level: DiagnosticLevel, message: string): void {
    this.listeners.emit({ type: 'Diagnostic', level, message });
  }
}

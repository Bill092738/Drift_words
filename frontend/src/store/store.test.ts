import { describe, expect, it } from 'vitest';
import type { Command, ServerMsg } from '../protocol/index.ts';
import type { ServerListener, Transport } from '../transport/transport.ts';
import { createSessionStore } from './store.ts';

class TestTransport implements Transport {
  private listener: ServerListener | null = null;

  send(_command: Command): number {
    return 1;
  }

  subscribe(listener: ServerListener): () => void {
    this.listener = listener;
    return () => {
      this.listener = null;
    };
  }

  close(): void {}

  emit(message: ServerMsg): void {
    this.listener?.(message);
  }
}

describe('createSessionStore', () => {
  it('keeps diagnostics separate from command rejections', () => {
    const transport = new TestTransport();
    const [store] = createSessionStore(transport);

    transport.emit({ type: 'Diagnostic', level: 'warning', message: 'retrying generation' });

    expect(store.getState().diagnostics).toEqual([
      { level: 'warning', message: 'retrying generation' },
    ]);
    expect(store.getState().lastRejection).toBeNull();
  });

  it('retains diagnostics in arrival order', () => {
    const transport = new TestTransport();
    const [store] = createSessionStore(transport);

    transport.emit({ type: 'Diagnostic', level: 'warning', message: 'first' });
    transport.emit({ type: 'Diagnostic', level: 'error', message: 'second' });

    expect(store.getState().diagnostics.map((item) => item.message)).toEqual(['first', 'second']);
  });
});

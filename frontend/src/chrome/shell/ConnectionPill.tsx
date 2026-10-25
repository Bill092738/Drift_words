import { devMode } from '../../devMode.ts';
import { icons } from '../icons.tsx';

/** Where the live connection stands. Mock sessions have none. */
export type Connection =
  | { state: 'none' }
  | { state: 'starting' }
  | { state: 'connecting' }
  | { state: 'open' }
  | { state: 'reconnecting' }
  | { state: 'failed'; reason: string };

/**
 * A small status capsule at the top of the screen, shown only while the live
 * connection is not working. A healthy connection shows nothing.
 */
export function ConnectionPill({ connection, onRetry }: { connection: Connection; onRetry: () => void }) {
  if (connection.state === 'none' || connection.state === 'open') return null;
  const failed = connection.state === 'failed';
  return (
    <div className="connection material" data-state={connection.state} role={failed ? 'alert' : 'status'}>
      {failed ? <icons.warning size={16} /> : <span className="spinner" aria-hidden="true" />}
      <span>
        {connection.state === 'starting' && 'Starting a session…'}
        {connection.state === 'connecting' && 'Connecting…'}
        {connection.state === 'reconnecting' && 'Reconnecting…'}
        {failed && "Can't reach the Driftwords server."}
        {failed && devMode && <span className="connection-detail"> {connection.reason} Start it with make server.</span>}
      </span>
      {failed && (
        <button type="button" className="btn btn-secondary btn-sm" onClick={onRetry}>
          <icons.retry size={14} />
          Try again
        </button>
      )}
    </div>
  );
}

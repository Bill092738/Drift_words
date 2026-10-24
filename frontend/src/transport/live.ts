import type { Lang } from '../protocol/index.ts';

/** The URL parameter that names the live session, so a reload resumes it. */
export const SESSION_PARAM = 'session';
/** `?live` opens a new live session without picking it in the toolbar. */
export const LIVE_PARAM = 'live';

/**
 * Creates a session on drift-server and returns its id. Sessions are always
 * English for now; the backend's Chinese support is out of scope.
 */
export async function createLiveSession(lang: Lang = 'en'): Promise<string> {
  const response = await fetch('/api/sessions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ lang }),
  });
  if (!response.ok) throw new Error(`drift-server answered ${response.status} ${response.statusText}`.trim());
  const body = (await response.json()) as { sessionId?: unknown };
  if (typeof body.sessionId !== 'string' || body.sessionId === '') {
    throw new Error('drift-server returned no session id');
  }
  return body.sessionId;
}

export function sessionFromUrl(): string | null {
  const id = new URLSearchParams(location.search).get(SESSION_PARAM);
  return id === null || id === '' ? null : id;
}

export function wantsLive(): boolean {
  const params = new URLSearchParams(location.search);
  return params.has(SESSION_PARAM) || params.has(LIVE_PARAM);
}

/**
 * Records the live session in the URL (or removes it with `null`) without
 * reloading, keeping other parameters such as `debug`.
 */
export function setSessionInUrl(id: string | null): void {
  const url = new URL(location.href);
  url.searchParams.delete(LIVE_PARAM);
  if (id === null) url.searchParams.delete(SESSION_PARAM);
  else url.searchParams.set(SESSION_PARAM, id);
  history.replaceState(history.state, '', url);
}

// What a screen reader hears as the session changes. The desk is a canvas, so
// these sentences carry what a sighted user sees happen on it.
import type { SessionState } from '../store/session.ts';

function list(words: readonly string[]): string {
  return words.join(', ');
}

/** Sentences describing the step from `prev` to `next`, in the order they happened. */
export function announcements(prev: SessionState, next: SessionState): string[] {
  const out: string[] = [];

  if (prev.cloud.length === 0 && next.cloud.length > 0 && next.nodes.size === 0) {
    out.push(`${next.cloud.length} words are drifting: ${list(next.cloud.map((c) => c.word))}. Pick one to begin.`);
  }

  const current = next.current;
  if (current !== null && current !== prev.current) {
    const node = next.nodes.get(current);
    if (node !== undefined) out.push(prev.nodes.has(current) ? `Back at ${node.word}.` : `You chose ${node.word}.`);
  }

  if (current !== null) {
    const offered = next.offers.get(current);
    if (offered !== undefined && offered !== prev.offers.get(current)) {
      out.push(offered.length > 0 ? `New words: ${list(offered.map((c) => c.word))}.` : 'No new words came up.');
    }
  }

  const newSources = [...next.sources.values()].filter((s) => !prev.sources.has(s.source.sourceId));
  if (newSources.length === 1) out.push(`A source landed: ${newSources[0]!.source.title}.`);
  else if (newSources.length > 1) out.push(`${newSources.length} sources landed.`);

  const newEntries = [...next.entries.keys()].filter((id) => !prev.entries.has(id)).length;
  if (newEntries === 1) out.push('A note was added.');
  else if (newEntries > 1) out.push(`${newEntries} notes were added.`);

  if (!prev.wrappedUp && next.wrappedUp) out.push('Wrapped up. Writing your outputs.');
  if (prev.outputs === null && next.outputs !== null) out.push('Your outputs are ready.');
  return out;
}

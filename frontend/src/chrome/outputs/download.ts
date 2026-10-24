import type { Outputs } from '../../protocol/index.ts';

export type DocKind = 'tree' | 'draft' | 'final';
export type FileFormat = 'md' | 'html' | 'docx';

export const DOC_KINDS: readonly DocKind[] = ['tree', 'draft', 'final'];

export const DOC_LABELS: Record<DocKind, string> = {
  tree: 'Decision tree',
  draft: 'Draft',
  final: 'Final',
};

/** The Markdown of one output, as the backend wrote it. */
export function markdownOf(outputs: Outputs, doc: DocKind): string {
  return doc === 'tree' ? outputs.decisionTree : doc === 'draft' ? outputs.draft : outputs.final;
}

/** The same names the backend gives its downloads. */
export function fileName(doc: DocKind, format: FileFormat): string {
  return `${doc === 'tree' ? 'decision-tree' : doc}.${format}`;
}

/** The backend's export route for a live session. */
export function exportUrl(sessionId: string, doc: DocKind, format: FileFormat): string {
  return `/api/sessions/${encodeURIComponent(sessionId)}/export/${doc}/${format}`;
}

const MEDIA_TYPES: Record<FileFormat, string> = {
  md: 'text/markdown;charset=utf-8',
  html: 'text/html;charset=utf-8',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};

/** Hands a blob to the browser as a file download. */
export function saveBlob(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.rel = 'noopener';
  document.body.append(link);
  link.click();
  link.remove();
  // Give the browser a moment to start the download before the address goes away.
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

/** Markdown needs no server: it is the text already on screen. */
export function downloadMarkdown(outputs: Outputs, doc: DocKind): void {
  saveBlob(new Blob([markdownOf(outputs, doc)], { type: MEDIA_TYPES.md }), fileName(doc, 'md'));
}

/**
 * HTML and DOCX come from the backend's export route. Throws with a message
 * fit to show the user when the download fails.
 */
export async function downloadFromServer(sessionId: string, doc: DocKind, format: FileFormat): Promise<void> {
  let response: Response;
  try {
    response = await fetch(exportUrl(sessionId, doc, format));
  } catch {
    throw new Error('Could not reach the server.');
  }
  if (!response.ok) {
    const reason = (await response.text().catch(() => '')).trim().slice(0, 200);
    throw new Error(reason === '' ? `The server answered ${response.status}.` : reason);
  }
  saveBlob(await response.blob(), fileName(doc, format));
}

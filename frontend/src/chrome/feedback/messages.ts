// What the user is told about rejections and server diagnostics. The server's
// own words stay in the developer diagnostics panel; this decides what, if
// anything, appears in a toast, in plain language.
import type { DiagnosticLevel } from '../../protocol/index.ts';

export type Tone = 'info' | 'warning' | 'error';
export interface ToastMessage {
  tone: Tone;
  text: string;
}

/** A rejected command. Null when the user did not ask for it (desk placement). */
export function rejectionMessage(reason: string): ToastMessage | null {
  const r = reason.trim();
  if (/^(Position coordinates|Cannot place)/u.test(r)) return null;
  if (r.startsWith('That candidate is not currently available')) {
    return { tone: 'info', text: 'That word is no longer on offer.' };
  }
  if (r.startsWith('Enter exactly one word') || r.startsWith('Enter a nonempty word')) {
    return { tone: 'info', text: 'Type a single word, without spaces.' };
  }
  if (r.startsWith('The session is wrapped up')) {
    return { tone: 'info', text: 'This session is wrapped up. Start a new one to keep exploring.' };
  }
  if (r.startsWith('The session manager is stopped')) {
    return { tone: 'error', text: 'The server is shutting down. Try again in a moment.' };
  }
  // The rest are short sentences already written for people.
  if (r.length > 0 && r.length <= 120) return { tone: 'info', text: r };
  return { tone: 'error', text: 'That did not work. Please try again.' };
}

/**
 * A server or transport diagnostic. Most are routine (a retried call, a
 * source search that found nothing) and show nothing; the connection has its
 * own status capsule.
 */
export function diagnosticMessage(level: DiagnosticLevel, message: string): ToastMessage | null {
  const m = message.trim();
  if (level === 'info') return null;
  // Connection changes: the status capsule shows them.
  if (/^(Lost the connection|Cannot reach the session|Connected to the session)/u.test(m)) return null;
  if (m.includes('api_key_env') || m.includes('Check the key') || m.includes('Check GEMINI_API_KEY')) {
    return { tone: 'error', text: 'The AI service rejected its API key, so no new words can be made.' };
  }
  if (m.startsWith('Branch generation failed (attempt')) return null;
  if (m.startsWith('Branch generation failed')) {
    return { tone: 'error', text: "Couldn't find new words. Pick the word again to retry." };
  }
  if (m.startsWith('Every generated word was filtered out')) {
    return { tone: 'warning', text: 'No new words came up. Try another word, or move the slider.' };
  }
  if (m.startsWith('Generated branches were not offered') || m.startsWith('Saving the generated branches failed')) {
    return { tone: 'error', text: "Couldn't show the new words. Pick the word again." };
  }
  if (m.startsWith('The final outputs could not be made, trying again')) return null;
  if (m.startsWith('The final outputs could not be made')) {
    // The controls bar offers "Try again".
    return { tone: 'error', text: "Your outputs couldn't be made." };
  }
  if (m.startsWith('Making the outputs without')) {
    return { tone: 'info', text: 'Some notes were still being written, so the outputs were made without them.' };
  }
  if (m.startsWith('Saving')) return { tone: 'error', text: "Something couldn't be saved. Please try again." };
  // Sources and notes fail quietly: exploring goes on without them.
  if (/^(Source|Entry writing|Ignored a server message)/u.test(m)) return null;
  return level === 'error' ? { tone: 'error', text: 'Something went wrong. Please try again.' } : null;
}

/** True for the diagnostic that says the outputs failed for good this time. */
export function isOutputsFailure(message: string): boolean {
  const m = message.trim();
  return m.startsWith('The final outputs could not be made') && !m.startsWith('The final outputs could not be made, trying again');
}

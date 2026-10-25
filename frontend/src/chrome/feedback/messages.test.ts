import { describe, expect, it } from 'vitest';
import { diagnosticMessage, isOutputsFailure, rejectionMessage } from './messages.ts';

describe('rejectionMessage', () => {
  it('keeps short sentences written for people', () => {
    expect(rejectionMessage('That word has already been chosen.')).toEqual({
      tone: 'info',
      text: 'That word has already been chosen.',
    });
  });

  it('rewrites the technical ones', () => {
    expect(rejectionMessage('That candidate is not currently available.')?.text).toBe('That word is no longer on offer.');
    expect(rejectionMessage('Enter exactly one word without internal whitespace.')?.text).toBe(
      'Type a single word, without spaces.',
    );
    expect(rejectionMessage('The session is wrapped up; exploration and curation are closed.')?.text).toContain(
      'Start a new one',
    );
  });

  it('says nothing about desk placement, which the user did not ask for', () => {
    expect(rejectionMessage('Position coordinates and angle must be finite numbers.')).toBeNull();
    expect(rejectionMessage('Cannot place an unknown node.')).toBeNull();
  });

  it('never shows a long raw reason', () => {
    const raw = `internal: ${'x'.repeat(300)}`;
    expect(rejectionMessage(raw)?.text).toBe('That did not work. Please try again.');
  });
});

describe('diagnosticMessage', () => {
  it('stays quiet about routine events', () => {
    expect(diagnosticMessage('info', 'Connected to the session again.')).toBeNull();
    expect(diagnosticMessage('warning', 'Lost the connection to the session; reconnecting.')).toBeNull();
    expect(diagnosticMessage('warning', 'Branch generation failed (attempt 1 of 3), retrying: timeout')).toBeNull();
    expect(diagnosticMessage('warning', 'Source search failed; continuing without new sources.')).toBeNull();
    expect(diagnosticMessage('warning', 'Entry writing failed; using a template.')).toBeNull();
    expect(diagnosticMessage('warning', 'The final outputs could not be made, trying again: boom')).toBeNull();
  });

  it('explains failures the user can act on, without the raw text', () => {
    const final = diagnosticMessage('error', 'Branch generation failed after 3 attempts: HttpExceptionRequest …');
    expect(final).toEqual({ tone: 'error', text: "Couldn't find new words. Pick the word again to retry." });
    expect(diagnosticMessage('error', 'x Check the key in the variable named by api_key_env in DRIFT_CONFIG')?.text).toContain(
      'API key',
    );
    expect(diagnosticMessage('warning', 'Every generated word was filtered out (already chosen…)')?.tone).toBe('warning');
  });

  it('reports an outputs failure, and recognizes it for the retry button', () => {
    const msg = 'The final outputs could not be made: disk on fire Press Wrap up again to retry.';
    expect(diagnosticMessage('error', msg)).toEqual({
      tone: 'error',
      text: "Your outputs couldn't be made.",
    });
    expect(isOutputsFailure(msg)).toBe(true);
    expect(isOutputsFailure('The final outputs could not be made, trying again: x')).toBe(false);
  });

  it('falls back to a generic sentence for unknown errors and to nothing for unknown warnings', () => {
    expect(diagnosticMessage('error', 'Exception: <<loop>>')?.text).toBe('Something went wrong. Please try again.');
    expect(diagnosticMessage('warning', 'some internal note')).toBeNull();
  });
});

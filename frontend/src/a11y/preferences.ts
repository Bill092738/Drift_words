// Accessibility settings chosen in the help popover. They are kept in
// localStorage and applied as attributes on <html>, which the stylesheets and
// the desk theme read:
//   data-contrast="high"   stronger text and borders, no translucency
//   data-text="large"      the type ramp scaled up (--text-scale)
//   data-motion="reduce"   reduced motion, in addition to the system setting
//   data-word-list="on"    the keyboard word list stays visible

export interface Preferences {
  highContrast: boolean;
  largeText: boolean;
  reduceMotion: boolean;
  wordList: boolean;
}

const KEY = 'driftwords.preferences';
const DEFAULTS: Preferences = { highContrast: false, largeText: false, reduceMotion: false, wordList: false };

type Listener = () => void;
const listeners = new Set<Listener>();
let current: Preferences = load();

function storage(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

function load(): Preferences {
  try {
    const raw = storage()?.getItem(KEY);
    if (!raw) return DEFAULTS;
    const parsed = JSON.parse(raw) as Partial<Preferences>;
    return {
      highContrast: parsed.highContrast === true,
      largeText: parsed.largeText === true,
      reduceMotion: parsed.reduceMotion === true,
      wordList: parsed.wordList === true,
    };
  } catch {
    return DEFAULTS;
  }
}

function apply(p: Preferences): void {
  if (typeof document === 'undefined') return;
  const root = document.documentElement;
  const set = (name: string, value: string | null) =>
    value === null ? root.removeAttribute(name) : root.setAttribute(name, value);
  set('data-contrast', p.highContrast ? 'high' : null);
  set('data-text', p.largeText ? 'large' : null);
  set('data-motion', p.reduceMotion ? 'reduce' : null);
  set('data-word-list', p.wordList ? 'on' : null);
}

apply(current);

export function getPreferences(): Preferences {
  return current;
}

export function setPreference<K extends keyof Preferences>(key: K, value: Preferences[K]): void {
  current = { ...current, [key]: value };
  try {
    storage()?.setItem(KEY, JSON.stringify(current));
  } catch {
    // Private mode or a full quota: the setting still applies to this page.
  }
  apply(current);
  listeners.forEach((l) => l());
}

export function subscribePreferences(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

const systemReducedMotion = (): MediaQueryList | null =>
  typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : null;

/** True if the system asks for reduced motion. */
export function systemPrefersReducedMotion(): boolean {
  return systemReducedMotion()?.matches ?? false;
}

/** Reduced motion from either the system or the "Reduce motion" setting. */
export function reducedMotion(): boolean {
  return current.reduceMotion || systemPrefersReducedMotion();
}

/** Calls `onChange` whenever {@link reducedMotion} may have changed. Returns an unsubscribe. */
export function onReducedMotionChange(onChange: () => void): () => void {
  const mql = systemReducedMotion();
  mql?.addEventListener('change', onChange);
  const off = subscribePreferences(onChange);
  return () => {
    mql?.removeEventListener('change', onChange);
    off();
  };
}

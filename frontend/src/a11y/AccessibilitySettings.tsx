import { useId } from 'react';
import { usePreferences } from '../chrome/motion/hooks.ts';
import { icons } from '../chrome/icons.tsx';
import { type Preferences, setPreference, systemPrefersReducedMotion } from './preferences.ts';

interface Row {
  key: keyof Preferences;
  label: string;
  detail: string;
}

const ROWS: readonly Row[] = [
  { key: 'wordList', label: 'Word list', detail: 'Choose words from a list, with the keyboard or a screen reader.' },
  { key: 'highContrast', label: 'High contrast', detail: 'Darker text and borders, no translucency.' },
  { key: 'largeText', label: 'Larger text', detail: 'Text 20% larger, on the desk too.' },
  { key: 'reduceMotion', label: 'Reduce motion', detail: 'Words stop drifting and transitions are instant.' },
];

/** A switch in the style of the system one. */
function Switch({ row, checked, disabled }: { row: Row; checked: boolean; disabled: boolean }) {
  const id = useId();
  return (
    <div className="setting">
      <label className="setting-text" htmlFor={id}>
        <span className="setting-label">{row.label}</span>
        <span className="setting-detail" id={`${id}-detail`}>
          {row.detail}
        </span>
      </label>
      <button
        id={id}
        type="button"
        role="switch"
        className="switch"
        aria-checked={checked}
        aria-describedby={`${id}-detail`}
        disabled={disabled}
        onClick={() => setPreference(row.key, !checked)}
      >
        <span className="switch-thumb" aria-hidden="true" />
      </button>
    </div>
  );
}

/** The accessibility section of the help popover. */
export function AccessibilitySettings() {
  const prefs = usePreferences();
  const systemMotion = systemPrefersReducedMotion();
  return (
    <section aria-labelledby="a11y-heading">
      <h2 id="a11y-heading" className="settings-heading">
        <icons.accessibility size={16} />
        Accessibility
      </h2>
      <div className="settings">
        {ROWS.map((row) => {
          // The system setting wins; the switch shows it and cannot turn it off.
          const fromSystem = row.key === 'reduceMotion' && systemMotion;
          return <Switch key={row.key} row={row} checked={prefs[row.key] || fromSystem} disabled={fromSystem} />;
        })}
      </div>
      {systemMotion && <p className="help-tip">Reduce motion is on in your system settings.</p>}
    </section>
  );
}

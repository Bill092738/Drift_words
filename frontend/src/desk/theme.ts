import { Color } from 'pixi.js';

/** Desk colors, read from the CSS custom properties so canvas and DOM match. */
export interface DeskTheme {
  surface: number;
  fg: number;
  muted: number;
  line: number;
  accent: number;
  shadow: number;
  dark: boolean;
  /** The same font stack as the DOM chrome (`--font`). */
  font: string;
}

const FALLBACK_FONT = '-apple-system, BlinkMacSystemFont, "Inter Variable", "Segoe UI", system-ui, sans-serif';

export function readTheme(): DeskTheme {
  const css = getComputedStyle(document.documentElement);
  const color = (name: string, fallback: string) => new Color(css.getPropertyValue(name).trim() || fallback).toNumber();
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  return {
    font: css.getPropertyValue('--font').trim() || FALLBACK_FONT,
    surface: color('--surface', '#ffffff'),
    fg: color('--fg', '#1d1d1f'),
    muted: color('--muted', '#76767c'),
    line: color('--line', '#e4e2dc'),
    accent: color('--accent', '#3466f0'),
    shadow: 0x000000,
    dark,
  };
}

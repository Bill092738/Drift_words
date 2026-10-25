// Line icons in the spirit of SF Symbols: a 20×20 grid, drawn with currentColor.
// The stroke is scaled so every icon renders a 1.5px line at any size.
import type { ReactNode } from 'react';
import type { SourceKind } from '../protocol/index.ts';

const STROKE_PX = 1.5;

function Icon({ children, size = 20 }: { children: ReactNode; size?: number }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      strokeWidth={(STROKE_PX * 20) / size}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

type IconProps = { size?: number };

const page = <path d="M5 2.5h6.5L15 6v11.5H5z M11.5 2.5V6H15" />;

export const icons = {
  article: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      {page}
      <path d="M7.5 9.5h5M7.5 12h5M7.5 14.5h3" />
    </Icon>
  ),
  paper: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      {page}
      <path d="M7.5 6.5h2M7.5 9h5M7.5 11.25h5M7.5 13.5h5M7.5 15.5h2.5" />
    </Icon>
  ),
  pdf: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      {page}
      <rect x="6.5" y="11" width="7" height="4" rx="1" />
    </Icon>
  ),
  webPage: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      <circle cx="10" cy="10" r="7" />
      <path d="M3 10h14M10 3c2 2.2 2.8 4.6 2.8 7s-.8 4.8-2.8 7c-2-2.2-2.8-4.6-2.8-7S8 5.2 10 3z" />
    </Icon>
  ),
  image: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      <rect x="3" y="4" width="14" height="12" rx="2" />
      <circle cx="7.5" cy="8" r="1.3" />
      <path d="M3.5 14.5l4-4 3 3 2-2 4 3.5" />
    </Icon>
  ),
  audio: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M3.5 8v4h3l4 3.5v-11l-4 3.5z" />
      <path d="M13.5 7.5c.8.7 1.2 1.6 1.2 2.5s-.4 1.8-1.2 2.5M15.5 5.5c1.4 1.2 2 2.8 2 4.5s-.6 3.3-2 4.5" />
    </Icon>
  ),
  /** arrow.up */
  promote: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M10 15.5v-11M5.5 9L10 4.5 14.5 9" />
    </Icon>
  ),
  /** strikethrough: a text line crossed out */
  strike: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M3.5 10h13" />
      <path d="M13.6 6.2C13 5 11.7 4.3 10 4.3c-2 0-3.5 1-3.5 2.6 0 .9.4 1.6 1.2 2.1" />
      <path d="M6.6 13.6c.6 1.3 1.9 2.1 3.6 2.1 2.1 0 3.6-1.1 3.6-2.7 0-.6-.2-1.1-.5-1.5" />
    </Icon>
  ),
  /** arrow.uturn.backward */
  restore: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M7.5 5L4 8.5 7.5 12" />
      <path d="M4.5 8.5h7a4 4 0 0 1 0 8H9" />
    </Icon>
  ),
  notes: ({ size }: IconProps = {}) => (
    <Icon size={size}>
      <rect x="4" y="3" width="12" height="14" rx="2" />
      <path d="M7 7h6M7 10h6M7 13h4" />
    </Icon>
  ),
  chevronRight: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M7.5 4.5L13 10l-5.5 5.5" />
    </Icon>
  ),
  chevronDown: ({ size = 16 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M5 7.5l5 5 5-5" />
    </Icon>
  ),
  external: ({ size = 16 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M11 4h5v5M16 4l-7 7M14 11.5V16H4V6h4.5" />
    </Icon>
  ),
  /** plus */
  plus: ({ size = 16 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M10 4v12M4 10h12" />
    </Icon>
  ),
  /** xmark */
  close: ({ size = 16 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M5 5l10 10M15 5L5 15" />
    </Icon>
  ),
  /** arrow.right, between two words */
  arrowRight: ({ size = 12 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M3.5 10h13M11.5 5l5 5-5 5" />
    </Icon>
  ),
  /** square.and.arrow.down */
  download: ({ size = 16 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M10 3v9.5M6.5 9L10 12.5 13.5 9" />
      <path d="M6.5 7H5.5A1.5 1.5 0 0 0 4 8.5v7A1.5 1.5 0 0 0 5.5 17h9a1.5 1.5 0 0 0 1.5-1.5v-7A1.5 1.5 0 0 0 14.5 7h-1" />
    </Icon>
  ),
  /** info.circle */
  info: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <circle cx="10" cy="10" r="7.25" />
      <path d="M10 9v4.5M10 6.4v.1" />
    </Icon>
  ),
  /** exclamationmark.triangle */
  warning: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M8.7 3.8a1.5 1.5 0 0 1 2.6 0l5.9 10.5a1.5 1.5 0 0 1-1.3 2.2H4.1a1.5 1.5 0 0 1-1.3-2.2z" />
      <path d="M10 8v3.5M10 13.9v.1" />
    </Icon>
  ),
  /** xmark.octagon */
  error: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M7 2.75h6L17.25 7v6L13 17.25H7L2.75 13V7z" />
      <path d="M7.75 7.75l4.5 4.5M12.25 7.75l-4.5 4.5" />
    </Icon>
  ),
  /** questionmark.circle */
  help: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <circle cx="10" cy="10" r="7.25" />
      <path d="M7.9 7.7a2.2 2.2 0 0 1 4.2.8c0 1.5-2.1 1.8-2.1 3.2M10 14.2v.1" />
    </Icon>
  ),
  /** accessibility: a figure in a circle */
  accessibility: ({ size = 18 }: IconProps = {}) => (
    <Icon size={size}>
      <circle cx="10" cy="10" r="7.25" />
      <circle cx="10" cy="6.6" r="0.9" />
      <path d="M6.5 8.6c1.2.4 2.3.6 3.5.6s2.3-.2 3.5-.6M10 9.2v2.6M10 11.8l-1.6 3M10 11.8l1.6 3" />
    </Icon>
  ),
  /** checkmark */
  check: ({ size = 14 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M4.5 10.5l3.5 3.5 7.5-8" />
    </Icon>
  ),
  /** arrow.clockwise, for retry */
  retry: ({ size = 16 }: IconProps = {}) => (
    <Icon size={size}>
      <path d="M15.5 9.5a5.5 5.5 0 1 1-1.6-3.9M15.5 4.5v4h-4" />
    </Icon>
  ),
} as const;

export const sourceKindLabel: Record<SourceKind, string> = {
  article: 'Article',
  paper: 'Paper',
  pdf: 'PDF',
  webPage: 'Web page',
  image: 'Image',
  audio: 'Audio',
};

export function SourceKindIcon({ kind }: { kind: SourceKind }) {
  const Kind = icons[kind];
  return <Kind />;
}

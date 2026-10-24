// Flat line icons, 20×20, drawn with currentColor.
import type { ReactNode } from 'react';
import type { SourceKind } from '../protocol/index.ts';

function Icon({ children, size = 20 }: { children: ReactNode; size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

const page = <path d="M5 2.5h6.5L15 6v11.5H5z M11.5 2.5V6H15" />;

export const icons = {
  article: () => (
    <Icon>
      {page}
      <path d="M7.5 9.5h5M7.5 12h5M7.5 14.5h3" />
    </Icon>
  ),
  paper: () => (
    <Icon>
      {page}
      <path d="M7.5 9h5M7.5 11.25h5M7.5 13.5h5M7.5 15.5h2.5" />
      <circle cx="8" cy="6" r="0.6" fill="currentColor" stroke="none" />
    </Icon>
  ),
  pdf: () => (
    <Icon>
      {page}
      <path d="M7 11.5h6v3.5H7z" />
    </Icon>
  ),
  webPage: () => (
    <Icon>
      <circle cx="10" cy="10" r="7" />
      <path d="M3 10h14M10 3c2 2.2 2.8 4.6 2.8 7s-.8 4.8-2.8 7c-2-2.2-2.8-4.6-2.8-7S8 5.2 10 3z" />
    </Icon>
  ),
  image: () => (
    <Icon>
      <rect x="3" y="4" width="14" height="12" rx="1.5" />
      <circle cx="7.5" cy="8" r="1.3" />
      <path d="M3.5 14.5l4-4 3 3 2-2 4 3.5" />
    </Icon>
  ),
  audio: () => (
    <Icon>
      <path d="M3.5 8v4h3l4 3.5v-11l-4 3.5z" />
      <path d="M13.5 7.5c.8.7 1.2 1.6 1.2 2.5s-.4 1.8-1.2 2.5M15.5 5.5c1.4 1.2 2 2.8 2 4.5s-.6 3.3-2 4.5" />
    </Icon>
  ),
  promote: () => (
    <Icon size={18}>
      <path d="M10 15.5v-11M5.5 9L10 4.5 14.5 9" />
    </Icon>
  ),
  strike: () => (
    <Icon size={18}>
      <path d="M4 10h12M13.5 6.5c-.6-1.2-1.9-2-3.5-2-2 0-3.5 1-3.5 2.5 0 .9.5 1.6 1.4 2M7 13.5c.6 1.3 1.8 2 3.5 2 2.1 0 3.5-1 3.5-2.6" />
    </Icon>
  ),
  restore: () => (
    <Icon size={18}>
      <path d="M4.5 9.5a5.5 5.5 0 1 1 1.6 4.4M4.5 5v4.5H9" />
    </Icon>
  ),
  notes: () => (
    <Icon>
      <rect x="4" y="3" width="12" height="14" rx="1.5" />
      <path d="M7 7h6M7 10h6M7 13h4" />
    </Icon>
  ),
  chevronRight: () => (
    <Icon size={18}>
      <path d="M7.5 4.5L13 10l-5.5 5.5" />
    </Icon>
  ),
  chevronDown: () => (
    <Icon size={16}>
      <path d="M5 7.5l5 5 5-5" />
    </Icon>
  ),
  external: () => (
    <Icon size={16}>
      <path d="M11 4h5v5M16 4l-7 7M14 11.5V16H4V6h4.5" />
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

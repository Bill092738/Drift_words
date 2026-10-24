import { useEffect, useRef, useState, useSyncExternalStore, type PointerEvent, type ReactNode } from 'react';
import { springs } from '../../engine/api.ts';
import { icons } from '../icons.tsx';
import { useSpring } from '../motion/hooks.ts';

const PEEK_PX = 60;
/** How far ahead (seconds) a flick is projected when choosing where to settle. */
const FLICK_PROJECTION_S = 0.18;
const TAP_SLOP_PX = 4;

const Snap = { Peek: 0, Half: 1, Full: 2 } as const;
type Snap = (typeof Snap)[keyof typeof Snap];

function useViewportHeight(): number {
  return useSyncExternalStore(
    (onChange) => {
      window.addEventListener('resize', onChange);
      return () => window.removeEventListener('resize', onChange);
    },
    () => window.innerHeight,
    () => 800,
  );
}

/**
 * Mobile: the sidebar as a bottom sheet with three resting points (peek, half,
 * full). Dragging follows the finger; on release it settles at the snap point
 * nearest to where the flick was heading, keeping the flick's velocity.
 */
export function BottomSheet(props: {
  unseen: number;
  entryCount: number;
  onOpenChange: (open: boolean) => void;
  children: ReactNode;
}) {
  const { onOpenChange } = props;
  const vh = useViewportHeight();
  const sheetHeight = Math.round(vh * 0.92);
  // translateY for each snap point; 0 means fully open.
  const offsets = [sheetHeight - PEEK_PX, sheetHeight - Math.round(vh * 0.5), 0] as const;
  const [snap, setSnap] = useState<Snap>(Snap.Peek);
  const sheet = useRef<HTMLDivElement>(null);
  const drag = useRef<{ startY: number; startOffset: number; samples: [number, number][]; moved: boolean } | null>(null);

  const { spring, kick } = useSpring(
    offsets[snap],
    springs.smooth,
    (y) => {
      if (sheet.current !== null) sheet.current.style.transform = `translateY(${y}px)`;
    },
    0.5,
  );

  useEffect(() => onOpenChange(snap !== Snap.Peek), [snap, onOpenChange]);

  const settle = (index: Snap, velocity: number) => {
    spring.target = offsets[index];
    spring.velocity = velocity;
    kick();
    setSnap(index);
  };

  const onPointerDown = (e: PointerEvent<HTMLDivElement>) => {
    if ((e.target as HTMLElement).closest('button:not(.sheet-handle-button)')) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    drag.current = { startY: e.clientY, startOffset: spring.value, samples: [[e.timeStamp, e.clientY]], moved: false };
  };

  const onPointerMove = (e: PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (d === null) return;
    const dy = e.clientY - d.startY;
    if (Math.abs(dy) > TAP_SLOP_PX) d.moved = true;
    let y = d.startOffset + dy;
    // Rubber-band past the fully open position.
    if (y < 0) y = -Math.sqrt(-y) * 3;
    spring.snap(Math.min(y, offsets[Snap.Peek]));
    kick();
    d.samples.push([e.timeStamp, e.clientY]);
    if (d.samples.length > 5) d.samples.shift();
  };

  const onPointerUp = (e: PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    drag.current = null;
    if (d === null) return;
    if (!d.moved) {
      settle(snap === Snap.Peek ? Snap.Half : Snap.Peek, 0);
      return;
    }
    const [t0, y0] = d.samples[0] ?? [e.timeStamp, e.clientY];
    const dt = (e.timeStamp - t0) / 1000;
    const velocity = dt > 0 ? (e.clientY - y0) / dt : 0;
    const projected = spring.value + velocity * FLICK_PROJECTION_S;
    const nearest = offsets.reduce<Snap>(
      (best, offset, i) => (Math.abs(offset - projected) < Math.abs(offsets[best] - projected) ? (i as Snap) : best),
      Snap.Peek,
    );
    settle(nearest, velocity);
  };

  return (
    <div ref={sheet} className="sheet" style={{ height: sheetHeight }}>
      <div
        className="sheet-handle"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <span className="grabber" aria-hidden="true" />
        <button
          className="sheet-handle-button"
          aria-expanded={snap !== Snap.Peek}
          onClick={(e) => e.preventDefault()}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              settle(snap === Snap.Peek ? Snap.Half : Snap.Peek, 0);
            }
          }}
        >
          <icons.notes />
          <span>Notes</span>
          {props.entryCount > 0 && <span className="tab-count">{props.entryCount}</span>}
          {props.unseen > 0 && <span className="tab-badge" aria-label={`${props.unseen} new`} />}
        </button>
      </div>
      <div className="sheet-body" inert={snap === Snap.Peek}>
        {props.children}
      </div>
    </div>
  );
}

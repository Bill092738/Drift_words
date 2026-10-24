import { useEffect, useRef, useState } from 'react';
import { type Engine, createEngine } from '../engine/index.ts';
import './playground.css';
import { type Tile, createTile } from './tile.ts';

const COUNTS = [50, 500, 2000] as const;
const SYLLABLES = ['dri', 'ft', 'wor', 'ra', 'lo', 'mi', 'san', 'tu', 'ne', 'qua', 'bel', 'ion'];
const CJK = ['漂流', '词语', '海', '光', '记忆'];

/** Small deterministic PRNG so a scene looks the same on every load. */
function mulberry32(seed: number): () => number {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeWord(rand: () => number): string {
  if (rand() < 0.08) return CJK[Math.floor(rand() * CJK.length)]!;
  const n = 1 + Math.floor(rand() * 3);
  let s = '';
  for (let i = 0; i < n; i++) s += SYLLABLES[Math.floor(rand() * SYLLABLES.length)]!;
  return s;
}

/**
 * M3 developer page: a plain scene of placeholder tiles for trying the desk
 * engine. Open it at /playground.
 */
export function Playground() {
  const hostRef = useRef<HTMLDivElement>(null);
  const engineRef = useRef<Engine | null>(null);
  const [count, setCount] = useState<number>(50);
  const [status, setStatus] = useState('starting engine…');
  const [last, setLast] = useState('no intent yet');

  useEffect(() => {
    const host = hostRef.current;
    if (host === null) return;
    let cancelled = false;
    let engine: Engine | null = null;
    let offFrame = (): void => {};
    let offIntent = (): void => {};

    void createEngine(host).then((e) => {
      // StrictMode mounts twice; the first engine may finish after its effect was cleaned up.
      if (cancelled) {
        e.destroy();
        return;
      }
      engine = e;
      engineRef.current = e;

      const rand = mulberry32(7);
      const half = Math.sqrt(count) * 90;
      const tiles = new Map<string, Tile>();
      for (let i = 0; i < count; i++) {
        const id = `w${i}`;
        const tile = createTile(id, makeWord(rand), (rand() * 2 - 1) * half, (rand() * 2 - 1) * half);
        tiles.set(id, tile);
        e.add('words', tile);
      }

      let selected: Tile | undefined;
      offIntent = e.onIntent((intent) => {
        selected?.setSelected(false);
        selected = undefined;
        if (intent.type === 'background') {
          setLast(`background at (${intent.at.x.toFixed(0)}, ${intent.at.y.toFixed(0)})`);
          return;
        }
        selected = tiles.get(intent.id);
        selected?.setSelected(true);
        setLast(`${intent.type} ${intent.id}`);
        if (intent.type === 'select' && selected !== undefined) {
          const b = selected.bounds();
          e.camera.glideTo({ x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2 });
        }
      });

      let acc = 0;
      offFrame = e.onFrame(({ dt }) => {
        acc += dt;
        if (acc < 0.2) return;
        acc = 0;
        const { center, zoom } = e.camera;
        setStatus(
          `${count} tiles · zoom ${zoom.toFixed(2)} · center (${center.x.toFixed(0)}, ${center.y.toFixed(0)})`,
        );
      });
    });

    return () => {
      cancelled = true;
      offFrame();
      offIntent();
      engineRef.current = null;
      engine?.destroy();
    };
  }, [count]);

  return (
    <div className="playground">
      <div className="host" ref={hostRef} />
      <div className="bar">
        <strong>Desk engine playground</strong>
        <label>
          Tiles{' '}
          <select value={count} onChange={(e) => setCount(Number(e.target.value))}>
            {COUNTS.map((n) => (
              <option key={n}>{n}</option>
            ))}
          </select>
        </label>
        <button onClick={() => engineRef.current?.camera.glideTo({ x: 0, y: 0 }, 1)}>
          Reset view
        </button>
        <span className="muted">drag to pan · wheel / pinch to zoom · tap to select</span>
      </div>
      <div className="status">
        {status} · last: {last}
      </div>
    </div>
  );
}

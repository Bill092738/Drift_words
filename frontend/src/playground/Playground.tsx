import { useEffect, useRef, useState } from 'react';
import { type Engine, advanceOrbit, createDrift, createEngine, orbitPoint } from '../engine/index.ts';
import { type BenchmarkResult, describeBenchmark, runBenchmark } from './benchmark.ts';
import './playground.css';
import { SCENES, type SceneKind, generateScene } from './scenes.ts';
import { type Tile, createTile } from './tile.ts';

type RendererChoice = 'auto' | 'webgl';

const initialRenderer = (): RendererChoice =>
  new URLSearchParams(location.search).get('renderer') === 'webgl' ? 'webgl' : 'auto';

/**
 * M3 developer page: scenes of placeholder tiles for trying the desk engine.
 * Open it at /playground. The performance overlay is on; `?renderer=webgl`
 * (or the selector) skips WebGPU to exercise the WebGL path.
 */
export function Playground() {
  const hostRef = useRef<HTMLDivElement>(null);
  const engineRef = useRef<Engine | null>(null);
  const benchmarking = useRef(false);
  const tilesRef = useRef(new Map<string, Tile>());
  const [kind, setKind] = useState<SceneKind>('small');
  const [renderer, setRenderer] = useState<RendererChoice>(initialRenderer);
  const [status, setStatus] = useState('starting engine…');
  const [last, setLast] = useState('no intent yet');
  const [bench, setBench] = useState('');

  useEffect(() => {
    const host = hostRef.current;
    if (host === null) return;
    let cancelled = false;
    let engine: Engine | null = null;
    let offFrame = (): void => {};
    let offIntent = (): void => {};
    const tiles = new Map<string, Tile>();
    tilesRef.current = tiles;

    void createEngine(host, { perfOverlay: true, preferWebGPU: renderer === 'auto' }).then((e) => {
      // StrictMode mounts twice; the first engine may finish after its effect was cleaned up.
      if (cancelled) {
        e.destroy();
        return;
      }
      engine = e;
      engineRef.current = e;

      type Mover = { tile: Tile; update: (time: number, dt: number) => void };
      const movers: Mover[] = [];
      const drift = createDrift({ seed: 11 });
      for (const spec of generateScene(kind)) {
        const moving = spec.motion.kind !== 'static';
        const tile = createTile(e, spec.id, spec.label, spec.x, spec.y, moving);
        tiles.set(spec.id, tile);
        e.add('words', tile);
        const m = spec.motion;
        if (m.kind === 'drift') {
          movers.push({
            tile,
            update: (time) => {
              const o = drift(m.phase, time);
              tile.place(spec.x + o.x, spec.y + o.y);
            },
          });
        } else if (m.kind === 'orbit') {
          let angle = m.angle;
          movers.push({
            tile,
            update: (_time, dt) => {
              angle = advanceOrbit(angle, m.speed, dt);
              const p = orbitPoint(m.center, m.radius, angle);
              tile.place(p.x, p.y);
            },
          });
        }
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
        if (intent.type === 'select' && selected !== undefined && !benchmarking.current) {
          const b = selected.bounds();
          e.camera.glideTo({ x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2 });
        }
      });

      const reducedQuery = matchMedia('(prefers-reduced-motion: reduce)');
      let acc = 0;
      offFrame = e.onFrame(({ time, dt }) => {
        // With reduced motion the desk holds still; drifting and orbiting are decoration.
        if (!reducedQuery.matches) for (const m of movers) m.update(time, dt);
        acc += dt;
        if (acc < 0.2) return;
        acc = 0;
        const { center, zoom } = e.camera;
        const tiers = new Set<number>();
        for (const t of tiles.values()) tiers.add(t.textTier());
        setStatus(
          `${tiles.size} tiles (${movers.length} moving) · zoom ${zoom.toFixed(2)} · center (${center.x.toFixed(0)}, ${center.y.toFixed(0)}) · text tiers [${[...tiers].sort((a, b) => a - b).join(', ')}] · reduced motion ${reducedQuery.matches ? 'on' : 'off'}`,
        );
      });
    });

    return () => {
      cancelled = true;
      offFrame();
      offIntent();
      engineRef.current = null;
      engine?.destroy();
      tiles.clear();
    };
  }, [kind, renderer]);

  const onBenchmark = (): void => {
    const canvas = hostRef.current?.querySelector('canvas');
    const engine = engineRef.current;
    if (!canvas || engine === null || benchmarking.current) return;
    benchmarking.current = true;
    setBench('warming up, then measuring for 10 s…');
    const visibleCount = (): number => {
      const v = engine.camera.viewport;
      let n = 0;
      for (const t of tilesRef.current.values()) {
        const b = t.bounds();
        if (b.minX <= v.maxX && b.maxX >= v.minX && b.minY <= v.maxY && b.maxY >= v.minY) n++;
      }
      return n;
    };
    const motionAnimated = !matchMedia('(prefers-reduced-motion: reduce)').matches;
    void runBenchmark({ canvas, camera: engine.camera, visibleCount, motionAnimated }).then((r: BenchmarkResult) => {
      benchmarking.current = false;
      setBench(describeBenchmark(r));
    });
  };

  return (
    <div className="playground">
      <div className="host" ref={hostRef} />
      <div className="bar">
        <strong>Desk engine playground</strong>
        <label>
          Scene{' '}
          <select value={kind} onChange={(e) => setKind(e.target.value as SceneKind)}>
            {(Object.keys(SCENES) as SceneKind[]).map((k) => (
              <option key={k} value={k}>
                {SCENES[k].label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Renderer{' '}
          <select value={renderer} onChange={(e) => setRenderer(e.target.value as RendererChoice)}>
            <option value="auto">auto (WebGPU first)</option>
            <option value="webgl">WebGL only</option>
          </select>
        </label>
        <button onClick={() => engineRef.current?.camera.glideTo({ x: 0, y: 0 }, 1)}>
          Reset view
        </button>
        <button onClick={onBenchmark}>Run 10 s benchmark</button>
        <span className="muted">drag to pan · wheel / pinch to zoom · tap to select</span>
      </div>
      <div className="status">
        {status} · last: {last}
        {bench !== '' && (
          <>
            <br />
            benchmark: {bench}
          </>
        )}
      </div>
    </div>
  );
}

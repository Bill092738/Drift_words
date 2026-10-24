import type { Camera } from '../engine/index.ts';
import { Samples } from '../engine/perf.ts';

export interface BenchmarkResult {
  seconds: number;
  frames: number;
  fps: number;
  frameAvgMs: number;
  frameP95Ms: number;
  frameMaxMs: number;
  /** Objects on screen, sampled during the run. */
  visibleMin: number;
  visibleAvg: number;
  visibleMax: number;
  /** False when reduced motion froze the moving tiles, so their cost was not measured. */
  motionAnimated: boolean;
  /** False if the page was hidden or unfocused at any point: such numbers say nothing about performance. */
  valid: boolean;
}

/** Unmeasured lead-in: first-time text rasterization and shader compilation land here. */
export const WARMUP_SECONDS = 2;
export const BENCHMARK_SECONDS = 10;
/** The camera is brought back to the scene center this often, so scripted drags cannot wander off into empty space. */
const RECENTER_SECONDS = 1.5;

export interface BenchmarkTarget {
  canvas: HTMLCanvasElement;
  camera: Camera;
  /** How many tiles intersect the viewport right now. */
  visibleCount: () => number;
  motionAnimated: boolean;
}

/**
 * Drives the desk with scripted input: a circular drag with the wheel zooming
 * in and out, then wheel only, then taps, after a short unmeasured warm-up.
 * The input goes through real DOM events, so gesture recognition, camera,
 * culling and hit testing are all in the measured path.
 */
export function runBenchmark(target: BenchmarkTarget): Promise<BenchmarkResult> {
  const { canvas, camera } = target;
  const rect = canvas.getBoundingClientRect();
  const cx = rect.left + rect.width / 2;
  const cy = rect.top + rect.height / 2;
  const radius = Math.min(rect.width, rect.height) / 4;
  const pointer = (type: string, id: number, x: number, y: number): void => {
    canvas.dispatchEvent(
      new PointerEvent(type, { pointerId: id, clientX: x, clientY: y, bubbles: true, pointerType: 'mouse' }),
    );
  };
  const frames = new Samples();
  const visible = new Samples();
  let valid = document.visibilityState === 'visible' && document.hasFocus();
  let dragging = false;
  let start = 0;
  let last = 0;
  let n = 0;
  let nextRecenter = 0;
  let visibleMin = Infinity;

  return new Promise((resolve) => {
    const tick = (now: number): void => {
      if (start === 0) {
        start = now;
        last = now;
      }
      const elapsed = (now - start) / 1000;
      const t = elapsed - WARMUP_SECONDS; // negative during warm-up
      const measuring = t >= 0;
      if (measuring && now !== last) frames.add(now - last);
      last = now;
      if (measuring && (document.visibilityState !== 'visible' || !document.hasFocus())) valid = false;

      // The scripted phases repeat the same pattern in warm-up and measurement.
      const p = measuring ? t : elapsed;
      if (elapsed >= nextRecenter) {
        camera.glideTo({ x: 0, y: 0 });
        nextRecenter = elapsed + RECENTER_SECONDS;
      }
      const angle = (p / 4) * Math.PI * 2;
      const x = cx + Math.cos(angle) * radius;
      const y = cy + Math.sin(angle) * radius;
      const dragPhase = measuring ? p < 4 : elapsed < WARMUP_SECONDS;
      if (dragPhase) {
        if (!dragging) {
          pointer('pointerdown', 99, x, y);
          dragging = true;
        } else {
          pointer('pointermove', 99, x, y);
        }
      } else if (dragging) {
        pointer('pointerup', 99, x, y);
        dragging = false;
      }
      if (measuring && p >= 8 && n % 4 === 0) {
        const tx = rect.left + (0.2 + (0.6 * ((n * 37) % 100)) / 100) * rect.width;
        const ty = rect.top + (0.2 + (0.6 * ((n * 53) % 100)) / 100) * rect.height;
        pointer('pointerdown', 98, tx, ty);
        pointer('pointerup', 98, tx, ty);
      }
      canvas.dispatchEvent(
        new WheelEvent('wheel', {
          deltaY: Math.sin((p / 6) * Math.PI * 2) * 30,
          clientX: cx,
          clientY: cy,
          bubbles: true,
          cancelable: true,
        }),
      );
      if (measuring && n % 10 === 0) {
        const count = target.visibleCount();
        visible.add(count);
        visibleMin = Math.min(visibleMin, count);
      }
      n++;

      if (t >= BENCHMARK_SECONDS) {
        if (dragging) pointer('pointerup', 99, x, y);
        const s = frames.summary();
        const v = visible.summary();
        resolve({
          seconds: t,
          frames: s.count,
          fps: s.count / t,
          frameAvgMs: s.avg,
          frameP95Ms: s.p95,
          frameMaxMs: s.max,
          visibleMin: visibleMin === Infinity ? 0 : visibleMin,
          visibleAvg: v.avg,
          visibleMax: v.max,
          motionAnimated: target.motionAnimated,
          valid,
        });
        return;
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

export function describeBenchmark(r: BenchmarkResult): string {
  const notes: string[] = [];
  if (!r.valid) notes.push('INVALID: page was hidden or unfocused');
  if (!r.motionAnimated) notes.push('reduced motion is on: moving tiles were frozen and NOT stressed');
  if (r.visibleAvg < 1) notes.push('nothing was on screen: result says nothing');
  const head = notes.length > 0 ? `${notes.join(' · ')} · ` : '';
  return `${head}${r.fps.toFixed(1)} fps over ${r.seconds.toFixed(1)} s · frame ${r.frameAvgMs.toFixed(1)} avg / ${r.frameP95Ms.toFixed(1)} p95 / ${r.frameMaxMs.toFixed(1)} max ms · on screen ${r.visibleMin}–${r.visibleMax} (avg ${r.visibleAvg.toFixed(0)})`;
}

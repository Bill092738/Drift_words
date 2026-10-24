import { Samples } from '../engine/perf.ts';

export interface BenchmarkResult {
  seconds: number;
  frames: number;
  fps: number;
  frameAvgMs: number;
  frameP95Ms: number;
  frameMaxMs: number;
  /** False if the page was hidden or unfocused at any point: such numbers say nothing about performance. */
  valid: boolean;
}

export const BENCHMARK_SECONDS = 10;

/**
 * Drives the desk with scripted input for ten seconds, as a user would: a
 * circular drag with the wheel zooming in and out, then wheel only, then taps.
 * The input goes through real DOM events, so gesture recognition, camera,
 * culling and hit testing are all in the measured path.
 */
export function runBenchmark(canvas: HTMLCanvasElement): Promise<BenchmarkResult> {
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
  let valid = document.visibilityState === 'visible' && document.hasFocus();
  let dragging = false;
  let start = 0;
  let last = 0;
  let n = 0;

  return new Promise((resolve) => {
    const tick = (now: number): void => {
      if (start === 0) {
        start = now;
        last = now;
      }
      const t = (now - start) / 1000;
      if (now !== last) frames.add(now - last);
      last = now;
      if (document.visibilityState !== 'visible' || !document.hasFocus()) valid = false;

      const angle = (t / 4) * Math.PI * 2;
      const x = cx + Math.cos(angle) * radius;
      const y = cy + Math.sin(angle) * radius;
      if (t < 4) {
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
      if (t >= 8 && n % 4 === 0) {
        const tx = rect.left + (0.2 + 0.6 * ((n * 37) % 100) / 100) * rect.width;
        const ty = rect.top + (0.2 + 0.6 * ((n * 53) % 100) / 100) * rect.height;
        pointer('pointerdown', 98, tx, ty);
        pointer('pointerup', 98, tx, ty);
      }
      canvas.dispatchEvent(
        new WheelEvent('wheel', {
          deltaY: Math.sin((t / 6) * Math.PI * 2) * 30,
          clientX: cx,
          clientY: cy,
          bubbles: true,
          cancelable: true,
        }),
      );
      n++;

      if (t >= BENCHMARK_SECONDS) {
        const s = frames.summary();
        resolve({
          seconds: t,
          frames: s.count,
          fps: s.count / t,
          frameAvgMs: s.avg,
          frameP95Ms: s.p95,
          frameMaxMs: s.max,
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
  const head = r.valid ? '' : 'INVALID (page was hidden or unfocused) · ';
  return `${head}${r.fps.toFixed(1)} fps over ${r.seconds.toFixed(1)} s · frame ${r.frameAvgMs.toFixed(1)} avg / ${r.frameP95Ms.toFixed(1)} p95 / ${r.frameMaxMs.toFixed(1)} max ms`;
}

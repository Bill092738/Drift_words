import { quality } from './config.ts';

export interface Summary {
  count: number;
  avg: number;
  p95: number;
  max: number;
}

/** Collects samples over a window and summarizes them. */
export class Samples {
  private values: number[] = [];

  add(value: number): void {
    this.values.push(value);
  }

  get count(): number {
    return this.values.length;
  }

  clear(): void {
    this.values.length = 0;
  }

  summary(): Summary {
    const n = this.values.length;
    if (n === 0) return { count: 0, avg: 0, p95: 0, max: 0 };
    const sorted = [...this.values].sort((a, b) => a - b);
    let sum = 0;
    for (const v of sorted) sum += v;
    return {
      count: n,
      avg: sum / n,
      p95: sorted[Math.min(n - 1, Math.ceil(n * 0.95) - 1)]!,
      max: sorted[n - 1]!,
    };
  }
}

export interface PerfSnapshot {
  /** Which renderer is actually in use, for example "webgl2" or "webgpu". */
  renderer: string;
  /** Time between frames, which is what the user sees as smoothness. */
  frame: Summary;
  /** CPU time of the engine's per-frame logic: springs, camera, frame callbacks, culling. */
  logic: Summary;
  /** CPU time between the end of the logic and the end of the frame: Pixi building and submitting the draw. */
  render: Summary;
  visible: number;
  total: number;
  /** Seconds covered by the samples. */
  seconds: number;
}

const ms = (v: number): string => v.toFixed(1);

/** Plain-text view of a snapshot. Draw calls are not shown because Pixi 8 exposes no counter for them. */
export function formatPerf(s: PerfSnapshot): string {
  const fps = s.seconds > 0 ? s.frame.count / s.seconds : 0;
  return [
    `renderer  ${s.renderer}`,
    `fps       ${fps.toFixed(1)}`,
    `frame     ${ms(s.frame.avg)} avg · ${ms(s.frame.p95)} p95 · ${ms(s.frame.max)} max ms`,
    `logic     ${ms(s.logic.avg)} avg · ${ms(s.logic.max)} max ms`,
    `render    ${ms(s.render.avg)} avg · ${ms(s.render.max)} max ms (CPU, not GPU)`,
    `objects   ${s.visible} visible / ${s.total}`,
  ].join('\n');
}

/** A small DOM readout fed once per frame. */
export class PerfOverlay {
  private readonly el: HTMLElement;
  private readonly frame = new Samples();
  private readonly logic = new Samples();
  private readonly render = new Samples();
  private elapsed = 0;
  private readonly renderer: string;

  constructor(host: HTMLElement, renderer: string) {
    this.renderer = renderer;
    if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
    this.el = document.createElement('pre');
    Object.assign(this.el.style, {
      position: 'absolute',
      top: '8px',
      right: '8px',
      margin: '0',
      padding: '6px 8px',
      font: '11px/1.4 ui-monospace, Menlo, Consolas, monospace',
      color: '#e8e8ea',
      background: 'rgba(20, 20, 24, 0.78)',
      borderRadius: '8px',
      pointerEvents: 'none',
      zIndex: '2',
      whiteSpace: 'pre',
    });
    this.el.textContent = `renderer  ${renderer}\nmeasuring…`;
    host.appendChild(this.el);
  }

  record(frameMs: number, logicMs: number, renderMs: number, visible: number, total: number): void {
    this.frame.add(frameMs);
    this.logic.add(logicMs);
    this.render.add(renderMs);
    this.elapsed += frameMs / 1000;
    if (this.elapsed < quality.perfOverlay.refreshSeconds) return;
    this.el.textContent = formatPerf({
      renderer: this.renderer,
      frame: this.frame.summary(),
      logic: this.logic.summary(),
      render: this.render.summary(),
      visible,
      total,
      seconds: this.elapsed,
    });
    this.frame.clear();
    this.logic.clear();
    this.render.clear();
    this.elapsed = 0;
  }

  destroy(): void {
    this.el.remove();
  }
}

import { useEffect, useRef } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { createEngine } from '../engine/index.ts';
import type { SessionStore } from '../store/store.ts';
import { DeskScene } from './DeskScene.ts';
import './desk.css';

/** The weights canvas text uses. */
const DESK_FONT_WEIGHTS = ['500', '600', '700'] as const;
/** Never hold the desk back longer than this for a font. */
const FONT_WAIT_MS = 1500;

/**
 * Resolves once the bundled font is ready for canvas text, which is rasterized
 * once and would otherwise keep the fallback font. Systems with San Francisco
 * do not need it, and a slow or failed load only falls back to the system font.
 */
function deskFontsReady(): Promise<void> {
  if (typeof document === 'undefined' || !('fonts' in document)) return Promise.resolve();
  const loads = DESK_FONT_WEIGHTS.map((w) => document.fonts.load(`${w} 15px "Inter Variable"`));
  const timeout = new Promise<void>((resolve) => setTimeout(resolve, FONT_WAIT_MS));
  return Promise.race([Promise.allSettled(loads).then(() => undefined), timeout]);
}

/** The infinite desk: a canvas engine with the word tree scene on top. */
export function Desk({ store, onScene }: { store: StoreApi<SessionStore>; onScene?: (scene: DeskScene | null) => void }) {
  const host = useRef<HTMLDivElement>(null);
  // Kept in a ref so a new callback does not rebuild the scene.
  const sceneCallback = useRef(onScene);
  sceneCallback.current = onScene;

  useEffect(() => {
    const el = host.current;
    if (el === null) return;
    let disposed = false;
    let cleanup = () => {};
    void deskFontsReady()
      .then(() => (disposed ? null : createEngine(el)))
      .then((engine) => {
        if (engine === null) return;
        if (disposed) {
          engine.destroy();
          return;
        }
        const scene = new DeskScene(engine, store);
        // ?debug=1 exposes the scene for end-to-end tests.
        if (new URLSearchParams(location.search).has('debug')) {
          (window as unknown as { __desk?: unknown }).__desk = scene;
        }
        sceneCallback.current?.(scene);
        cleanup = () => {
          sceneCallback.current?.(null);
          scene.destroy();
          engine.destroy();
        };
      });
    return () => {
      disposed = true;
      cleanup();
    };
  }, [store]);

  return <div ref={host} className="desk" aria-label="Desk" />;
}

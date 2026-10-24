import { useEffect, useRef } from 'react';
import type { StoreApi } from 'zustand/vanilla';
import { createEngine } from '../engine/index.ts';
import type { SessionStore } from '../store/store.ts';
import { DeskScene } from './DeskScene.ts';
import './desk.css';

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
    void createEngine(el).then((engine) => {
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

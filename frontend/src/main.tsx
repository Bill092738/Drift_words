import { StrictMode, Suspense, lazy } from 'react';
import { createRoot } from 'react-dom/client';
import { EventLogView } from './dev/EventLogView.tsx';
import './styles.css';

// Loaded on demand so Pixi stays out of the initial bundle.
const Playground = lazy(() =>
  import('./playground/Playground.tsx').then((m) => ({ default: m.Playground })),
);

const root = document.getElementById('root');
if (root === null) throw new Error('missing #root');

createRoot(root).render(
  <StrictMode>
    {location.pathname.startsWith('/playground') ? (
      <Suspense fallback={null}>
        <Playground />
      </Suspense>
    ) : (
      <EventLogView />
    )}
  </StrictMode>,
);

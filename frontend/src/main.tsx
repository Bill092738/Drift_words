import { StrictMode, Suspense, lazy } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import { EventLogView } from './dev/EventLogView.tsx';
import './styles.css';

// Loaded on demand so Pixi stays out of the initial bundle.
const Playground = lazy(() =>
  import('./playground/Playground.tsx').then((m) => ({ default: m.Playground })),
);

const root = document.getElementById('root');
if (root === null) throw new Error('missing #root');

const view = new URLSearchParams(location.search).get('view');

function Page() {
  if (location.pathname.startsWith('/playground')) {
    return (
      <Suspense fallback={null}>
        <Playground />
      </Suspense>
    );
  }
  return view === 'log' ? <EventLogView /> : <App />;
}

createRoot(root).render(
  <StrictMode>
    <Page />
  </StrictMode>,
);

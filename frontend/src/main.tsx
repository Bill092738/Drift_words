import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { EventLogView } from './dev/EventLogView.tsx';
import './styles.css';

const root = document.getElementById('root');
if (root === null) throw new Error('missing #root');

createRoot(root).render(
  <StrictMode>
    <EventLogView />
  </StrictMode>,
);

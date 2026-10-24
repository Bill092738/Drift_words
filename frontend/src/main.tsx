import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import { EventLogView } from './dev/EventLogView.tsx';
import './styles.css';

const root = document.getElementById('root');
if (root === null) throw new Error('missing #root');

const view = new URLSearchParams(location.search).get('view');

createRoot(root).render(<StrictMode>{view === 'log' ? <EventLogView /> : <App />}</StrictMode>);

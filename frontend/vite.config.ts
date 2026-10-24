import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [react()],
  server: {
    // Fixtures live in ../protocol, outside the Vite root.
    fs: { allow: ['..'] },
    proxy: {
      '/api': { target: 'http://localhost:8080', ws: true },
    },
  },
  build: {
    // PixiJS alone is ~170 KB gzipped; the budget is 350 KB gzipped for initial JS (TECH_ROADMAP 5.8).
    chunkSizeWarningLimit: 700,
  },
  test: {
    environment: 'node',
  },
});

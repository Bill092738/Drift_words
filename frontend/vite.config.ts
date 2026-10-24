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
  test: {
    environment: 'node',
  },
});

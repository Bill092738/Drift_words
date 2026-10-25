/**
 * Developer mode: the Vite dev server (`make dev`), or any page opened with
 * `?dev`. It shows the session-source toolbar, the diagnostics panel, the
 * event log link and raw error text. Everyone else sees only the product.
 */
export const devMode: boolean =
  import.meta.env.DEV || (typeof location !== 'undefined' && new URLSearchParams(location.search).has('dev'));

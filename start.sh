#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

error() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

command -v cabal >/dev/null 2>&1 || error "cabal was not found on PATH. Install GHC/cabal and reopen this terminal."
command -v node >/dev/null 2>&1 || error "node was not found on PATH. Install Node.js and reopen this terminal."
command -v pnpm >/dev/null 2>&1 || error "pnpm was not found on PATH. Install Node.js and pnpm, then reopen this terminal."

[[ -d "$ROOT_DIR/backend" ]] || error "backend directory is missing from $ROOT_DIR."
[[ -f "$ROOT_DIR/backend/cabal.project" ]] || error "backend/cabal.project is missing."
[[ -d "$ROOT_DIR/frontend" ]] || error "frontend directory is missing from $ROOT_DIR."
[[ -f "$ROOT_DIR/frontend/package.json" ]] || error "frontend/package.json is missing."

cleanup() {
  [[ -n "${BACKEND_PID:-}" ]] && kill "$BACKEND_PID" 2>/dev/null || true
  [[ -n "${FRONTEND_PID:-}" ]] && kill "$FRONTEND_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

printf 'Starting Driftwords backend on http://localhost:8080 ...\n'
(cd "$ROOT_DIR/backend" && cabal run drift-server) &
BACKEND_PID=$!

printf 'Starting Driftwords frontend on http://localhost:5173 ...\n'
(cd "$ROOT_DIR/frontend" && pnpm dev) &
FRONTEND_PID=$!

printf 'Both services are running. Press Ctrl+C to stop them.\n'
wait -n "$BACKEND_PID" "$FRONTEND_PID"
STATUS=$?

if [[ "$STATUS" -ne 0 ]]; then
  printf 'Error: one of the services stopped with exit code %s.\n' "$STATUS" >&2
fi

exit "$STATUS"
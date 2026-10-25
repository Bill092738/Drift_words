# Common tasks. Run from the repository root.
#
#   make protocol   regenerate TypeScript types and fixtures after changing Protocol.hs
#   make check      everything CI runs: build, tests, typecheck, frontend build
#   make server     run the backend on :8080
#   make dev        run the frontend dev server (proxies /api to :8080)
#   make app        build the frontend and serve the whole app from the backend on :8080
#   make demo       Gemini cloud/rings/embeddings/notes/final (needs GEMINI_API_KEY)

# Local settings such as GEMINI_API_KEY (see .env.example). Plain KEY=value lines.
-include .env
export

.PHONY: protocol check backend-build backend-test backend-restart-test frontend-install frontend-check server dev app demo

protocol:
	cd backend && cabal run -v0 drift-gen-ts -- ../frontend/src/protocol/generated.ts
	cd frontend && pnpm fixtures

backend-build:
	cd backend && cabal build all

backend-test: backend-build
	cd backend && cabal test all --test-show-details=direct

backend-restart-test: backend-build
	cd backend && cabal test drift-test --test-options='--match "server process restart" --format=progress'

frontend-install:
	cd frontend && pnpm install

frontend-check:
	cd frontend && pnpm typecheck && pnpm test && pnpm build

check: backend-build backend-test frontend-check

server:
	cd backend && cabal run drift-server

dev:
	cd frontend && pnpm dev

app:
	cd frontend && pnpm build
	cd backend && cabal run drift-server

demo:
	@test -n "$$GEMINI_API_KEY" || { echo "Set GEMINI_API_KEY first (in .env or your shell; never commit it)."; exit 1; }
	cd frontend && pnpm build
	@echo "Open http://localhost:8080/?live"
	cd backend && DRIFT_CONFIG=config.gemini.yaml cabal run drift-server

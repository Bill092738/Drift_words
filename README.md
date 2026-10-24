# Driftwords

**A thinking workbench where you explore by choosing, not chatting.**

Driftwords is a browser-based tool for the moments when you want to do something but don't know what, or have a vague direction you can't untangle. Instead of a blank prompt, you get an infinite desk of drifting words. You pick the one that interests you most, it grows a ring of related words, and you pick again. Your path becomes a tree, sources quietly land on the desk behind the words they explain, and a sidebar turns the path into structured, cited notes. When you're done, you leave with a decision tree, a full draft, and a final document.

Language models and web search run in the background. You never talk to an AI.

> **Status:** M1 to M5 are in place: the frontend runs a live session against the backend, with model-generated rings when a model is configured. M6 source search and the M7 writing pipeline are implemented as libraries and in the UI, but the live server does not run them yet. M8 is in: "Wrap up" ends a session, the server builds the decision tree, draft and final document (`Drift.Output.*`) and sends them as `OutputsReady`, the outputs view shows them, and downloads are Markdown, HTML and Word (`GET /api/sessions/:id/export/{tree,draft,final}/{md,html,docx}`). Because the live server writes no entries or sources yet, a live session's draft and final document are empty until M6 and M7 are wired in; the decision tree is complete. "Driftwords" is a working title.

## Documents

| Document | Contents |
| --- | --- |
| [idea.md](idea.md) | Product concept: design principles, interaction, data structures, open questions |
| [TECH_ROADMAP.md](TECH_ROADMAP.md) | Architecture, frontend/backend contract, and parallel milestones |

## Architecture at a glance

| Layer | Technology |
| --- | --- |
| Desk rendering | TypeScript, PixiJS v8 (WebGPU with WebGL2 fallback), spring-based motion system |
| UI chrome | React 19 (sidebar, controls, outputs) |
| Backend | Haskell: Servant/Warp, STM, event-sourced domain stored as a persistent linked list |
| AI | A model-agnostic provider slot (any OpenAI-compatible endpoint, local or hosted), with speculative prefetch and embedding-based divergence |
| Sources and citations | Wikipedia, Wikimedia Commons, OpenAlex, Crossref, arXiv; references rendered by `citeproc`; export with `pandoc` |
| Persistence | SQLite event log (save, resume, replay) |

See [TECH_ROADMAP.md](TECH_ROADMAP.md) for the reasoning behind each choice.

## Repository layout

```
protocol/   shared command/event contract and fixtures
backend/    Haskell server, domain, AI pipelines, outputs
frontend/   TypeScript client: desk engine, desk content, UI chrome
```

## Development

The expected toolchain:

- GHC 9.10 and cabal 3.16 (via [ghcup](https://www.haskell.org/ghcup/))
- Node.js 24 LTS and pnpm
- Optional: a local model server with an OpenAI-compatible API (for example Ollama or llama.cpp). Without one, the backend runs on its built-in mock provider.

The frontend can be developed without the backend through its mock transport.

### Run the backend

From the repository root, run `make backend-build` and then `make server`. The server listens on port `8080` and stores session events in `backend/drift.sqlite` by default because `make server` starts it from `backend/`. Set `DRIFT_PORT` to choose another port and `DRIFT_DB_PATH` to choose another SQLite file. Relative database paths are resolved from the server's current working directory.

Create a session with `POST /api/sessions` and JSON body `{"lang":"en"}`. The frontend always creates English sessions; Chinese is out of scope for now. The response is `{"sessionId":"..."}`. Connect the client to `/api/sessions/<sessionId>/ws`. `/api/health` returns plain-text `ok`.

By default the backend uses a deterministic offline vocabulary: a fixed initial word cloud and six branch words, each with the selected node ID appended, so sessions can continue at any depth without a model.

To generate rings with a model, set `DRIFT_CONFIG` to a model configuration (see `backend/config.example.yaml`). Its `branches` role generates the rings, and its optional `embeddings` role drives divergence selection. After each ring, the server prefetches the ring of every offered word, so a pick usually finds its ring ready; set `DRIFT_PREFETCH=0` to save model calls. For example: `DRIFT_CONFIG=config.packycode.yaml PACKYCODE_API_KEY=... make server`. The initial word cloud stays fixed for now.

### Run the whole app

`make app` builds the frontend and starts the server, which also serves the built frontend at `http://localhost:8080/` (set `DRIFT_STATIC_DIR` to serve another build). Choose **Live (backend)** in the toolbar, or open `/?live`. The session id is kept in the URL (`?session=...`), so reloading the page restores the same desk, and the page reconnects on its own if the server restarts. With `make dev` instead, the Vite dev server on :5173 proxies `/api` to the backend on :8080.

Run backend tests from `backend/` with `cabal build drift-server && cabal test drift-test --test-show-details=direct`. The real child-process persistence test can be run from the repository root with `make backend-restart-test`; it builds the server, resolves the executable with `cabal list-bin drift-server`, and launches three server processes against one temporary database. Run `make check` for backend build/tests and frontend checks.

Build notes, verified on Ubuntu 26.04 with GHC 9.10.3:

- `cabal.project` needs `constraints: zlib +bundled-c-zlib, string-interpolate < 1`. The first builds zlib from bundled C sources, so `zlib1g-dev` is not required. The second works around an `aeson-typescript` build failure with `string-interpolate` 1.0.
- GHC links against `libgmp`, `libffi` and `libtinfo`, so install `libgmp-dev libffi-dev libncurses-dev`. Without sudo, symlinks to the runtime libraries (for example `libgmp.so -> libgmp.so.10`) in a directory on `LIBRARY_PATH` work as a substitute.

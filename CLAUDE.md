# Driftwords: guide for AI agents and teammates

Read [idea.md](idea.md) for what we are building and [TECH_ROADMAP.md](TECH_ROADMAP.md) for how. Section 7 of the roadmap lists the milestones and which track owns each.

## Ground rules

- **Everything in the repository is in English**: code, comments, docs, commit messages.
- **The protocol is contract-first.** `backend/src/Drift/Protocol.hs` is the source of truth. Never hand-edit `frontend/src/protocol/generated.ts` or `protocol/fixtures/*.jsonl`. Follow [protocol/README.md](protocol/README.md) to change them.
- **The frontend must always run without the backend**, on `MockTransport` and the fixtures.
- **Commit small and often, with clear messages.** Judges evaluate what was built during the event, so the git history is evidence.

## Local references (not in git)

`references/` is gitignored and exists only on the workstation. It holds the HackOHI/O 2026 participant guidebook and the judging guide, as PDFs with `.txt` extracts for easy reading. Key points:

- Hacking ends at **10:00 AM on Sunday, Oct 25, 2026**. The submission is a 3-minute MP4 video (max 500 MB) covering team name, project name, concept, execution, and technical challenges and how we overcame them.
- Judging is 3 minutes of video plus 6 minutes of Q&A. Each criterion is scored 1 to 5: Innovation, Curiosity, Communication, Project Breadth & Complexity, Impact, Challenge Navigation.
- We are in the Open Track and aiming for the "Most Technical" superlative.

## Running the frontend without a backend

`make dev` opens the app on an interactive in-browser mock session (`frontend/src/transport/mockServer.ts`). It answers every command with streamed branch words and placeholder notes and sources. The toolbar can switch to replaying a protocol fixture instead. The toolbar's **Live (backend)** mode (or `?live`) creates a session on drift-server instead and keeps its id in the URL (`?session=...`), so a reload resumes it. `?view=log` shows the raw event log, and `?debug=1` exposes `window.__desk.debugTiles()` and `window.__desk.debugSources()` (every word tile and source object with its screen position) for end-to-end tests.

The wrap-up outputs: pressing **Wrap up** (it asks twice) sends `WrapUp`; the session actor then builds the decision tree, the draft and the final document in a worker (`backend/src/Drift/Output/`, injected into the actor with `newManagerWithOutputs`) and commits them as `OutputsReady`. The mock server emits a stand-in `OutputsReady` (`frontend/src/transport/mockOutputs.ts`). The final document uses the config's optional `final` model role and falls back to the kept entries' own text without it. `GET /api/sessions/:id/export/{tree,draft,final}/{md,html,docx}` serves downloads.

The desk runs on the M3 engine (`frontend/src/engine/`, behind `engine/api.ts`). Its playground is at `/playground`. The engine reads a drawable's `moving` flag once, when it is added: static drawables go into a spatial index and must call `engine.moved(id)` whenever their bounds change, or they are culled and hit-tested at their old place.

## Commands

| Task | Command |
| --- | --- |
| Everything CI runs | `make check` |
| Regenerate TS types and fixtures | `make protocol` |
| Backend server on :8080 | `make server` (offline vocabulary; set `DRIFT_CONFIG` for a model) |
| Whole app from the backend on :8080 | `make app`, then open `/?live` |
| The demo, with Gemini behind every model role | `GEMINI_API_KEY=... make demo`, then open `/?live` |
| Frontend dev server (proxies `/api` to :8080) | `make dev` |
| Backend tests only | `cd backend && cabal test` |
| Frontend tests only | `cd frontend && pnpm test` |

## Workstation notes

- The toolchain is installed per user, without sudo: GHC 9.10.3 and cabal via ghcup, and Node 24 with pnpm in `~/.local`.
- The system `-dev` packages are missing, so GHC links through symlinks in `~/.local/lib/devlinks`. `~/.bashrc` exports `LIBRARY_PATH` for this. In a non-interactive shell, run `source ~/.ghcup/env` and `export LIBRARY_PATH=$HOME/.local/lib/devlinks` before using cabal.
- Ollama is installed in `~/.local/opt/ollama` (binary only, no model pulled yet). It detects the RTX 4060 through CUDA.

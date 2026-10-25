# Driftwords

**A thinking workbench where you explore by choosing, not chatting.**

Driftwords is a browser-based tool for the moments when you want to do something but don't know what, or have a vague direction you can't untangle. Instead of a blank prompt, you get an infinite desk of drifting words. You pick the one that interests you most, it grows a ring of related words, and you pick again. Your path becomes a tree, sources quietly land on the desk behind the words they explain, and a sidebar turns the path into structured, cited notes. When you're done, you leave with a decision tree, a full draft, and a final document.

Language models and web search run in the background. You never talk to an AI.

> **Status:** M1 to M8 are integrated. Gemini can generate the cloud, rings, embeddings and the final rewrite. Sources come from Wikipedia, OpenAlex (papers and open-access PDFs) and Wikimedia Commons (images and audio), with a different mix of kinds for each edge; search is on by default (`DRIFT_SOURCES=0` turns it off). M7 writes a persistent template note for every non-root edge, and M8 turns the tree, notes and citations into a decision tree, draft and final document with Markdown, HTML and Word downloads. Gemini note writing and model-backed relevance remain follow-ups; see [docs/todo/REMAINING.md](docs/todo/REMAINING.md). "Driftwords" is a working title.

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
| Sources and citations | Live English MVP: Wikipedia and OpenAlex with retrieved CSL metadata and heuristic relevance. Wikimedia Commons, Crossref, arXiv and model-backed relevance are planned; `citeproc`/`pandoc` belong to the output roadmap |
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

Each non-root edge also gets one deterministic note, `fromWord → toWord`, with an empty explanation. Notes arrive quietly: the sidebar stays closed until opened. Promote, strike and restore are persisted. `DRIFT_WRITING=0` explicitly disables note production, including recovery of missing notes after restart; otherwise the template writer runs independently of `DRIFT_CONFIG`. A `writing` role does not enable model writing in this server. The provider-independent `EntryWriter` seam is ready for the separate Gemini integration.

Source search is on by default: every non-root edge searches Wikipedia and OpenAlex. It needs no model configuration and no key; set `OPENALEX_API_KEY` to raise the OpenAlex daily budget, and `DRIFT_SOURCES=0` to turn search off (for example with no network). The server shares one HTTP cache and rate-limit environment, runs at most two edge searches with sixteen pending jobs, and skips the newest search with a warning when that queue is full. Its note is still written. Writing waits for search completion or 250ms, whichever comes first; later sources revise the note's citations. Search failures or zero results are normal and do not stop exploration. See [source behavior and limits](backend/sources/README.md).

The frontend creates English sessions. Retrieval currently uses an English word-overlap heuristic, not semantic or model judgement. Crossref search, arXiv search, Commons retrieval, Chinese retrieval, model-backed relevance and Gemini writing/quality acceptance are deferred. Fixture references to those providers are recorded UI test data, not evidence of live provider support.

For an offline session, leave `DRIFT_CONFIG` unset and set `DRIFT_SOURCES=0`; leave `DRIFT_WRITING` unset to keep template notes. The tests always start the server with `DRIFT_SOURCES=0`, so CI never calls the source APIs. Startup reports modes and whether an OpenAlex key is present, never the key value. HTTP diagnostics redact `api_key` values.

To generate rings with a model, set `DRIFT_CONFIG` to a model configuration (see `backend/config.gemini.yaml` and `backend/config.example.yaml`). Its `branches` role generates the rings, and its optional `embeddings` role drives divergence selection. After each ring, the server prefetches the ring of every offered word, so a pick usually finds its ring ready; set `DRIFT_PREFETCH=0` to save model calls. An optional `cloud` role makes each session's starting cloud; without it the cloud is the fixed offline list.

### Run on Gemini (the demo setup)

Gemini is the model behind the demo. Export your key, then run `make demo`:

```
export GEMINI_API_KEY=...   # in your shell only; never put it in a file in the repo
make demo                   # builds the frontend, starts drift-server with config.gemini.yaml
```

Open `http://localhost:8080/?live`. `backend/config.gemini.yaml` routes the roles like this:

| Role | Model | Why |
| --- | --- | --- |
| `branches`, `cloud` | `gemini-3.1-flash-lite` | about 1.4 s per answer; rings and the cloud are on the critical path |
| `writing` | `gemini-3.8-flash` | configured for future integration; current notes are deterministic templates |
| `final` | `gemini-3.8-flash` | rewrites the M8 final document; falls back to kept note text on failure |
| `embeddings` | `gemini-embedding-001` | divergence band; about 0.5 s per ring |

To put 3.8 Flash behind the rings too, set `branches: gemini` in that file. Expect a 4 to 10 s wait whenever a pick misses the prefetch (the first pick, a backtrack, a typed word).

`kind: gemini` in a model configuration is Gemini's OpenAI-compatible endpoint with the settings Gemini 3 needs: `reasoning_effort: low` (Gemini 3 cannot stop thinking, and 3.8 Flash rejects `minimal`), no `temperature`, no output-token limit (Gemini counts thinking tokens against it, so a small limit returns an empty answer), and parallel prefetch. Every provider accepts these as options: `reasoning_effort`, `send_temperature`, `limit_output_tokens`, `timeout_seconds` and `concurrent_requests`.

Prefetch makes about 12 extra requests per pick (6 rings and 6 embedding calls), so a pick usually finds its ring ready (60 to 150 ms in testing, against about 1.5 s for a miss). Set `DRIFT_PREFETCH=0` to save quota.

### Run the whole app

`make app` builds the frontend and starts the server, which also serves the built frontend at `http://localhost:8080/` (set `DRIFT_STATIC_DIR` to serve another build). Choose **Live (backend)** in the toolbar, or open `/?live`. The session id is kept in the URL (`?session=...`), so reloading the page restores the same desk, and the page reconnects on its own if the server restarts. With `make dev` instead, the Vite dev server on :5173 proxies `/api` to the backend on :8080.

For local development with both processes running separately, use `./start.sh` on Linux/macOS or double-click `start.cmd` on Windows. Each launcher checks that `cabal`, `pnpm`, and the expected project files are available before starting the backend and frontend. The Windows launcher opens one Command Prompt window per service.

Run backend tests from `backend/` with `cabal build drift-server && cabal test drift-test --test-show-details=direct`. The real child-process persistence test can be run from the repository root with `make backend-restart-test`; it builds the server, resolves the executable with `cabal list-bin drift-server`, and launches three server processes against one temporary database. Run `make check` for backend build/tests and frontend checks.

M6/M7 verification uses no model provider or real source API: saved-response source specs, injected source/writer actor tests, and a fake-source child-process integration test cover admission, citations, bounded work, persistence and WebSocket delivery. Browser acceptance covers live template notes and curation through reload and real backend restart; recorded fixtures cover references, locating/focusing sources, mobile sheets, long prose and reduced motion. Regenerate contracts with `make protocol` and require no semantic diff. The opt-in `DRIFT_LIVE_TESTS=1` source smoke is separate and non-gating. These checks establish behavior, not model quality or real-provider availability. See the [M6/M7 live design](docs/superpowers/specs/2026-10-24-m6-m7-live-design.md); the completion records are in the git history.

Build notes, verified on Ubuntu 26.04 with GHC 9.10.3:

- `cabal.project` needs `constraints: zlib +bundled-c-zlib, string-interpolate < 1`. The first builds zlib from bundled C sources, so `zlib1g-dev` is not required. The second works around an `aeson-typescript` build failure with `string-interpolate` 1.0.
- GHC links against `libgmp`, `libffi` and `libtinfo`, so install `libgmp-dev libffi-dev libncurses-dev`. Without sudo, symlinks to the runtime libraries (for example `libgmp.so -> libgmp.so.10`) in a directory on `LIBRARY_PATH` work as a substitute.

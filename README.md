# Driftwords

**A thinking workbench where you explore by choosing, not chatting.**

Driftwords is a browser-based tool for the moments when you want to do something but don't know what, or have a vague direction you can't untangle. Instead of a blank prompt, you get an infinite desk of drifting words. You pick the one that interests you most, it grows a ring of related words, and you pick again. Your path becomes a tree, sources quietly land on the desk behind the words they explain, and a sidebar turns the path into structured, cited notes. When you're done, you leave with a decision tree, a full draft, and a final document.

Language models and web search run in the background. You never talk to an AI.

> **Status:** planning. The concept and technical plan are written; no runnable code yet. "Driftwords" is a working title.

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

## Repository layout (planned)

```
protocol/   shared command/event contract and fixtures
backend/    Haskell server, domain, AI pipelines, outputs
frontend/   TypeScript client: desk engine, desk content, UI chrome
```

## Development (planned)

Setup instructions will land with milestone M0. The expected toolchain:

- GHC 9.10 and cabal 3.16 (via [ghcup](https://www.haskell.org/ghcup/))
- Node.js 24 LTS and pnpm
- Optional: a local model server with an OpenAI-compatible API (for example Ollama or llama.cpp). Without one, the backend runs on its built-in mock provider.

The frontend can be developed without the backend through its mock transport.

Build notes, verified on Ubuntu 26.04 with GHC 9.10.3:

- `cabal.project` needs `constraints: zlib +bundled-c-zlib, string-interpolate < 1`. The first builds zlib from bundled C sources, so `zlib1g-dev` is not required. The second works around an `aeson-typescript` build failure with `string-interpolate` 1.0.
- GHC links against `libgmp`, `libffi` and `libtinfo`, so install `libgmp-dev libffi-dev libncurses-dev`. Without sudo, symlinks to the runtime libraries (for example `libgmp.so -> libgmp.so.10`) in a directory on `LIBRARY_PATH` work as a substitute.

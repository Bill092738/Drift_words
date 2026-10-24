# M6/M7 Live Completion Design

## Intent

Finish M6 and M7 as live, persistent parts of Driftwords rather than fixture-only components. During a normal session, sources must land asynchronously and sidebar entries must appear without delaying exploration. Curation and placements must survive reloads and server restarts.

The Gemini integration is being developed elsewhere. This work must not depend on any usable model provider. It must provide a deterministic template writer now and leave a provider-independent seam for Gemini later.

## Goals

- Run the existing Wikipedia/OpenAlex source pipeline for live sessions when explicitly enabled.
- Generate one persistent sidebar entry per non-root edge with no model provider, using the existing `fromWord → toWord` fallback form.
- Keep source search and entry writing off the latency-critical pick path.
- Reconcile sources with entries regardless of arrival order.
- Allocate `SourceId` and `EntryId` in the serialized session actor and continue correctly after replay.
- Preserve curation, entries, citations, sources, and placements across reload and restart.
- Bound background work, clean it up on shutdown, and reject late writes after wrap-up.
- Keep CI and offline mode free of real network and model calls.
- Preserve a future seam for Gemini without changing actor, persistence, protocol, or frontend behavior.

## Non-goals

- Crossref search, arXiv search, Wikimedia Commons, general web search, or Chinese retrieval quality.
- Model-backed relevance judgement.
- Gemini provider implementation or model-quality acceptance.
- M8 wrap-up draining and output assembly.
- Claiming the full provider list in `TECH_ROADMAP.md` is complete; this delivery is the M6 live English MVP plus M7 live completion.

## Anti-goals

- Never block a pick, backtrack, or branch ring on source or writing work.
- Never let a background exception terminate a session actor.
- Never log API keys, including keys embedded in failed request query strings.
- Never let a worker assign durable IDs or broadcast before persistence succeeds.
- Never make the actor aware of Gemini or another concrete provider.

## Constraints

- Baseline is `origin/main` at `fbeb5e06041062d1fc74cc6855f0bad71dd50326`.
- GHC 9.10.3 and the existing Cabal/React/TypeScript stacks remain in use.
- The Windows baseline cannot archive the separate `drift-sources` package from a path containing spaces; folding it into `drift` is both an architecture prerequisite and the verified environmental fix.
- Sources are opt-in with `DRIFT_SOURCES=1`. Without it, no source HTTP request may occur.
- Template entries are the default live writing mode when no model writer is configured. An explicit switch may disable writing for deterministic legacy tests.
- Tests use fake source search and deterministic writers. Real providers are manual smoke tests only.

## Approaches Considered

### A. Wire the existing source and writing modules now

This closes the live-session gap quickly using Wikipedia/OpenAlex and the existing writing pipeline. By itself it underspecifies dependency direction, concurrency, no-model behavior, and citation races.

### B. Finish every roadmap provider and semantic relevance first

This adds Crossref, arXiv and model relevance before live wiring. It delays the core value, expands rate-limit/parser work, and cannot validate semantic relevance while no model provider is available.

### C. Follow `docs/m6-m7-todo` exactly

The TODO branch has the strongest actor/admission/test skeleton. Its original M7 behavior disables entries when no writing role exists, so it cannot meet the no-provider requirement. Its scheduler and source-worker lifetime also need stronger bounds and failure isolation.

### Chosen approach

Use A's scope with a corrected C architecture. Deliver the live English MVP now, add an explicit template-writing mode, and keep Crossref/arXiv/model relevance as independent follow-ups.

## Architecture

### 1. Fold the source package into `drift`

Move `backend/sources/src/Drift/**` into `backend/src/Drift/**`, its specs and fixtures into the main test suite, and its CLI into `backend/app/Sources.hs`. Add the missing library dependencies and remove `sources` from `cabal.project`.

This removes the `drift-sources -> drift` dependency cycle that prevents `SessionActor` and `Server` from importing the source pipeline. It also removes the current Windows archive failure for the nested package.

### 2. Inject provider-independent pipelines

Add a `Pipelines` record and `newManagerWith`, while retaining `newManager store branchGenerator` as a compatibility wrapper.

```haskell
type EntryWriter = WritingInput -> IO Entry
type SourceSearch = SourceRequest -> (SourceDraft -> IO ()) -> IO ()

data Pipelines = Pipelines
  { pipeBranches :: BranchGenerator
  , pipeWriter :: Maybe EntryWriter
  , pipeSources :: Maybe SourceSearch
  }
```

Workers return values without durable IDs. The actor owns IDs, validation, persistence, application, and broadcast. Neither actor nor domain code knows which provider produced an entry.

### 3. Writing modes

Production assembly supports three explicit states:

- disabled: no entries, used only when explicitly requested and by legacy whole-log tests;
- template: every edge gets `fallbackEntry` without a model call; this is the default with no usable model provider;
- model: a future configured writer calls a provider and retains fallback behavior on ordinary failure.

Template work does not enter the model scheduler. Gemini later implements the same writer seam.

### 4. Pure admission

Add pure domain admission functions for sources and entries.

`admitEntry` rejects wrapped sessions, unknown/root nodes, duplicate edge entries, unknown citations, and citations belonging to another node. It assigns the next ID from the highest replayed ID plus one.

`admitSource` rejects wrapped sessions, unknown/root nodes, and duplicate canonical sources for the edge. It assigns the next source ID, produces `SourceFound`, and produces `EntryRevised` in the same batch when an entry already exists.

Entry admission reconciles all current sources for that edge. This covers sources arriving before the writer snapshot and the snapshot-to-commit race. Revisions preserve priority and struck state.

### 5. Actor lifecycle

After a committed non-root `NodeChosen`, start one edge coordinator outside the actor loop:

- source search starts if configured;
- writing starts after source completion or a bounded wait, whichever comes first;
- a normal search failure is diagnosed and still allows writing;
- sources may continue arriving after writing and revise the entry;
- picks, rings and backtracks continue independently;
- edge work is not invalidated when focus moves;
- wrap-up causes later results to be dropped by admission policy;
- halt cancels and waits for actor-owned work.

Use a bounded server-level source concurrency gate. A fast user must not create unlimited simultaneous HTTP work. The source wait bound controls when writing starts, not total source lifetime.

The pending source queue is bounded as well. If it is full, the newest edge's source search is skipped and a warning diagnostic is emitted; its template entry is still produced. There is no durable source-job backlog in this milestone. This overload policy protects interaction latency and memory while preserving the core writing record.

On actor startup, recover missing template entries for replayed non-root nodes in an unwrapped session. Source search may be retried; admission deduplication prevents duplicate durable sources. Zero-result searches have no durable completion marker in this milestone.

### 6. Server assembly

- No `DRIFT_CONFIG`: existing mock branches plus template entries.
- `DRIFT_WRITING=0`: disable entry production explicitly.
- `DRIFT_SOURCES=1`: construct one shared HTTP fetch/cache/rate-limit environment, load optional `OPENALEX_API_KEY`, and inject `findSources`.
- Without `DRIFT_SOURCES=1`: do not construct or call the network source pipeline.
- Startup logs may print provider names and whether a key is present, never the key.
- HTTP error logging must redact `api_key` values before stderr.

The current branch scheduler remains responsible only for M2 branch work. Template writing needs no scheduler. The eventual Gemini work decides its hosted concurrency policy without changing this actor contract.

## Data and Event Semantics

- Every non-root node has at most one entry.
- Every durable ID is allocated by the actor from replayed state.
- A source belongs to exactly one node; entry citations may only reference sources of that node.
- Every accepted source is associated with its edge entry, regardless of arrival order.
- `SourceFound` and a corresponding late `EntryRevised` commit atomically.
- No event is broadcast until SQLite append succeeds.
- Replay remains the source of truth after reconnect or restart.

## Failure and Security Behavior

- Provider errors, malformed results, rate limits and ordinary background exceptions yield diagnostics or zero results, never actor termination.
- Async cancellation propagates during shutdown.
- Append failure emits no partial source/entry update.
- Source concurrency is bounded and the shared HTTP environment preserves host gaps, cache and 429 state.
- Source queue overflow skips only that edge's search, emits a warning, and never skips its entry.
- Query parameters containing `api_key` are redacted in every exception log path.
- Crossref/arXiv limits are deferred rather than approximated incorrectly.

## Testing

### Pure/domain

- ID allocation from empty and replayed state.
- Reject wrapped, unknown, root, duplicate and cross-edge-citation admissions.
- Source deduplication by canonical DOI/URL/title identity.
- Source/entry reconciliation for every arrival order.

### Actor

- Template entry for every non-root pick; no root entry.
- Pick/backtrack/ring flow continues while source search blocks forever.
- Search failure still produces a template entry.
- Two edges completing out of order receive unique IDs.
- Sources arriving before snapshot, between snapshot and commit, and after entry commit produce the same final citations.
- Old-edge work remains valid after focus moves.
- Wrap-up drops late results; halt cancels and joins workers.
- Append failure never broadcasts partial results.
- Restart recovers missing template entries and does not duplicate sources.
- Source concurrency never exceeds its configured bound.

### Persistence and transport

- Entry creation, multi-level promote, strike, reload, restore and second reload preserve state.
- Source placement and citations survive manager and real-server restart.
- Reconnect replay remains idempotent.
- Offline tests explicitly override model/source environment variables.

### Frontend and browser

- Live entries appear without opening the sidebar automatically.
- Path/priority ordering, promote/strike/restore, references and source locate work with live events.
- Mobile bottom sheet, long text and reduced motion remain usable.
- Source focus and second-click opening are checked without transmitting secrets.

### Verification commands

- `cabal build all`
- `cabal test all --test-show-details=direct`
- regenerate TypeScript declarations and fixtures and require a clean diff
- `pnpm typecheck`
- `pnpm test`
- `pnpm build`
- Playwright smoke against the real local server using template writer and fake/no-network sources

## Documentation and Delivery

- Update README for template writing, `DRIFT_WRITING`, `DRIFT_SOURCES`, and `OPENALEX_API_KEY`.
- Mark the TODO documents complete or replace them with implementation links.
- Deliver on a new branch and PR; do not merge into `main` without explicit user action.
- State that the completed scope is the M6 live English MVP and M7 live/provider-independent pipeline; Gemini quality and extra providers remain follow-ups.

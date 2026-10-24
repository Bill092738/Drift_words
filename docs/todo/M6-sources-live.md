# M6 Sources live: remaining work

**Goal (TECH_ROADMAP.md 7.3):** in a normal session, sources land asynchronously behind their nodes without ever stalling a pick.

**Prerequisites:**
- The M5 pull request (#13) is merged.
- The actor groundwork from [M7-sidebar-live.md](M7-sidebar-live.md) is done: the `Pipelines` record, `admitEntry`, and the writing worker. M6 reuses that pattern and must coordinate with the writing job.

## What already exists

| Piece | Where | State |
| --- | --- | --- |
| `findSources`: Wikipedia and OpenAlex search, heuristic relevance check, exact CSL from doi.org, dedupe, at most 2 per edge | `backend/sources/` (package `drift-sources`, see its README) | Done, tested on saved real responses (PR #10) |
| Polite HTTP: User-Agent, request gaps, cache, 429 handling | `backend/sources/src/Drift/Search/Http.hs` | Done |
| `toSource :: SourceId -> NodeId -> SourceDraft -> Source` | `Drift.Search.Types` | Done |
| `reviseForSource` (attach a late source to the edge's entry) | `backend/src/Drift/Pipeline/Writing.hs` | Done |
| Replay of `SourceFound`; `PlaceSource` | `Drift/Domain/State.hs`, `Decide.hs` | Done |
| Drop animation, icons per kind, focus to enlarge, second click opens the original, sidebar source list | `frontend/src/desk/SourceObject.ts`, `DeskScene.ts`, sidebar | Done (only tested on the mocks) |
| **Running `findSources` in the live server** | `SessionActor.hs`, `Server.hs` | **Missing.** Only the `drift-sources` CLI calls it |

## Decisions to agree before coding

1. **Fold `drift-sources` into the main `drift` package.**
   - `drift-sources` depends on `drift`, so `drift` (where the session actor lives) cannot depend on it back.
   - The module names already follow TECH_ROADMAP.md section 6, so this is mostly moving files (task 1).
   - **M8 (PR #12) has the same problem** with its `drift-outputs` package. Agree with its owner to fold both the same way.
2. **Sources are opt-in.**
   - The server searches only with `DRIFT_SOURCES=1`. CI, the offline mode and `SessionE2ESpec` must never touch the network.
   - Sources are independent of the model config: they need no model.
3. **The actor assigns `SourceId` at commit,** using the highest existing id plus one, in the same way as for entries. The search job never sees an id.
4. **Edges only for now.** Search only for nodes with a parent, like entries. The root word could get sources too, since `findSources` accepts `fromWord = Nothing`, but it is not needed for the demo.
5. **Source jobs do not use the model scheduler,** because they make no model call. They are not cancelled by a backtrack or a new pick: sources land behind older nodes too. They are cancelled on `Halt`. After `WrappedUp`, late sources are dropped (coordinate with M8, as for entries).

## Tasks

### 1. Fold the package

- Move `backend/sources/src/Drift/**` to `backend/src/Drift/`. There are no module name clashes: `Drift.Pipeline.Sources`, `Drift.Search.*` and `Drift.Sources.*` are all new in `drift`.
- In `drift.cabal`:
  - Add the 9 modules to `exposed-modules`.
  - Add the library dependencies that `drift` lacks: `case-insensitive` and `vector` (all the others are already there).
- **Tests:**
  - Move `backend/sources/test/*Spec.hs` to `backend/test/` and add them to `other-modules` and to `test/Main.hs`. There are no name clashes.
  - Move `backend/sources/test/fixtures/` to `backend/test/fixtures/`. The specs read `test/fixtures/...` relative to the package directory, so the paths keep working.
- **CLI:** move `backend/sources/app/Main.hs` to `backend/app/Sources.hs`, as `executable drift-sources` in `drift.cabal`.
- Move the content of `backend/sources/README.md` into `backend/README.md` or into `docs/`.
- Remove `sources` from `backend/cabal.project`. CI needs no change, because `cabal test all` covers it.
- Make this a separate pull request: it is mechanical and easy to review.

### 2. Actor interface

In the `Pipelines` record (see the M7 document):

```haskell
type SourceSearch = SourceRequest -> (SourceDraft -> IO ()) -> IO ()
-- pipeSources :: Maybe SourceSearch
```

In production this is `findSources env`. Tests pass a fake.

### 3. Server

In `backend/app/Server.hs`, when `DRIFT_SOURCES=1`:
- Create **one** `newFetch defaultHttpConfig` for the whole server, so all sessions share the per-host gaps, the cache and the 429 state.
- Create one `SourceEnv` (`defaultSourceEnv fetch`), with `envOpenAlexKey` read from `OPENALEX_API_KEY` and `envLog` printing to stderr.
- Print `sources: wikipedia, openalex (OpenAlex key: yes|no)`. Never print the key.

### 4. Domain: admit a found source (pure)

In `Drift/Domain/Decide.hs`, add:

```haskell
admitSource :: Session -> NodeId -> SourceDraft -> Either Rejection [Event]
```

- It rejects the source when the session is wrapped up or the node is unknown.
- Otherwise it allocates `SourceId` (highest plus one), builds the source with `toSource`, and returns `[SourceFound s] <> reviseForSource sessionEntries s`. Committing the revision in the same batch means the entry cites the source as soon as the source appears.

### 5. Actor: the per-edge job, together with writing

After a commit containing `NodeChosen n (Just parent) ...`, start **one per-edge job** instead of starting the writer directly:

```haskell
withAsync (search request (\draft -> send (Found n draft))) $ \job -> do
  race_ (wait job) (threadDelay 1500000)  -- give sources up to 1.5 s
  send (WriteEdge n)                       -- now write the entry
  wait job                                 -- sources may keep landing afterwards
```

- **`SourceRequest`**: `fromWord` is the parent's word, `toWord` the node's word, `pathWords` the words from the root down to the parent, and `lang` is `sessionLanguage`.
- **On `Found n draft`:** run `admitSource`, then `commit`.
- **On `WriteEdge n`:** take a snapshot of the sources committed for `n`, then start the M7 writing worker with those sources in `WritingInput.sources`.
- **Race to handle:** a source can be committed after the snapshot but before `EntryWritten`, and `reviseForSource` would then find no entry to revise. To cover it:
  - Pass the snapshot's source ids into the admit step (for example, `admitEntry session snapshotIds entry`).
  - When the entry is admitted, add to `cites` every source of `n` that is not in the snapshot. That matches what `reviseForSource` would have done.
- **Without a writer** (no `writing` role), skip `WriteEdge`. **Without sources**, run the writer directly, as in M7.

### 6. Tests

- **`DomainDecideSpec`**: `admitSource` allocates ids and revises the edge's entry in the same batch. It is rejected after wrap-up or for an unknown node.
- **`SessionActorSpec`**, with a fake `SourceSearch`:
  - Two drafts, one delayed, give `SourceFound` ids 1 and 2 for the right node. The entry ends up citing both, whether a source arrived before or after the snapshot.
  - **The "never stalls a pick" check:** with a search that blocks forever, picks, `BranchesOffered` and backtracks still flow, and the entry is still written after the 1.5 s cap.
  - Late sources after `WrapUp` are dropped.
  - A restart replays the sources and their placements.
- Never call the real APIs in CI. Real responses are covered by the existing saved-response specs.

### 7. Manual end-to-end check

Run this before the demo:

```
cd frontend && pnpm build
cd ../backend && DRIFT_CONFIG=<config> DRIFT_SOURCES=1 OPENALEX_API_KEY=... cabal run drift-server
```

Then open `http://localhost:8080/?live&debug=1`. Pick about 10 levels and check that:
- sources drop in behind their nodes;
- clicking one focuses it, and clicking again opens the original;
- the sidebar's source list and references fill in;
- picks feel no slower;
- after a reload, the sources come back where they were placed.

`window.__desk.debugSources()` lists every source with its screen position.

### 8. Docs

Update the README status line and the "Run the backend" section (`DRIFT_SOURCES`, `OPENALEX_API_KEY`), and move the drift-sources README. Tick this document off.

## Things to know

- **English only.** The relevance heuristic does not work for Chinese text, and Chinese is out of scope.
- **Zero sources is normal.** Many edges get none, because the heuristic needs both words in the result and one of them in the title. That is by design: fewer, relevant sources.
- **OpenAlex budget.** Without a key, about 100 searches a day are shared by everyone on the same IP address, which at a hackathon is the whole venue. Get a free key before the demo.
- **Wikipedia thumbnails are not fetched yet** (`thumbnailUrl` is always null), so pages show the web-card icon.

## Out of scope for this deadline

- A model-backed relevance check (`RelevanceJudge` is ready for it).
- Wikimedia Commons (images and audio), Crossref, arXiv, and general web search.

## Done when

- [ ] With `DRIFT_SOURCES=1`, sources land behind their nodes during a normal session, and picks are never delayed.
- [ ] Entries cite the sources of their edge, including sources that land after the entry was written.
- [ ] Sources and their placements survive a reload and a restart.
- [ ] Without `DRIFT_SOURCES`, nothing touches the network, and CI passes.
- [ ] Tests from task 6 are in.

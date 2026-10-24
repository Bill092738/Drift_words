# M7 Sidebar live: remaining work

**Goal (TECH_ROADMAP.md 7.3):** entries appear without interrupting exploration, and promote, strike and restore all survive a reload.

**Prerequisite:** the M5 pull request (#13) is merged. It adds model configuration to `drift-server` (`DRIFT_CONFIG`) and the live mode in the frontend. This document assumes that code.

**Order:** do M7 before M6. M6 ([M6-sources-live.md](M6-sources-live.md)) reuses the actor changes described here.

## What already exists

| Piece | Where | State |
| --- | --- | --- |
| Writing prompt, reply parsing, fallback entry | `backend/src/Drift/Pipeline/Writing.hs` (`writeEntry`, `reviseForSource`) | Done, tested in `WritingSpec` |
| Grounded citations | `backend/src/Drift/Pipeline/Citations.hs` | Done, tested |
| Entry table and curation rules (Promote, Strike, Restore) | `backend/src/Drift/Domain/Entries.hs`, called from `decide` | Done and live, tested in `EntriesSpec` |
| Replay of `EntryWritten` / `EntryRevised` | `backend/src/Drift/Domain/State.hs` | Done |
| Sidebar, priorities, strike and restore, reference list, mobile bottom sheet | `frontend/src/chrome/sidebar/` | Done (only tested on the mocks) |
| **Running `writeEntry` in the live server** | `backend/src/Drift/Server/SessionActor.hs` | **Missing.** Nothing calls `writeEntry` |

So the work is almost entirely backend wiring. Once `EntryWritten` events flow over the WebSocket, the frontend should show them without changes.

## Decisions to agree before coding

1. **Inject pipelines into the actor as functions.**
   - Add a record and a second constructor, `newManagerWith :: Store -> Pipelines -> IO Manager`. Keep `newManager store generator` as a wrapper that sets only the branches, so every existing test keeps compiling.
   - Tests pass fake functions, the same way `BranchGenerator` is faked today.

   ```haskell
   data Pipelines = Pipelines
     { pipeBranches :: BranchGenerator
     , pipeWriter   :: Maybe (Text -> IO Text)  -- M7: the writing model; Nothing = no entries
     , pipeSources  :: Maybe SourceSearch       -- M6, see M6-sources-live.md
     }
   ```

2. **The actor assigns `EntryId` when it commits, not when it starts the job.**
   - `Session` has no entry-id counter, so use the highest existing id plus one, computed inside the actor, which is single-threaded.
   - Call `writeEntry` with a placeholder `EntryId 0` and overwrite `entryId` at commit.
   - This needs no new state and survives restarts.

3. **Entries are opt-in.**
   - The server writes entries only when `DRIFT_CONFIG` has a `writing` role. `DRIFT_WRITING=0` turns them off.
   - Without a model the server writes nothing. This keeps the offline mode and `SessionE2ESpec` deterministic: that test compares whole event histories, and entries arriving in the background would make it flaky.

4. **Do not run writing on the branch scheduler as it stands.** `Drift.Model.Scheduler` has a single slot, which causes two problems:
   - A P0 job (the branch ring for a pick) *cancels* a running P2 job with `JobCancelled`, and the cancelled job is not requeued.
   - The 6 P1 prefetch jobs queued after each pick all run before any P2 job.

   With a fast picker, entries would be cancelled again and again or arrive very late. The options are:
   - **(a)** Give writing its own `Scheduler` instance. **Recommended for hosted models**, because the single slot exists to protect a local GPU.
   - **(b)** Share the scheduler and resubmit on `JobCancelled`. Needed only when everything runs on one local model.

   `BranchService` creates its scheduler internally (`newBranchService`). Option (b) would need a way to pass one in.

5. **Late results.**
   - An entry for an older node is still valid. Commit it even if the user has moved on, which is unlike branch results.
   - After `WrappedUp`, drop late entries. M8 (PR #12) runs the final assembly on `WrapUp`, so agree with its owner whether wrap-up waits briefly, for example up to 5 s, for in-flight writing jobs.

## Tasks

### 1. Domain: admit a written entry (pure)

In `Drift/Domain/Decide.hs`, next to `offerBranches`, add:

```haskell
admitEntry :: Session -> Entry -> Either Rejection [Event]
```

It rejects the entry when:
- the session is wrapped up;
- the node is unknown, or has no parent (only edges get entries);
- the node already has an entry (`entriesForNode`), which guards against double writes and against re-running after a restart;
- a cited source is not in `sessionSources`.

Otherwise it returns `[EntryWritten e {entryId = next}]`, where `next` is the highest existing id plus one. M6 extends this function (see the M6 document, task 5).

### 2. Actor: run the writer for each new edge

In `Drift/Server/SessionActor.hs`:

- **New message:** add `Wrote Entry` to `Message`.
- **Trigger:** after a successful commit containing `NodeChosen n (Just parent) ...` (any origin with a parent), start a writing worker.
  - Keep it in `stateWorkers`, so `Halt` cancels it.
  - Do **not** tie it to `stateGeneration`: a backtrack or a new pick must not cancel it.
- **Build the `WritingInput`** from the session right after that commit:
  - `node`, `fromWord` (the parent's word) and `toWord`.
  - `path`: the words from the root down to the parent. `sessionBreadcrumbs` lists the parent first, so reverse it.
  - `origin` and `lang` (`sessionLanguage`, default `En`).
  - `sources`: the sources already found for `n`. There are none until M6.
- **The worker** runs `writeEntry generateText (EntryId 0) input`, then writes `Wrote entry` to the inbox.
  - `generateText p = generate provider (GenRequest p model 0 256) (const (pure ()))`, as described in the header of `Writing.hs`.
  - `writeEntry` already falls back to `"from → to"` when the model fails, so the worker throws only when it is cancelled.
- **On `Wrote`:** run `admitEntry`.
  - On success, call `commit`; the commit already persists before it broadcasts.
  - On rejection, broadcast a `Diagnostic LevelWarning`, except after wrap-up, where the result is dropped silently.

### 3. Server: build the writer from the config

In `backend/app/Server.hs`, inside `withGenerator`:
- Resolve `WritingRole`. `resolveProvider` returns `MissingRole` when the role is absent, which means "no entries", not an error.
- Create the provider with `createModelProvider` and print `writing: <provider> <model>`. Never print the key.
- Honour `DRIFT_WRITING=0`.

Gemini note: 256 output tokens is too small for models that always think. The planned Gemini branch will handle this; do not tune it here.

### 4. Optional: recover after a restart

Writing jobs that were running when the server stopped are lost. When an actor starts (`startActor`), it could start the writer for every node with a parent and no entry. This is not needed for the demo.

### 5. Tests

- **`DomainDecideSpec`**: each rejection case of `admitEntry`, and id allocation (1, then 2, and the highest plus one after a replay).
- **`SessionActorSpec`**, with a fake writer such as `const (pure "RELATION: r\nEXPLANATION: x")`:
  - A pick with a parent gives `EntryWritten` for that node. A root pick gives nothing.
  - Promote, Strike and Restore on that entry are accepted.
  - A slow writer (block on an `MVar`), then a backtrack: the entry is still committed for the old node.
  - A pick right after another, while the first entry is still being written: both entries arrive, with distinct ids.
  - An entry that finishes after `WrapUp` is not committed.
- **"Survives a reload" (the done-when):** write, promote and strike, stop the manager, open a new manager on the same `Store`, subscribe, and check that the replayed entries have the same priority and struck state.
  - `SessionE2ESpec` stays offline with no writer, so it needs no change.

### 6. Frontend

No change should be needed. Check in live mode with a real model:
- entries appear one per edge while exploring, without blocking picks;
- promote, strike and restore work, and reloading keeps them;
- the mobile bottom sheet works with real text;
- the sort by path and by priority looks right on a deep tree.

### 7. Docs

Update the README status line and the "Run the backend" section (the `writing` role, `DRIFT_WRITING`). Tick this document off.

## Done when

- [ ] With `DRIFT_CONFIG` set, every new edge gets an `EntryWritten`, and picks are never delayed by writing.
- [ ] Promote, strike and restore are persisted and survive a reload and a server restart.
- [ ] Offline (no `DRIFT_CONFIG`) behaves exactly as before, and CI passes.
- [ ] Tests from task 5 are in.

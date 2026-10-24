# M1 Session Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scripted client completes an exploration through WebSocket using deterministic mock branches, then restarts the server and resumes the same session from SQLite without losing history or placements.

**Architecture:** Pure domain decisions and replay sit behind one actor per session. The actor validates commands and background results, persists each event batch before publishing it, and owns ordered subscriptions. HTTP and WebSocket are adapters over that actor.

**Tech Stack:** Existing GHC 9.10 / cabal project, Hspec / QuickCheck, STM, async, sqlite-simple, wai-websockets / websockets, Servant / Warp.

**Spec:** `TECH_ROADMAP.md` sections 3, 4.2–4.5, 4.9 and M1; `idea.md`; authoritative wire types in `backend/src/Drift/Protocol.hs`.

## Current baseline and constraints

- The current backend implements only `/api/health`, wire types, type generation, and protocol tests. Domain, actor, database, and WebSocket modules do not exist yet.
- All repository content must remain English. Read `CLAUDE.md` and `protocol/README.md` first.
- Do not hand-edit generated TypeScript or JSONL fixtures. Prefer no wire changes for M1.
- Keep the frontend runnable on MockTransport. No frontend redesign belongs here.
- M2 owns production providers, role routing, streaming parsing, scheduling, embeddings, and prefetch. M1 owns a deterministic integration mock behind a replaceable callback.
- M6–M8 own real source retrieval, writing, and output generation. M1 must replay their existing events and validate curation commands, but need not produce those outputs.
- Roadmap examples are illustrative: actual `Stamped` is not parameterized, and actual edges are identified by the child `NodeId`.
- This file proposes internal interfaces and default policies; they are not existing implemented APIs.

## Review focus

1. Streamed candidates subsequently sealed must not count as two appearances (A1/A2).
2. A delayed branch result after backtracking or wrap-up must not replace the active ring (A4).
3. Failed database writes must neither advance in-memory state nor publish events (A3/A4).
4. Connecting while a command commits must not miss or duplicate events between replay and subscription (A4/A5).
5. Restart must restore IDs, appearance counts, focus, and placements, not just the visible word tree (A6).

## Dispatch and ownership

| Agent goal | Dependency | Exclusive implementation files |
| --- | --- | --- |
| A1: Replayable domain state | M0 | `backend/src/Drift/Domain/Types.hs`, `State.hs`, `Word.hs`; `backend/test/DomainReplaySpec.hs` |
| A2: Pure command decisions and invariants | A1 | `backend/src/Drift/Domain/Decide.hs`; `backend/test/DomainDecideSpec.hs`, `DomainPropertySpec.hs` |
| A3: Durable SQLite log | M0 | `backend/src/Drift/Store/SQLite.hs`; `backend/test/StoreSpec.hs` |
| A4: Session actor and mock branch adapter | A1, A2, A3 | `backend/src/Drift/Server/SessionActor.hs`, `backend/src/Drift/Model/SessionMock.hs`; `backend/test/SessionActorSpec.hs` |
| A5: HTTP / WebSocket adapter | A4 | `backend/src/Drift/Api.hs`, `backend/src/Drift/Server/WebSocket.hs`; `backend/test/ServerSpec.hs` |
| A6: Server wiring and restart acceptance | A5 | `backend/app/Server.hs`, `backend/test/SessionE2ESpec.hs`, `backend/test/Main.hs`, `backend/drift.cabal`, `README.md`, `Makefile` |

A1 and A3 can run in parallel after A1 lands the shared `SessionId` declaration (`newtype SessionId = SessionId Text`, deriving Eq, Ord, Show); A3 can draft store tests before that declaration lands. A2 follows A1. A4 is the integration gate, then A5 and A6. Do not dispatch all six as independent implementation tasks. A6's integrator registers dependencies/modules/specs incrementally for each earlier delivery so each agent can run its checks; serialize changes to these shared files.

Each agent receives this entire document plus its goal below. Return changed files, test commands and results, public signatures, and remaining limitations. Do not claim checks passed if the Haskell toolchain is unavailable. Use small scoped commits when executing; never commit another worker's edits.

## A1 — Build the pure replayable session state

**Assignable goal:** Implement a complete pure fold of the existing protocol events, preserving all information needed for continuation, and prove that replay restores the same domain state.

**Interfaces:** In `Types.hs`, define `Session`, `Rejection` (text-backed), `SessionId` (text-backed), and `Log` (newest-first `[Stamped]`). In `State.hs`, expose `emptySession :: Session`, `apply :: Session -> Event -> Session`, `replay :: Log -> Session`. In `Word.hs`, expose `wordKey :: Text -> Text`, `cap :: Double -> Int`.

**State requirements:** Tree nodes with parents and selection order; current focus and zipper breadcrumbs; visited normalized words; appearance counts; current cloud/ring and streamed candidates; next node/candidate IDs; divergence; source and entry maps; entry priority/strike state; placement maps; wrapped state; outputs. Replaying every existing event constructor must be supported. Wire order is oldest-first; convert once to the newest-first Log, then fold in chronological order.

**Proposed M1 policy:** Keys use NFKC, case-folding, and trimming. Default divergence is 0.5; `cap d = 3 - floor (2 * clamp 0 1 d)`. Count a candidate's first visible occurrence once by candidate ID, including the initial cloud; sealing the same candidate does not increment it again. A fresh appearance uses a fresh candidate ID. State application must not consult clocks or randomness.

- [ ] Write `DomainReplaySpec`: all constructors replay, fork/backtrack parent links, priorities and strike/restore, placements, outputs, and stream-then-seal counting once; use the existing fixtures as decoding/replay inputs without changing them.
- [ ] Run `cd backend && cabal test --test-options='--match DomainReplay'`; verify the new tests fail before implementation.
- [ ] Implement the state, normalization, cap, and pure fold; export accessors needed by A2/A4 rather than letting them duplicate state logic.
- [ ] Re-run the spec; confirm fixture replay is deterministic and ID high-water marks include unchosen candidates.
- [ ] Commit only A1 files and provide A2/A4 the final Session fields/accessors.

## A2 — Validate commands and prove exploration invariants

**Assignable goal:** Implement `decide :: Session -> Command -> Either Rejection [Event]` without IO, enforcing legal exploration and preserving roadmap invariants 1–4.

**Files/interfaces:** `Decide.hs` consumes A1. Also expose `offerBranches :: Session -> NodeId -> [Candidate] -> Either Rejection [Event]` for actor-owned background admission. It filters normalized duplicates, visited words, and exhausted appearance caps before emitting branch events. It rejects duplicate/reused IDs for fresh appearances. A4 owns job freshness before calling this function.

**Behavior:** Pick only active candidates, consume the active offer on selection, allocate increasing node IDs, and attach the current parent. StartWithWord is valid before any node is chosen; InsertWord requires focus and requests branches through the actor. Reject empty/whitespace-separated words, already chosen normalized words, unknown IDs, invalid/nonfinite divergence or placement values, and nonpositive promotion levels. Backtrack requires an existing node and moves focus without deleting history. It starts a fresh branch generation, rather than resurrecting already chosen candidates. Divergence changes affect subsequent generation, never reroll the current offer. WrapUp is idempotent; after wrap-up reject exploration/curation changes, allow valid placements and repeated WrapUp. Reopening is deferred because there is no reopen command.

- [ ] Write `DomainDecideSpec` for each command's legal/rejected transitions, single-word Chinese and English input, repeat picks, invalid IDs, and wrap-up policy.
- [ ] Write `DomainPropertySpec` with generated valid command sequences and admitted mock branches: no visited word newly offered; appearance counts never exceed cap at admission; each nonroot parent exists and precedes its child; replay equals the incrementally applied state. Lowering the cap does not retroactively invalidate earlier offers.
- [ ] Run both specs and confirm failures before implementation.
- [ ] Implement decisions and branch admission. Include NFKC/case-fold duplicate cases and stream/seal deduplication in tests.
- [ ] Run `cd backend && cabal test`; require at least 100 QuickCheck cases per property, and report seeds for failures before committing A2 files.

## A3 — Persist and reload an atomic event log

**Assignable goal:** Implement a SQLite store that atomically appends ordered event batches and restores sessions after closing and reopening the database.

**Interfaces:** `openStore :: FilePath -> IO Store`, `closeStore :: Store -> IO ()`, `createSession :: Store -> SessionId -> [Stamped] -> IO ()`, `loadEvents :: Store -> SessionId -> IO (Maybe [Stamped])`, `appendEvents :: Store -> SessionId -> Int -> [Stamped] -> IO ()`. `loadEvents` returns oldest-first. The append Int is the expected last sequence; failures throw typed store exceptions, caught by the actor.

**Requirements:** A sessions table distinguishes unknown sessions from empty logs; events use `(session_id, seq)` as a unique key with timestamp and JSON payload. Creation and initial cloud are one transaction. Batch append checks the expected tail and contiguous 1-based sequences within the transaction. Serialize connection access. Never silently skip malformed payloads or sequence gaps. This module depends on protocol types and SessionId only, not command semantics.

- [ ] Write `StoreSpec` for reopen round trips, unknown vs empty sessions, duplicate IDs/sequences, expected-tail mismatch, and whole-batch rollback on failure.
- [ ] Run the spec to see the unimplemented store fail.
- [ ] Implement the schema and transactional API, with temporary database files in tests.
- [ ] Re-run `cd backend && cabal test --test-options='--match Store'`; inspect that rollback leaves the old log unchanged.
- [ ] Commit A3 files and document exception types for A4.

## A4 — Serialize sessions and integrate a deterministic mock

**Assignable goal:** Build one actor per session that handles commands and background results in order, durably commits events, and offers gap-free replay plus live subscriptions.

**Interfaces:** Define `BranchGenerator = Session -> NodeId -> IO [Text]`; `newManager :: Store -> BranchGenerator -> IO Manager`; `createManagedSession :: Manager -> Lang -> IO SessionId`; `subscribeSession :: Manager -> SessionId -> IO (Either Rejection Subscription)`; `submit :: Subscription -> ClientMsg -> IO ()`; `receive :: Subscription -> IO ServerMsg`; `unsubscribe :: Subscription -> IO ()`; `stopManager :: Manager -> IO ()`. Subscription creation enqueues the full history as its first Events message, atomically with registration inside the actor. Rejections go only to the originating subscription.

**Requirements:** Allocate unique session IDs, stamp sequence/time in the actor, persist before apply/broadcast, and use one actor registry entry per session under concurrent connects. Restore state before accepting commands. Run branch work outside the actor; track an internal generation token and discard stale results after focus changes or wrap-up. Allocate candidate IDs inside the actor, then use A2 admission. Mock cloud and branches are deterministic, support En/Zh, and allow a scripted 15-step path without exhausted vocabulary. A mock failure leaves the session responsive; insertion/backtracking remain available. A2/A4 are the authority for admission; the future M2 generator supplies suggestions only.

- [ ] Write `SessionActorSpec` with a controllable delayed generator and failing store seam: two clients, ordered sequences, sender-only rejection, persistence failure, concurrent subscription boundary, stale branches, and cancellation/shutdown.
- [ ] Run the tests before implementation and verify failures.
- [ ] Implement the registry, mailbox, subscription cleanup, mock, persistence-first commit, and restoration path.
- [ ] Run `cd backend && cabal test --test-options='--match SessionActor'`; require no database writes or outgoing events for rejected commands and no post-stop worker activity.
- [ ] Commit A4 files and hand the subscription API to A5.

## A5 — Expose the session engine over HTTP and WebSocket

**Assignable goal:** Let existing frontend WebSocketTransport communicate with the M1 actor using the unchanged wire protocol.

**Interfaces:** Change `Drift.Api.server` to `Manager -> Server Api`; retain `/api/health`. Add proposed HTTP contract `POST /api/sessions` with JSON `{"lang":"en"}` or `{"lang":"zh"}`, returning `{"sessionId":"..."}`. Define these HTTP DTOs in `Api.hs` and document them; the current WS protocol has no session-creation DTO. Expose `webSocketApp :: Manager -> ServerApp` in `Server/WebSocket.hs` for `/api/sessions/:id/ws`.

**Requirements:** Unknown session/path fails the handshake without creating state. A valid connection receives the entire ordered log first, then incremental Events. Decode ClientMsg and relay Rejected with its original req. Malformed JSON without a reliable req closes only that connection using a documented protocol-error close code, rather than inventing a request ID. Use a single socket writer and always unsubscribe on disconnect. Keep provider keys and implementation failures out of responses.

- [ ] Write `ServerSpec`: health, session creation/language validation, unknown WS session, initial replay, valid pick, matching rejection req, malformed frame isolation, and simultaneous clients receiving identical ordered events.
- [ ] Run the spec and observe missing API failures.
- [ ] Implement the HTTP and WebSocket adapters; keep domain rules inside A2/A4.
- [ ] Re-run `cd backend && cabal test --test-options='--match Server'` against actual local sockets.
- [ ] Commit A5 files and hand A6 the WAI/WebSocket composition entry points.

## A6 — Wire startup and prove restart/resume end to end

**Assignable goal:** Deliver the runnable M1 server and a repeatable scripted acceptance check showing persistence across a real server-process restart.

**Files:** Wire `backend/app/Server.hs`; register all modules/specs/dependencies in `backend/drift.cabal` and `backend/test/Main.hs`; add `SessionE2ESpec.hs`; document commands in `README.md` and add a `Makefile` target if helpful. Preserve `DRIFT_PORT`; add documented `DRIFT_DB_PATH` with default `drift.sqlite`, and ignore runtime database/sidecar files in `.gitignore`.

- [ ] Incrementally register earlier agents' modules and tests, run their focused checks, and avoid bundling unverified modules until their dependencies land.
- [ ] Implement server composition with graceful manager/store shutdown and the deterministic mock default.
- [ ] Implement a scripted client test that creates a session, picks a cloud word, explores 15 steps, changes divergence, inserts a word, backtracks, records a placement, and checks a rejected command leaves the log unchanged.
- [ ] Capture the complete pre-restart log; terminate the server process, restart a new process with the same temporary DB, reconnect to the same session, and assert exact Stamped history equality and replayed state equality.
- [ ] Continue picking after restart and assert no ID reuse and contiguous sequences; wrap up and restart again to prove WrappedUp persists. Test StartWithWord in a separate session. Do not require OutputsReady: that belongs to M8.
- [ ] Run `make check` and the documented process-restart test. If native Windows lacks the required toolchain, use an available configured environment or report the exact blocked checks; do not claim roadmap workstation notes prove this machine has GHC installed.
- [ ] Document the creation request, WS URL, mock mode, DB path, and exact reproduction commands; commit scoped integration changes.

## Final M1 acceptance

- [ ] A real scripted WebSocket client completes the mock exploration and resumes after a new server process starts.
- [ ] Pure domain invariants 1–4 pass; persisted replay includes all event constructors already in the contract.
- [ ] Concurrent subscribers see a consistent ordered history; failed writes and stale jobs cannot publish invalid state.
- [ ] Existing protocol and frontend checks still pass, with no manual edits to generated artifacts.
- [ ] M2 can replace BranchGenerator without rewriting actor, store, or transport.

This is a delegation plan only. No M1 implementation or passing runtime checks are implied by its creation.

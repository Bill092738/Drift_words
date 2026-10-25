# M2 Model Slot and Branch Pipeline Implementation Plan

> **Status (October 24, 2026):** this plan is complete and merged into `main`; the boxes were ticked afterwards. Remaining work is tracked in [docs/todo/REMAINING.md](../../todo/REMAINING.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build the Haskell M2 model abstraction and latency-oriented branch generation pipeline, including an offline mock and the `drift-branches` tuning CLI.

**Architecture:** Keep provider IO behind `ModelProvider`, candidate parsing and selection pure, and scheduling isolated behind a priority queue that preempts lower-priority work. The CLI composes those modules without requiring the session engine or frontend.

**Tech Stack:** GHC 9.10, Cabal 3.16, Hspec, STM/async, aeson, http-client-tls, yaml, unicode-transforms, optparse-applicative.

**Spec:** `TECH_ROADMAP.md`, sections 4.4 through 4.6 and milestone M2 in section 7.3.

## Global Constraints

- Keep `backend/src/Drift/Protocol.hs` as the wire-contract source of truth.
- Provide OpenAI-compatible and deterministic mock adapters with configuration-based role routing.
- `generate` streams chunks through a callback and returns the complete text; embeddings are optional.
- Use P0 selected branches, P1 speculative branches, P2 writing, and P3 final; P0 cancels lower-priority running work.
- Normalize with NFKC, case folding, and trimming; never offer chosen words; cap other repeats by divergence.
- Use embedding cosine-distance bands plus MMR when embeddings exist and a prompt-only fallback otherwise.
- Provide `drift-branches "word" --divergence 0.7`.
- Keep repository content and commits in English and follow test-first red-green-refactor.

## Review Focus

- Fragmented output cannot leak punctuation, empty words, or normalized duplicates.
- Missing, zero-length, or mismatched embeddings fall back safely.
- Divergence outside `[0,1]` is rejected at external boundaries.
- Preemption completes waiters and cannot publish a cancelled lower-priority result.
- Provider/config errors are useful and never expose API keys.

### Task 1: Provider Slot, Adapters, and Role Configuration

**Files:** `backend/src/Drift/Model/{Provider,Mock,OpenAICompat,Config}.hs`, `backend/test/ModelProviderSpec.hs`.

**Interfaces:** Produce provider/request/embedding types, model configuration and roles, deterministic mock, and OpenAI-compatible generation/embedding adapters.

- [x] Write and observe failing provider/config tests.
- [x] Implement the provider modules minimally.
- [x] Run focused tests and commit only Task 1 files.

### Task 2: Pure Branch Generation and Selection

**Files:** `backend/src/Drift/Pipeline/Branches.hs`, `backend/test/BranchesSpec.hs`.

**Interfaces:** Consume provider request/embedding types; produce prompt construction, streaming parsing, normalization, filtering, repeat cap, cosine distance, divergence bands, MMR, and branch generation.

- [x] Write and observe failing parser/selection tests.
- [x] Implement pure helpers and provider-driven generation minimally.
- [x] Run focused tests and commit only Task 2 files.

### Task 3: Preemptive Scheduler and Speculative Prefetch Cache

**Files:** `backend/src/Drift/Model/Scheduler.hs`, `backend/src/Drift/Pipeline/Prefetch.hs`, `backend/test/{Scheduler,Prefetch}Spec.hs`.

**Interfaces:** Produce P0 through P3 job scheduling, cancellation/shutdown, and a one-shot thread-safe prefetch cache with stable priority/FIFO ordering.

- [x] Write and observe failing scheduling/prefetch tests.
- [x] Implement STM/async scheduling and cache minimally.
- [x] Run focused tests and commit only Task 3 files.

### Task 4: Cabal Integration and `drift-branches` CLI

**Files:** modify `backend/drift.cabal` and `backend/test/Main.hs`; create `backend/app/Branches.hs`, `backend/config.example.yaml`, and `backend/test/BranchesCliSpec.hs`.

**Interfaces:** Consume Tasks 1 through 3 and provide a CLI with positional word, bounded `--divergence`, and optional `--config`.

- [x] Add failing parser and mock integration tests.
- [x] Wire modules, dependencies, CLI, and credential-free config into Cabal.
- [x] Run backend tests/build and mock CLI at divergence `0.1`, `0.7`, and `0.9`.
- [x] Run the full repository check and commit integration.

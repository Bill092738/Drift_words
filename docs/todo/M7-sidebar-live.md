# M7 sidebar live: template pipeline completed

This completion record replaces the remaining-work proposal on `origin/docs/m6-m7-todo`. See the [current design](../superpowers/specs/2026-10-24-m6-m7-live-design.md) and [run instructions](../../README.md#run-the-backend).

- [x] Provider-independent `Pipelines`, `EntryWriter` and source search functions are injected into the session actor. The compatibility `newManager` wrapper remains available.
- [x] Every committed non-root edge gets one persistent `fromWord → toWord` template note with an empty explanation by default. No model configuration or call is needed; `DRIFT_WRITING=0` explicitly disables entries.
- [x] Only the actor admits results, validates same-edge citations, assigns replay-safe IDs and persists before broadcasting. Late sources revise citations while preserving curation.
- [x] Writing runs outside the actor and branch scheduler; exploration continues independently, old-edge results remain valid and shutdown joins owned workers.
- [x] Unwrapped replay recovers missing entries without duplicating existing entries.
- [x] Domain/actor/process tests cover rejection, failures, ordering, cancellation, restart and curation persistence.
- [x] Rendered live acceptance verifies closed-until-opened notes, template content, multi-level promotion, strike, restore, reload and reconnect after real backend restart. Recorded fixture acceptance checks path/priority controls, citations and mobile behavior.

The original proposal's model-only, opt-in writer has been superseded: no-model template writing is the default, while deterministic legacy log tests explicitly disable writing. A `writing` role in model configuration does not currently activate model writing. Gemini can implement the `EntryWriter` seam later without changing protocol, persistence or frontend behavior.

No Gemini/provider quality or model-backed relevance was tested. M8 draining/output assembly, additional retrieval providers and Chinese retrieval remain separate work. Offline unit/integration/browser acceptance is required; real source smoke is optional and non-gating.

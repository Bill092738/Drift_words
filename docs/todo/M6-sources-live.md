# M6 sources live: English MVP completed

This completion record replaces the remaining-work proposal on `origin/docs/m6-m7-todo`. The current design is [M6/M7 live completion](../superpowers/specs/2026-10-24-m6-m7-live-design.md); runtime instructions and limits are in the [source README](../../backend/sources/README.md).

- [x] Source modules, fixtures and specs are part of the main `drift` package; `drift-sources` remains a CLI executable.
- [x] `DRIFT_SOURCES=1` independently enables Wikipedia/OpenAlex with optional `OPENALEX_API_KEY` and one shared HTTP environment. Without opt-in, the server makes no source requests.
- [x] The serialized actor allocates IDs, deduplicates sources and commits late citation revisions atomically before broadcast.
- [x] Two active searches and sixteen pending jobs bound source work. A full queue skips the newest search with a warning and still produces its template entry.
- [x] Search completion or a 250ms bound starts writing. All source/snapshot/entry arrival orders reconcile; focus changes preserve older edge work, wrap-up rejects late results and shutdown joins workers.
- [x] Offline saved-response, actor and real-process fake-source tests cover transport, citation integrity, ID continuation and placement replay after restart.
- [x] Rendered offline acceptance covers recorded references, source locate/focus and original-link opening, desktop/mobile sheets, long prose and reduced motion.

The original proposal's unbounded per-edge search and 1.5-second wait were superseded by the bounded shared pool and 250ms production deadline. Tests use barriers, fake sources and saved responses. Browser fixtures prove rendering; the fake-source child-process test proves live `SourceFound` transport/persistence. Real-provider smoke is optional and non-gating, and was not required for this acceptance.

Completed scope is the live English MVP using heuristic word overlap. Gemini, model-backed relevance, Crossref/arXiv search, Commons/general search, Chinese retrieval and M8 output/wrap-up draining are still deferred. Model or semantic quality was not tested.

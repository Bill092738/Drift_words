# Source search (M6 live English MVP)

Finds sources for one edge of the word tree: it searches Wikipedia and OpenAlex, applies an English word-overlap relevance heuristic, normalizes retrieved CSL-JSON, drops duplicates and hands each accepted source to the caller as a `SourceDraft`. It knows nothing about sessions. See [TECH_ROADMAP.md section 4.7](../../TECH_ROADMAP.md).

```haskell
findSources :: SourceEnv -> SourceRequest -> (SourceDraft -> IO ()) -> IO ()   -- Drift.Pipeline.Sources
toSource    :: SourceId -> NodeId -> SourceDraft -> Source                      -- Drift.Search.Types
```

The session actor allocates the `SourceId`, persists `SourceFound` and any late `EntryRevised` together, then broadcasts. Entry admission reconciles sources that arrived before the writer snapshot or before its commit. Citations stay on their own edge; revisions preserve curation. Nothing here changes `Protocol.hs`.

## Live server

From `backend/`, run `cabal run drift-server`. Sources are on by default; `DRIFT_SOURCES=0` turns them off, and then no source HTTP environment is constructed. Set optional `OPENALEX_API_KEY` for the OpenAlex request. No `DRIFT_CONFIG` or model is needed. The default writer emits `fromWord → toWord` with an empty explanation; `DRIFT_WRITING=0` disables it. Model writing through the provider-independent seam is deferred to Gemini work.

One shared HTTP environment owns cache and host-rate-limit state across sessions. A server-wide pool permits two active searches and sixteen queued edges. Full-queue admission skips the newest search, diagnoses it and still writes its template note. Writing starts after source completion or 250ms; source delivery can continue afterward. Picks, rings and backtracks do not wait for either job. Moving focus keeps older edge work valid; wrap-up drops later results, and shutdown cancels and joins workers before closing HTTP/SQLite resources.

Entries, sources, citations, curation and placements are replayed from SQLite. An unwrapped session recovers missing entries on startup and may retry source search; admission deduplicates durable sources. There is no durable source-job backlog or zero-result completion marker. M8 wrap-up draining remains separate.

## Behavior

- At most 2 sources per edge (`envMaxPerEdge`), often 0. The best passing result of each provider goes first, so there is one page and one paper rather than two of the same kind. With fewer places than providers (`envMaxPerEdge = 1`), the pipeline waits for both and takes the best score, so the result does not depend on which provider answers first.
- Sources are delivered one at a time, as they are accepted. Failures, timeouts, rate limits and malformed responses are logged and dropped; the search never throws for them and stops when its thread is cancelled.
- Only `http(s)` links reach the desk, titles are plain text (markup and entities removed), and CSL-JSON comes from retrieved metadata only, never from model text.
- Papers need a DOI. The exact CSL-JSON comes from doi.org content negotiation; if that fails, the fields OpenAlex returned are used. DOI links are percent-encoded, so old DOIs with `<`, `>`, `;` or `#` resolve. Book and chapter references keep their editor, edition and place.
- The relevance check is a replaceable `RelevanceJudge`. The default is a word-overlap heuristic: both words of the connection must appear in the title or the provider's text, one of them in the title. It matches words, not meaning (for example "apple" and "newton" also accept the old Apple Newton PDA). The words above the edge (`pathWords`) only rank sources that already pass: a source that also mentions them scores higher. A model-backed judge can replace it without changing the pipeline.
- English only. The heuristic splits text on spaces and punctuation, so it does not work for Chinese, which has no spaces between words; Chinese is out of scope for now.

## HTTP behavior

- **OpenAlex** receives the optional `OPENALEX_API_KEY`; startup logs only whether it is present. The pipeline makes one search per edge. After HTTP 429, a numeric `Retry-After` takes priority. Without it, a numeric `x-ratelimit-remaining` at or below zero selects numeric `x-ratelimit-reset`, falling back to 60 seconds if reset is absent or invalid; positive remaining budget selects 2 seconds. Missing or invalid remaining-budget data selects 60 seconds. Numeric waits are rounded up and clamped to 1–86,400 seconds. Current provider quotas and availability are external conditions, not guarantees from the offline test suite.
- **Wikipedia** and **doi.org**: a descriptive User-Agent and a short gap between requests. Responses are cached for an hour, at most 512 of them.
- **Crossref search** and **arXiv search** are not used yet; their provider-specific request policies belong to that future integration.

HTTP errors redact `api_key` query values before logging. Crossref DOI metadata obtained through doi.org is not Crossref search support. Gemini writing, model-backed relevance, Chinese retrieval, Commons and additional search providers remain deferred.

## Try it

Real network calls only happen on request:

```
cabal run drift-sources -- --live tide moon        # prints SourceFound events, logs on stderr
DRIFT_LIVE_TESTS=1 cabal test drift-test          # includes the live test
cabal test drift-test                             # offline: saved real responses in test/fixtures
```

Run these commands from `backend/`. Source search is part of the `drift` library;
`drift-sources` is its CLI executable, backed by `app/Sources.hs`. The source
specs run in the main `drift-test` suite, with saved responses in `test/fixtures`.

Required verification is offline: the saved-response specs, barrier-controlled actor timing/queue tests, and the fake-source real-process restart test prove deterministic source delivery, citation reconciliation and replay over the actual API/WebSocket/SQLite stack. Recorded frontend fixtures cover reference/source rendering; they do not prove live external search quality. Real Wikipedia/OpenAlex smoke is optional and non-gating. No model-quality claim follows from these checks.

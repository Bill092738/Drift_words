# drift-sources (M6 backend)

Finds sources for one edge of the word tree: it searches Wikipedia and OpenAlex, checks that each result supports the connection, makes the CSL-JSON exact, drops duplicates and hands each accepted source to the caller as a `SourceDraft`. It knows nothing about sessions. See TECH_ROADMAP.md section 4.7.

```haskell
findSources :: SourceEnv -> SourceRequest -> (SourceDraft -> IO ()) -> IO ()   -- Drift.Pipeline.Sources
toSource    :: SourceId -> NodeId -> SourceDraft -> Source                      -- Drift.Search.Types
```

The caller (the session actor) allocates the `SourceId`, builds the `Source` with `toSource` and emits `SourceFound`. Nothing here changes `Protocol.hs`.

## Behavior

- At most 2 sources per edge (`envMaxPerEdge`), often 0. The best passing result of each provider goes first, so there is one page and one paper rather than two of the same kind.
- Sources are delivered one at a time, as they are accepted. Failures, timeouts, rate limits and malformed responses are logged and dropped; the search never throws for them and stops when its thread is cancelled.
- Only `http(s)` links reach the desk, titles are plain text (markup and entities removed), and CSL-JSON comes from retrieved metadata only, never from model text.
- Papers need a DOI. The exact CSL-JSON comes from doi.org content negotiation; if that fails, the fields OpenAlex returned are used.
- The relevance check is a replaceable `RelevanceJudge`. The default is a word-overlap heuristic: both words of the connection must appear in the title or the provider's text, one of them in the title. It matches words, not meaning (for example "apple" and "newton" also accept the old Apple Newton PDA). A model-backed judge can replace it without changing the pipeline.

## Free API limits

- **OpenAlex** needs no key, but a keyless client shares a small daily budget (USD 0.10, about 100 searches) with everyone on its IP address; a free key (`OPENALEX_API_KEY`) gives ten times that. The pipeline makes one search per edge and, after a 429, does not call the host again until its budget resets. No paid plan is used or needed.
- **Wikipedia** and **doi.org**: a descriptive User-Agent and a short gap between requests.
- **Crossref** and **arXiv** are not used yet. arXiv allows one request every three seconds on one connection.

## Try it

Real network calls only happen on request:

```
cabal run drift-sources -- --live tide moon        # prints SourceFound events, logs on stderr
DRIFT_LIVE_TESTS=1 cabal test drift-sources        # includes the live test
cabal test drift-sources                           # offline: saved real responses in test/fixtures
```

This is a separate cabal package so it does not edit `drift.cabal` or `test/Main.hs`; its modules follow the layout in TECH_ROADMAP.md section 6 and can be folded into the main package later by moving files.

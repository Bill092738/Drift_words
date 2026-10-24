# drift-sources (M6 backend)

Finds sources for one edge of the word tree: it searches Wikipedia and OpenAlex, checks that each result supports the connection, makes the CSL-JSON exact, drops duplicates and hands each accepted source to the caller as a `SourceDraft`. It knows nothing about sessions. See TECH_ROADMAP.md section 4.7.

```haskell
findSources :: SourceEnv -> SourceRequest -> (SourceDraft -> IO ()) -> IO ()   -- Drift.Pipeline.Sources
toSource    :: SourceId -> NodeId -> SourceDraft -> Source                      -- Drift.Search.Types
```

The caller (the session actor) allocates the `SourceId`, builds the `Source` with `toSource` and emits `SourceFound`. Nothing here changes `Protocol.hs`.

## Behavior

- At most 2 sources per edge (`envMaxPerEdge`), often 0. The best passing result of each provider goes first, so there is one page and one paper rather than two of the same kind. With fewer places than providers (`envMaxPerEdge = 1`), the pipeline waits for both and takes the best score, so the result does not depend on which provider answers first.
- Sources are delivered one at a time, as they are accepted. Failures, timeouts, rate limits and malformed responses are logged and dropped; the search never throws for them and stops when its thread is cancelled.
- Only `http(s)` links reach the desk, titles are plain text (markup and entities removed), and CSL-JSON comes from retrieved metadata only, never from model text.
- Papers need a DOI. The exact CSL-JSON comes from doi.org content negotiation; if that fails, the fields OpenAlex returned are used. DOI links are percent-encoded, so old DOIs with `<`, `>`, `;` or `#` resolve. Book and chapter references keep their editor, edition and place.
- The relevance check is a replaceable `RelevanceJudge`. The default is a word-overlap heuristic: both words of the connection must appear in the title or the provider's text, one of them in the title. It matches words, not meaning (for example "apple" and "newton" also accept the old Apple Newton PDA). The words above the edge (`pathWords`) only rank sources that already pass: a source that also mentions them scores higher. A model-backed judge can replace it without changing the pipeline.
- English only. The heuristic splits text on spaces and punctuation, so it does not work for Chinese, which has no spaces between words; Chinese is out of scope for now.

## Free API limits

- **OpenAlex** needs no key, but a keyless client shares a small daily budget (USD 0.10, about 100 searches) with everyone on its IP address; a free key (`OPENALEX_API_KEY`) gives ten times that. The pipeline makes one search per edge. After a 429 for a spent budget (`x-ratelimit-remaining` at 0) it does not call OpenAlex again until the budget resets at midnight UTC; a 429 for the per-second limit only pauses it for 2 seconds. No paid plan is used or needed.
- **Wikipedia** and **doi.org**: a descriptive User-Agent and a short gap between requests. Responses are cached for an hour, at most 512 of them.
- **Crossref** and **arXiv** are not used yet. arXiv allows one request every three seconds on one connection.

## Try it

Real network calls only happen on request:

```
cabal run drift-sources -- --live tide moon        # prints SourceFound events, logs on stderr
DRIFT_LIVE_TESTS=1 cabal test drift-sources        # includes the live test
cabal test drift-sources                           # offline: saved real responses in test/fixtures
```

This is a separate cabal package so it does not edit `drift.cabal` or `test/Main.hs`; its modules follow the layout in TECH_ROADMAP.md section 6 and can be folded into the main package later by moving files.

# drift-outputs (M8 backend)

The three wrap-up outputs: decision tree, draft and final (TECH_ROADMAP.md sections 4.8 and 7.3, M8). Pure functions over the session's events and tables; nothing here touches the network or the session actor. The result goes into the existing `Outputs` and `OutputsReady` of the protocol, which this package does not change.

| Module | Output | Status |
| --- | --- | --- |
| `Drift.Output.Tree` | Decision tree as a fenced Mermaid block (forks and backtracks) | done; matches the `exploration.jsonl` fixture exactly |
| `Drift.Output.Cite` | Citations and reference lists in APA, rendered by citeproc from each source's CSL-JSON | done |
| `Drift.Output.Draft` | Draft: every entry in order, struck ones crossed out and kept, with the full reference list | done |
| `Drift.Output.Final` | Final: kept entries (not struck, priority at least 1) as prose, a model rewrite with a no-model fallback, references recomputed from the final text | done |

The final document splits the walk into sections at each backtrack (headed by the first kept word in each, no headings when there is only one section). A model, given as a plain `Text -> IO Text`, rewrites each section; only sources cited by the kept entries can be cited, anything else is dropped, and a section falls back to the kept entries' own text when there is no model, it fails, or its reply is unusable. The reference list is rendered from the citations that remain in the final text. Nothing here is wired into the session actor yet: no code produces `OutputsReady`.

`data/apa.csl` is the APA 7th edition style from [citation-style-language/styles](https://github.com/citation-style-language/styles), unchanged and under its own license (CC BY-SA 3.0, stated inside the file). citeproc embeds the locale files itself. The style is compiled into the library, so nothing is read from disk at run time.

Text that came from a model or the web is escaped before it goes into a document, and a source that was not retrieved is never cited (invariant 6).

It is a separate cabal package so it does not edit `drift.cabal` or `test/Main.hs`; the module names follow the layout in TECH_ROADMAP.md section 6, so folding them into the main package later is a file move.

```
cabal test drift-outputs
```

# drift-outputs (M8 backend)

The three wrap-up outputs: decision tree, draft and final (TECH_ROADMAP.md sections 4.8 and 7.3, M8). Pure functions over the session's events and tables; nothing here touches the network or the session actor. The result goes into the existing `Outputs` and `OutputsReady` of the protocol, which this package does not change.

| Module | Output | Status |
| --- | --- | --- |
| `Drift.Output.Tree` | Decision tree as a fenced Mermaid block (forks and backtracks) | done; matches the `exploration.jsonl` fixture exactly |
| `Drift.Output.Draft` | Draft: every entry in order, struck ones crossed out, with the full reference list | next |
| `Drift.Output.Final` | Final: high-priority entries only, references recomputed from what the text cites | next |

It is a separate cabal package so it does not edit `drift.cabal` or `test/Main.hs`; the module names follow the layout in TECH_ROADMAP.md section 6, so folding them into the main package later is a file move.

```
cabal test drift-outputs
```

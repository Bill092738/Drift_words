# Protocol

The wire contract between the frontend and the backend. The overview is in [TECH_ROADMAP.md](../TECH_ROADMAP.md#3-the-shared-contract).

## Source of truth

`backend/src/Drift/Protocol.hs` defines every command, event and message. Everything else is derived from it:

| File | How it is produced |
| --- | --- |
| `frontend/src/protocol/generated.ts` | `drift-gen-ts` (aeson-typescript) from the Haskell types |
| `protocol/fixtures/*.jsonl` | `frontend/scripts/make-fixtures.ts`, typed against `generated.ts` |

Both are committed, so the frontend builds without a Haskell toolchain. CI regenerates them and fails if they differ from what is committed.

## Encoding

- Messages are JSON. Sum types are objects tagged with a `"type"` field, for example `{"type":"Pick","candidateId":3}`.
- Enum-like types are camelCase strings: `"en"`, `"branch"`, `"webPage"`.
- Optional fields are present and `null` when empty.
- Client to server: `{"req": <int>, "command": Command}`.
- Server to client: `{"type":"Events","events":[Stamped]}` or `{"type":"Rejected","req":<int>,"reason":"..."}`.
- `Stamped` is `{"seq": <int from 1>, "atMs": <unix ms>, "event": Event}`.

## Fixtures

Each fixture is a session's event log, one `Stamped` JSON object per line.

| Fixture | Use |
| --- | --- |
| `exploration.jsonl` | A whole session: cloud, streamed branches, sources, a backtrack, an inserted word, curation, wrap-up and outputs |
| `sources-heavy.jsonl` | A short path with sources of every kind and recorded node and source placements |

Titles, URLs and citation metadata in fixtures are illustrative test data. Some point to real works, but none are guaranteed to be accurate or reachable.

## Changing the contract

1. Edit `Protocol.hs`.
2. Run `make protocol` to regenerate `generated.ts` and the fixtures. Update `frontend/scripts/make-fixtures.ts` if the change needs new data.
3. Fix whatever the TypeScript compiler now reports. `EVENT_TYPES` in `frontend/src/protocol/index.ts` is checked against the generated union on purpose.
4. Commit the Haskell change, the generated file and the fixtures in the same pull request, and tell every track.

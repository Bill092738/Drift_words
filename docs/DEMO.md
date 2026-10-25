# Demo script

A 3-minute video that shows every part of Driftwords once, on a live Gemini session. Rehearse it twice before recording.

## Before you start

- [ ] `.env` (copy `.env.example`; it is gitignored) sets `GEMINI_API_KEY` and `DRIFT_CONFIG=config.gemini.yaml`. Add `OPENALEX_API_KEY=...` (free) too: without it, every machine on the venue's IP address shares about 100 paper searches a day. Never commit `.env`.
- [ ] Run `./start.sh`. It starts `drift-server` on :8080 with Gemini and the frontend dev server on :5173. (Or run `make server` and `make dev` in two terminals.) The server checks the key at startup and stops with a clear message if it is wrong.
- [ ] Open `http://localhost:5173/?live`. The bar should not stay on **Connecting…**, words should appear within a few seconds, and **Diagnostics** should be empty.
- [ ] The dev server always shows the developer tools (**DEV**, the session menu, **Diagnostics**, **Event log**) in the top bar. Crop them out of the recording, or record `make demo` at `http://localhost:8080/?live` instead: it serves a fresh build of the same frontend, where the bar shows only the name and the help button.
- [ ] Start a fresh session right before recording: **New session** in the bar, or open `/?live` again (without `?session=`).
- [ ] Close other tabs and turn off notifications. Use a browser window around 1440 × 900.
- [ ] In the help popover (**?**), leave the Accessibility switches off (they are kept per browser).

## The run (about 1:45 on screen)

The words come from Gemini, so they differ in every session. Pick whatever catches your eye; concrete words (an object, a place, an animal) find better images and papers.

| # | Action | What to point out |
| --- | --- | --- |
| 1 | Let the cloud drift for 3 seconds, then click a word | No prompt box: you only choose. The camera glides and a ring grows. |
| 2 | Pick 3 or 4 more words, one every few seconds | The path becomes a tree. Sources land on the desk behind the words: web pages, papers, images, audio. |
| 3 | Click an image source once, then again | First click lifts it; second opens the original (Commons, with its licence). |
| 4 | Drag the slider from **Close** to **Far** and pick once | The ring jumps further away: divergence is measured in embedding space. |
| 5 | Click an earlier word on the tree | Backtracking: a new ring grows from there. |
| 6 | Type one word in **Add your own word** and press Enter | The only typing in the tool: one word, never a sentence. |
| 7 | Open **Notes** (its tab shows a dot for new notes). Promote one note a few times, strike another | One cited note per step. Promote is one click per level; struck notes stay, crossed out. Switch **Path** / **Priority** to reorder. |
| 8 | Scroll to **References** at the bottom of the panel | Built from retrieved metadata (DOI, CSL), never from the model. |
| 9 | Press **Wrap up**, then **Wrap up now?** | Wait for **Your outputs**. |
| 10 | Show **Decision tree**, **Draft**, then **Final**; click **Word** under **Export the final document** | The final document keeps every note that is not struck; promoted ones weigh more. |

## If the network fails

- Open `http://localhost:5173/` without `?live`: it is the in-browser mock (**Interactive (mock)** in the session menu). It needs no server or network and shows the desk, rings, notes and sources.
- Keep a recorded run of the live demo as the fallback video.

## Narration (3:00)

About 400 words; no clip needs more than about 150 words a minute. Each row is one clip; leave a short pause between rows. The right column is what the clip earns in the judging guide. The demo part (0:15–1:24) is tight, so record the run first and cut it to the clips.

| Time | On screen | Narration | Covers |
| --- | --- | --- | --- |
| 0:00–0:15 | Title card (team, project), then the drifting cloud | We're team MyGO, team 56, and this is Driftwords. When you don't know what you want, a blank chat box doesn't help: you need a question before you can ask. Driftwords lets you think by choosing. | Team, project, problem (Impact) |
| 0:15–0:28 | Step 1 | This is the whole interface: drifting words, and no prompt. I pick the word that pulls at me, and a ring of related words grows around it. | Concept (Innovation) |
| 0:28–0:45 | Steps 2 and 3 | Gemini generates each ring live. My path becomes a tree, and sources land behind the words: Wikipedia pages, OpenAlex papers, images and audio from Wikimedia Commons. One click lifts a source; a second opens the original. | Execution |
| 0:45–0:57 | Steps 4 to 6 | The slider sets how far the next ring jumps, in embedding space. I can backtrack to any word, or type one word of my own. | Execution (Curiosity) |
| 0:57–1:12 | Steps 7 and 8 | Meanwhile, the notes panel writes one cited note for every step. I promote what matters and strike what doesn't. References come from retrieved metadata; the model never invents them. | Execution (Impact) |
| 1:12–1:24 | Steps 9 and 10 | When I'm done, I wrap up: a decision tree, a draft and a final document, ready as Markdown, HTML or Word. | Execution |
| 1:24–2:00 | The README's architecture diagram; move the pointer from left to right as the narration goes | Here's how it fits together. In the browser, our WebGPU engine draws the desk, and React handles the panels. Every click becomes a command over a WebSocket, using types generated from the Haskell server, so both sides agree. On the server, each session is one actor. It saves every event to a SQLite log first, and only then publishes it, so nothing you've seen is lost, even in a crash. Around it, workers prefetch the next rings, search sources, write notes and build the outputs, calling Gemini in the background. | Process (Breadth and complexity) |
| 2:00–2:35 | `backend/src/Drift/Server/SessionActor.hs`, then the test run (`make check`, 442 backend and 172 frontend tests passing) | Our biggest challenge was Haskell itself, and we chose it on purpose. Each session has prefetch, search and writing running at once. With Haskell's software transactional memory, their results reach the session without races or locks, and the types make a malformed event impossible to write. The price was a small ecosystem: there's no official Gemini SDK for Haskell, so we wrote our own model and search clients and our own Word exporter, and we chased a restart test that hung only on Linux. | Decisions and technical challenges (Challenge navigation) |
| 2:35–2:55 | A "What's next" card: hosted database, Docker, edge | And Haskell is proven at scale: Meta's spam-fighting system, Sigma, runs on it. Next, the event log can move to a hosted database like Postgres, and the server can ship as one Docker image to the cloud or the edge. | Future work (Impact, Curiosity) |
| 2:55–3:00 | Back to the desk, then the end card with "Narration: AI voice" in small text | Driftwords: explore by choosing, not chatting. Thank you. | Close |

### Ready for Q&A

- **The Linux hang.** The test started `drift-server` with its standard streams closed. On Linux and macOS the GHC runtime then reused file descriptor 1 for an internal pipe, the startup message went into it, and Warp never started listening. Pointing the streams at the null device fixed it (Windows was never affected).
- **Gemini 3 and the token limit.** Gemini 3 cannot turn thinking off and counts thinking against `max_tokens`, so our 96-token ring budget returned a single word. Each provider now has its own request settings (`kind: gemini` sends no limit, no temperature and `reasoning_effort: low`).
- **Moving off SQLite.** The event log is one module with five operations (open, close, create a session, load its events, append events), so a Postgres store replaces that module, not the actor.
- **Why the words feel instant.** After each ring, the server prefetches the ring of every word on offer: a pick that hits answers in 60 to 150 ms, against about 1.5 s for a miss.

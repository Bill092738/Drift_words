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

About 400 words: no clip needs more than about 150 words a minute. Each row is one clip; leave a short pause between rows. The right column is what the clip earns in the judging guide.

| Time | On screen | Narration | Covers |
| --- | --- | --- | --- |
| 0:00–0:20 | Title card, then the drifting cloud | We're team MyGO, team 56, and this is Driftwords. Sometimes you want to do something but don't know what. A blank chat box makes that worse: you have to know your question before you can ask it. Driftwords lets you think by choosing instead. | Team, project, problem (Impact) |
| 0:20–0:35 | Step 1 | This is the whole interface: a desk of drifting words, and no prompt. I pick the word that pulls at me, and a ring of related words grows around it. | Concept (Innovation) |
| 0:35–0:55 | Steps 2 and 3 | Each ring is generated live by Gemini. As I keep picking, my path becomes a tree. Behind the words, sources quietly land: Wikipedia pages, research papers from OpenAlex, images and audio from Wikimedia Commons. One click lifts a source, a second opens the original. | Execution |
| 0:55–1:10 | Steps 4 to 6 | The slider sets how far the next ring jumps, measured in embedding space. I can click any earlier word to go back, or type a single word. One word is the only typing in the whole tool. | Execution (Curiosity) |
| 1:10–1:30 | Steps 7 and 8 | Meanwhile, the notes panel has written one short, cited note for every step. I promote the ones that matter and strike the ones that don't. The references come from real retrieved metadata; the model never invents them. | Execution (Impact) |
| 1:30–1:45 | Steps 9 and 10 | When I'm done, I wrap up. Driftwords turns my path into a decision tree, a draft and a final document, ready to download as Markdown, HTML or Word. | Execution |
| 1:45–2:20 | The architecture diagram in the README | Under the hood, the backend is Haskell. Every session is an actor that saves each event to a SQLite log before showing it, so a reload, or even a server restart, brings back the exact desk. We chose a fast model for the rings and a larger one for the notes, because waiting kills curiosity, and the server prefetches the next ring for every word on offer, so most picks answer in about a tenth of a second. The desk itself is our own WebGPU engine on PixiJS. | Process and decisions (Breadth and complexity) |
| 2:20–2:50 | The commits or tests behind each fix | Three challenges stood out. Our restart test hung only on Linux: closed standard streams let the runtime reuse a file descriptor, so we pointed them at the null device. Gemini 3 counted its thinking against our token limit and returned a single word, so each provider now gets its own request settings. And every source looked the same, so each step now draws a mix of pages, papers, images and audio. | Technical challenges (Challenge navigation) |
| 2:50–3:00 | Back to the desk, then the title card | Driftwords: explore by choosing, not chatting. Thanks for watching. The narration in this video is AI-generated; the demo and the code are ours. | Close |

# Demo script

A 3-minute run that shows every part of Driftwords once. Rehearse it twice before recording.

## Before you start

- [ ] `export GEMINI_API_KEY=...` in the shell (never commit it). `drift-server` checks the key at startup and stops with a clear message if it is wrong.
- [ ] `export OPENALEX_API_KEY=...` (free). Without it, every machine on the venue's IP address shares about 100 paper searches a day.
- [ ] `make demo`, then open `http://localhost:8080/?live`. Add `&debug=1` if you want `window.__desk` in the console.
- [ ] Close other tabs and turn off notifications. Use a browser window around 1440 × 900.
- [ ] Open `http://localhost:8080/?live&dev` once and check **Diagnostics** in the top-left bar: it should be empty. Then record without `?dev`, so the bar shows only the name and the help button.
- [ ] In the help popover, leave the Accessibility switches off for the recording (they are kept per browser).

## The run (about 2 minutes on screen)

| # | Action | What to point out |
| --- | --- | --- |
| 1 | Let the cloud drift for 3 seconds, then pick **tide** | No prompt box: you only choose. The camera glides and a ring grows. |
| 2 | Pick **moon** from the ring | Words come from Gemini. Sources start dropping onto the desk behind the words. |
| 3 | Pick 3 more words, one every few seconds | The path is the thought. Point at an image source and an audio source as they land. |
| 4 | Click an image source once, then again | First click lifts it; second opens the Commons page with its licence. |
| 5 | Move the divergence slider to **Far** and pick once | The ring jumps further away: divergence is measured in embedding space. |
| 6 | Click an earlier word on the tree (backtrack) | A new ring grows from there; revisited words become section headings later. |
| 7 | Type one word in the box (for example **rhythm**) and press Enter | The only typing in the tool: one word, never a sentence. |
| 8 | Open **Notes**. Promote one note three times quickly, strike another | Promotion is one click per level; struck notes stay, crossed out. |
| 9 | Show the reference list at the bottom of the sidebar | References come from retrieved metadata (DOI, CSL), never from the model. |
| 10 | Press **Wrap up**, then **Wrap up now?** to confirm | The tree, the draft and the final document. |
| 11 | Open the final document, then download **Word** | Headings come from the backtracked words; only kept notes are in it. |

## If the network fails

- Open `/` without `?live`: it is the in-browser mock (**Interactive (mock)** in the `?dev` bar). It needs no server or network and shows the desk, rings, notes and sources.
- Keep a recorded run of the live demo as the fallback video.

## Video outline (3 minutes)

| Time | Content | Judging criterion |
| --- | --- | --- |
| 0:00–0:20 | Team and project name; the problem: brain fog, a blank prompt does not help | Impact |
| 0:20–1:50 | The run above, cut to the essentials | Innovation, Communication |
| 1:50–2:30 | How it works: Haskell event log, speculative prefetch, embedding divergence, grounded citations, WebGPU desk | Breadth and complexity |
| 2:30–2:50 | Challenges and fixes: a test that hung only on Linux, a provider that rejected temperature, sources that were all the same kind | Challenge navigation |
| 2:50–3:00 | What is next | Curiosity |

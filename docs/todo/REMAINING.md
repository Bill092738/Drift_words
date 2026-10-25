# Remaining work (Gemini-independent)

State of `main` at `0615ee2` (October 24, 2026, evening): M0 to M8 are merged. A live session explores with Gemini rings, drops sources, writes template notes, and wraps up into a decision tree, a draft and a final document with Markdown, HTML and Word downloads.

This list is everything left that does **not** depend on wiring Gemini into the notes. The Gemini items are listed at the end only so they are not done twice.

**Deadline:** hacking ends at **10:00 AM on Sunday, October 25**, and the 3-minute video is due then. Priorities:

| Priority | Meaning |
| --- | --- |
| **P0** | Needed for the demo |
| **P1** | Visible in the demo if done |
| **P2** | After the deadline |

---

## 1. Varied source types: images, audio, PDFs (P0) — done

> **Done** on `feature/remaining-todo`: Commons images and audio, OpenAlex PDFs, Wikipedia thumbnails, a weighted kind draw per edge with fallback, media relevance, and offline tests. A live run over 8 edges showed images, web pages, papers and audio. **Deviation:** the draw is seeded from the edge's words (path and both words), not the session and node ids, so `SourceRequest` did not need new fields; it is just as deterministic. Thumbnails come from `thumb.wikimedia.org`, which also sends `Access-Control-Allow-Origin: *`. Still to do by hand: the browser check in step 7.

### Problem

Every source on the desk is either a web card or a paper icon (see the screenshot in the conversation: only "Wikipedia" cards and paper sheets). **This is not Gemini's fault.** Source search makes no model call. The two providers each produce exactly one kind:

| Provider | Kind | Where |
| --- | --- | --- |
| Wikipedia | always `webPage`, `thumbnailUrl = Nothing` | `backend/src/Drift/Search/Wikipedia.hs:73,77` |
| OpenAlex | always `paper`, `thumbnailUrl = Nothing` | `backend/src/Drift/Search/OpenAlex.hs:99,103` |

The frontend already draws every kind (`frontend/src/desk/SourceObject.ts:269-280`):
- `image` shows a thumbnail loaded from `thumbnailUrl`, with `crossOrigin = 'anonymous'`;
- `audio` shows a speaker pill with level bars;
- `pdf` and `paper` show a file;
- `webPage` shows a web card.

The backend just never sends `image`, `audio` or `pdf`.

### Plan

1. **New provider: Wikimedia Commons** (`backend/src/Drift/Search/Commons.hs`). It needs no key; reuse the same `Fetch`, User-Agent and per-host gap. It uses one request per kind:

   ```
   https://commons.wikimedia.org/w/api.php?action=query&format=json
     &generator=search&gsrnamespace=6&gsrlimit=6
     &gsrsearch=filetype:bitmap|drawing <query>     (images)
     &gsrsearch=filetype:audio <query>              (audio)
     &prop=imageinfo&iiprop=url|mime|extmetadata&iiurlwidth=320
     &iiextmetadatafilter=LicenseShortName|Artist|ImageDescription|DateTimeOriginal
   ```

   I checked this live: `tide moon` returned 3 tide diagrams (PNG, CC BY-SA) and several audio files.

   **Map each result to a `SourceDraft`:**
   - `kind`: `Image` or `Audio`.
   - `title`: the file title without `File:` and without the extension.
   - `site`: `"Wikimedia Commons"`.
   - `url`: `descriptionurl`, the file page with its licence, so the second click opens it.
   - `thumbnailUrl`: `thumburl` for images. `upload.wikimedia.org` sends `Access-Control-Allow-Origin: *`, so the desk can use it as a texture. Audio has no thumbnail.
   - `hitSnippet`: the description from `ImageDescription`, after `plainText`.
   - `csl`: `type: "graphic"` for an image or `"song"` for audio, with `title`, `author` (from `Artist`, HTML stripped, as `literal`), `issued` (from `DateTimeOriginal`, when present), `URL`, and `container-title: "Wikimedia Commons"`. Keep the licence in `note`, because CC BY-SA requires attribution.

   **Filter out noise.** Audio search is full of pronunciation clips such as `En-us-tide.ogg` and `De-Tide.ogg`. Drop titles that match `^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?-` and anything shorter than 5 s, using `duration` from `imageinfo`. Keep only MIME types `image/*`, `audio/*` and `application/ogg`.

2. **PDFs from OpenAlex.** Add `best_oa_location` to the OpenAlex `select` (`OpenAlex.hs:44`).
   - When `best_oa_location.pdf_url` points to a PDF (the path ends in `.pdf`, or it is an arXiv `/pdf/` link), set `kind = Pdf` and `url = pdf_url`. Keep the DOI in the CSL, so the reference stays exact.
   - I checked this live: for `tides moon`, 4 of 6 open-access works had a PDF link (OUP, arXiv, drpress, ewadirect). Some `pdf_url` values are landing pages (`hdl.handle.net`, `dc.cod.edu`); those must stay `paper`.

3. **Wikipedia thumbnails.** The search response already has `thumbnail.url`, a protocol-relative URL (`//thumb.wikimedia.org/...`). Read it as `https:` + url into `thumbnailUrl`. Optional: also show it inside the web card in `SourceObject.webGlyph`.

4. **Random type mix per edge** (`backend/src/Drift/Pipeline/Sources.hs`).
   - Today every edge searches Wikipedia and OpenAlex and keeps at most 2 sources (`envMaxPerEdge = 2`, `providers` at lines 109-112).
   - Change this so that each edge draws **which kinds it wants** before searching, then queries only the providers for those kinds. This also saves OpenAlex budget.
   - Suggested weights, as constants so they are easy to tune: image 0.35, web page 0.25, paper or PDF 0.25, audio 0.15.
   - Draw 2 kinds without repeats. Seed from the session id and node id, so a test is deterministic.
   - **Fallback:** when a drawn kind finds nothing that passes the relevance check, fill the place from the other providers' passing results, best score first. That is the existing leftover pass. So an edge still gets sources whenever anything relevant exists.
   - Keep `envMaxPerEdge = 2`. Consider 3 when one of the kinds is audio, because audio matches less often.

5. **Relevance for media.** `heuristicVerdict` needs both words in the title or snippet and one of them in the title. Commons file titles are short, so for `Image` and `Audio` count the description as the title. Without that, few media pass.

6. **Tests**, offline, on saved real responses as the existing source specs do:
   - Commons fixtures for one image search and one audio search;
   - a parse test for each kind, and the pronunciation-clip filter;
   - the OpenAlex PDF and landing-page split;
   - the kind draw with a fixed seed;
   - the fallback when a drawn kind is empty.

7. **Check in the browser** in live mode with `?debug=1`: `window.__desk.debugSources()` should show a mix of kinds.
   - Images show their thumbnail.
   - Audio shows the speaker.
   - A second click opens the Commons page or the PDF.
   - The sidebar's reference list renders the new CSL types.

**Done when:** a 10-pick live session shows at least three different kinds on the desk, and no test calls the network.

---

## 2. Source quality (P1)

- [x] **Odd matches** (partly). Pre-1950 works are dropped when newer ones match, and cited works rank first. Not done: the "separate words" rule, because the tokenizer already splits on word boundaries; the Flint example is a proper-noun problem. The heuristic matches words, not meaning. Live examples: the edge Flint got a 1922 tunnel-kiln paper because its title mentions "Spark Plug Company, Flint"; Entropy got "Planetary migration". Cheap fixes:
  - drop OpenAlex works older than 1950 unless nothing else passes;
  - prefer works with `cited_by_count > 0`;
  - require the two words to be separate words in the title, not substrings of names.
- [x] **All-caps titles from OpenAlex** ("RHYTHMS, CYCLES AND PERIODS IN HEALTH AND DISEASE"). Convert them to title case for display only; the CSL stays as retrieved.
- [ ] **Before the demo, set `OPENALEX_API_KEY` in `.env`.** Sources are on by default, so every edge makes one OpenAlex search. Without a key there are about 100 searches a day, shared by everyone on the venue's IP address.

## 3. Sidebar (P1)

- [x] **Duplicate line in every note.** The header shows `Vintage → Provenance`, and the template relation repeats the same `Vintage → Provenance` (`frontend/src/chrome/sidebar/EntryItem.tsx:47-64`). Hide the relation line when it equals `from → to`. It will matter less once Gemini writes real relations, but it is what the demo shows now.
- [x] **Citation numbers with no text next to them** (shown as chips with the site name) (`3 4`, `11 12`) look like noise without an explanation. Consider showing them as source chips with the site name until notes have text.

## 4. Wrap-up and outputs (M8 follow-ups)

- [x] **P1. Stuck outputs.** Retried once automatically, then a second Wrap up retries; the server falls back to model-free outputs if building them throws. If the outputs generator throws, the UI shows "Writing your outputs…" forever. It is not retried in the same server process, and a second WrapUp does nothing (`SessionActor.hs`, `stateOutputsStarted`). Allow one retry, or fall back to model-free outputs.
- [ ] **P2. Slow final document.** The final document calls the model once per section, sequentially. A session with many backtracks waits many times 1.5 to 12 s. Run the sections concurrently.
- [x] **P2. Final title.** The title uses the last word of the whole path, even when that entry is struck. Use the last kept word.
- [ ] **P2. Word check.** Open a `.docx` export in real Microsoft Word once. So far it has only been checked structurally.

## 5. Server and developer experience

- [x] **P1. Readable diagnostics.** Strip the `HasCallStack backtrace…` text from diagnostics: show the provider's message only (`describe` in `SessionActor.hs` and the `show` in `SessionBranches.hs`).
- [x] **P1. API key errors.** Do not retry an authentication error (HTTP 400 "Invalid Auth key", 401, 403) three times. Report "Check GEMINI_API_KEY" at once. Also make one cheap `GET /models` call at startup, so a wrong key fails before the first pick. This would have caught the `C9FIH8` typo.
- [x] **P2. Event log page.** (labelled as a fixture replay) `?view=log` replays fixtures only and looks like the live log. Label it "fixture replay", or make it show the live session from `?session=`.
- [x] **P2. Startup message.** "listening" is printed before the port is bound. Print it after.
- [ ] **P2. Session ids.** Session ids (`session-<ms>-<counter>`) are guessable, and the WebSocket and export routes have no other check. This is fine on a laptop; use random ids before any public hosting.
- [ ] **P2. Streaming rings.** Rings arrive sealed, all words at once. Streaming word by word needs `offerBranches` and the actor to emit `CandidateStreamed` as words parse.

## 6. Desk and polish (M3, M9)

- [x] **P2. Reduced motion.** (rings and drift stop, and the setting is followed live) With reduced motion, drift and orbit still run on the desk (only the playground freezes movers). `DeskScene.ts:70` also reads the setting once, at construction, not live.
- [ ] **P2. Text LOD.** The real desk does not use text LOD (`WordTile.ts` uses a fixed resolution). Only the playground does.
- [ ] **P2. Long-press** (roadmap 5.6) is not implemented.
- [ ] **P2. Performance budgets** (roadmap 5.8) were never measured. Run the playground benchmark once on a laptop and a phone and record the numbers.
- [ ] **P0. Demo.** Script written in [docs/DEMO.md](../DEMO.md); rehearsing and recording remain.
  - Write a demo script: start word, about 10 picks, one backtrack, one typed word, promote and strike, wrap up, open the outputs, download Word.
  - Rehearse it with `make demo`.
  - Keep the mock mode ("Interactive (mock)") as the offline fallback if the venue network fails, and record a fallback video.
- [x] **P1. Docs.**
  - Update the README status line.
  - Tick off or delete the stale checklists in `docs/superpowers/plans/` (all boxes are unticked).
  - Remove `docs/todo/M6-sources-live.md` and `M7-sidebar-live.md` when they are superseded.

---

## Not in this list: the Gemini branch

These belong to the separate Gemini integration and are listed only to avoid duplicate work:
- [x] Notes written by Gemini 3.8 Flash. Done on `feature/gemini-notes`: the `writing` role runs `writeEntry` with one retry, a model note waits up to 3 s for its sources, and wrap-up waits up to 30 s for unfinished notes. The final document now keeps every note that is not struck.
- Divergence-band calibration for `gemini-embedding-001`. Distances between related words fall between 0.33 and 0.49.
- An optional model-backed `RelevanceJudge` for sources.

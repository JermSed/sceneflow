# Sceneflow — the cut agent

**Multi-App AI Agent Hackathon submission.** An agent that reads a hand-drawn
storyboard and turns it into a graded edit of your real footage — and files
everything it *couldn't* find as a shoot list.

Connects **Google Drive**, **DaVinci Resolve**, and **Todoist**, triggered from
inside **Sceneflow**, a native collaborative storyboarding canvas.

---

## 01 · Project overview

### The problem

Pre-production and post-production don't talk to each other.

A director boards a scene — twelve frames, each a rough sketch with a scribbled
slug line. The shoot happens. Two hundred clips land in a Drive folder named
after the date. Now somebody, usually an assistant editor at 1am, sits with the
storyboard open on one screen and the footage on the other and does the two
jobs nobody wants: work out which clip is which frame, and work out **which
frames were never shot at all**.

The second job is the one that costs money. A missed setup discovered in the
edit is a reshoot. A missed setup discovered on the day is five more minutes on
the schedule.

### What this does

Pin a comment on a Sceneflow board:

```
@claude cut this board  folder:"SceneFlowDemo"  list:"Reshoots"
```

The agent then, in one run:

1. **Reads the storyboard in order.** A Sceneflow board is spatial, not linear,
   so shot order is inferred: connector arrows are the director stating sequence
   explicitly and win; unwired frames fall back to reading order, left to right
   and wrapping into rows.
2. **Catalogs the footage in Google Drive** — every clip in the named folder,
   with duration, resolution, shoot date, and Drive's own poster frame.
3. **Matches beats to clips**, looking at both sides as pictures: each
   storyboard frame rendered from its raw strokes, each clip as its poster
   frame. Filenames are a signal, never the deciding one — real camera media is
   called `C0042.MP4`.
4. **Builds and grades the timeline in DaVinci Resolve.** Clips are imported,
   trimmed to the matched sub-range, laid down in storyboard order, and each one
   gets an ASC CDL derived from the beat's intended look ("cold dusk exterior").
   Every unshot beat becomes a red marker at the position in the cut where the
   shot belongs.
5. **Files every unshot beat to Todoist** — one task per missing frame, in a
   shoot-list project, **with the storyboard sketch attached as an image**, so
   whoever picks it up sees the drawing rather than a line of text.
6. **Reports back onto the board** as a pinned comment, next to the question.

The gaps are the product. An edit assistant that silently drops what it can't
match is worse than no assistant; this one is built so that *"I could not find
this shot"* is a first-class, well-typed output that lands on somebody's list.

### Why it's built on Sceneflow

Sceneflow is an existing project of mine: a native, offline-first, CRDT-based
collaborative canvas for cinematic pre-production (SwiftUI, iPad + macOS,
Automerge). The agent is **not** a special integration bolted onto it. It joins
a board the same way a second iPad does — a `Repo`, a WebSocket to the relay,
`repo.find(<share token>)` — and everything it says is an ordinary comment
appended to the same CRDT list the app renders.

That has a consequence worth stating plainly: **you can ask for a cut while
offline.** The request merges when you reconnect, the agent runs, and the report
merges back. No new sync code was written for any of this.

---

## 02 · External apps used

| App | What the agent does with it | How it connects |
|---|---|---|
| **Google Drive** | Catalogs the footage folder, pulls poster frames for visual matching, downloads only the clips that made the cut | Drive API v3 via `googleapis`, OAuth2, **read-only scope** |
| **DaVinci Resolve** (Studio) | Creates/opens the project, imports media, builds the timeline, trims each clip, applies a per-shot ASC CDL grade, marks the holes | Resolve's Python scripting API, driven through a JSON sidecar (`resolve_bridge.py`) |
| **Todoist** | Finds-or-creates the shoot-list project, files one task per unshot beat, attaches the storyboard sketch | REST API over HTTPS, with automatic v1/v2 version negotiation |
| *(Sceneflow)* | Trigger and report surface | Automerge CRDT over the sync relay — the agent is a peer, not a client |

Anthropic's API supplies the matching judgement (Claude, vision + structured
tool output).

---

## 03 · Setup

### Requirements

- Node 20+ (developed on 22)
- DaVinci Resolve **Studio** — the scripting API is Studio-only. Without it the
  agent degrades to writing a CMX3600 EDL, which is a real importable conform,
  not a mock.
- A Google account with footage in a Drive folder
- A Todoist account
- An Anthropic API key

### Install

```sh
git clone <this repo> && cd flow/agent
npm install
cp .env.example .env      # fill in ANTHROPIC_API_KEY and TODOIST_API_TOKEN
```

### Connect Google Drive

1. In [Google Cloud Console](https://console.cloud.google.com), create a project
   and **enable the Google Drive API**.
2. *Credentials → Create OAuth client ID → Desktop app*. Download the JSON and
   save it as `agent/.state/drive-client.json`.
3. On the *Audience* (OAuth consent) screen, add your own Google account under
   **Test users**.
4. `npm run auth:drive` — opens consent against a loopback redirect, stores the
   refresh token in `agent/.state/drive-token.json` (chmod 600, gitignored), and
   prints the account it connected as.

The scope requested is `drive.readonly`. The agent cannot modify your Drive.

### Enable Resolve scripting

Open DaVinci Resolve → *Preferences → System → General* → set
**"External scripting using"** to **Local**. Leave Resolve running.

### Bring up the Sceneflow relay and app

```sh
cd ../sync-server && npm install && npm start     # ws://localhost:3030
```

Open the Sceneflow app (`flow.xcodeproj`, Xcode → run on Mac or iPad), make a
board, sketch some frames, label them, and copy the share token from the share
sheet.

### Verify everything before you rely on it

```sh
cd agent
npm run eval:live
```

```
Sceneflow cut agent — live connectivity check

  anthropic  credentials present ... ok — env credential set
  drive      folder "SceneFlowDemo" ... ok — 11 clips, poster frames available
  todoist    list "Shoot List" ... ok — project 2349…, 0 open task(s), write+delete ok
  resolve    scripting connection ... ok — project "Sceneflow", timeline "Sceneflow Smoke Test"

4/4 checks passed.  Ready to cut.
```

### Run it

Two entry points, same code path:

```sh
# Watch a board and react to pinned comments (how it actually works)
npm start -- <documentId>

# Run one cut and print the full report (demos, CI, debugging)
npm run cut -- <documentId> --folder "SceneFlowDemo" --list "Reshoots"
npm run cut -- <documentId> --dry        # EDL instead of Resolve
```

---

## 04 · Reliability testing

Three layers, all runnable by a reviewer. The first two need **no credentials
and no network**.

### Layer 1 — `npm test` · 40 tests, no credentials required

The three external apps are injected through one seam (`REAL_APPS` in
`src/cut/run.js`), so the whole orchestration is exercised in milliseconds
against behavioral fakes — a fake Todoist that really stores tasks and really
dedupes, not a stub that counts calls.

```
# tests 40
# pass 40
# fail 0
```

What it actually asserts:

- **Ordering** — connectors beat position; a *cycle* in the arrows falls back to
  reading order instead of hanging or inventing a sequence; nearby text notes
  attach to a frame and distant ones don't.
- **Repair of model output** (`reconcile`) — a clip claimed by two beats, a
  hallucinated clip id, a beat the model forgot, an assignment for a beat that
  doesn't exist, and a grade of `slope: [99, -99, 0]` all produce a *valid,
  smaller* cut rather than a corrupt timeline. Nine adversarial cases.
- **Routing** — matched beats reach Resolve, unmatched beats reach Todoist, the
  two agree, and only clips that made the cut are downloaded.
- **Idempotency** — cutting the same board twice files **zero** duplicate tasks
  and creates no second project. Each task carries a stable `[sf:KEY]` marker
  derived from the frame's UUID; the second run recognizes its own prior work in
  an app that has never heard of Sceneflow.
- **Partial failure** — each app is failed in turn. Todoist down still yields a
  graded timeline. Resolve unavailable still files the shoot list, degrading to
  an EDL and *saying so* in the report. Drive unreachable puts the whole board on
  the shoot list rather than cutting a timeline out of nothing.
- **Connector internals** — the EDL is diffed against exact expected timecode
  (record times stay contiguous across a hole in the cut, ASC_SOP/ASC_SAT are
  emitted in standard form); the Todoist client's v1→v2 fallback, 429 retry with
  `Retry-After`, and loud failure on a bad token are all tested against a mocked
  fetch, so the real request-building code runs.

**Two real bugs this suite caught during the build**, both of which would have
been invisible in a demo:

- `frameKey` sliced the first 8 characters of the frame UUID. Against random v4
  UUIDs that looks fine; against structured ids every key collided, so only the
  *first* missing beat ever reached Todoist. Now an FNV-1a hash of the whole id,
  with a 500-id collision test pinning it.
- A model returning `saturation: null` passed the `Number.isFinite` guard as
  `0` — silently shipping a black-and-white cut. Empties now fall back to
  neutral.

### Layer 2 — `npm run eval` · scored against golden storyboards

Five fixture boards with known-correct answers, shaped exactly like real
Automerge documents and real Drive catalogs. The matcher runs N times per
fixture (default 3) and is scored on metrics that are deliberately *not*
averaged into one number, because the two failure modes aren't equally bad:

- **precision** — of the clips it placed, how many belonged there
- **recall** — of the beats that had footage, how many it found
- **decline accuracy** — of the beats with *no* footage, how many it correctly
  refused to fill. This is the number an eager model fails.
- **exact rate** and its **run-to-run standard deviation** — can the same board
  produce a different cut?

Plus **structural invariants** checked on every single run — no clip used twice,
every beat present and in order, no clip id outside the catalog, every CDL in
range. These are pass/fail, not scored: one violation means a corrupt timeline
was reachable, and the eval exits non-zero.

The fixtures are adversarial by design:

| fixture | what it tests |
|---|---|
| `tidy` | well-named footage, full coverage — anything under 100% is a bug |
| `gaps` | two clips for six beats; the correct answer is four declines |
| `carddump` | `C0042.MP4` — filenames carry *no* signal, only the image and duration do |
| `wired` | board laid out out-of-order with arrows drawn; connectors must win |
| `cycle` | arrows form a loop; must fall back, not hang |

`npm run eval -- --baseline` runs a deterministic filename-token matcher with no
API key and no network. It exists to be beaten — it scores 100% on `tidy` and
`gaps` and **0% on `carddump`**, which is exactly the gap the vision matcher has
to close, and makes "did the model help?" a number rather than a vibe:

```
     fixture beats clips precis recall decline  exact     ± falseFill
---------------------------------------------------------------------
        tidy     4     5   100%   100%     n/a   100%  0.00       0.0
        gaps     6     2   100%   100%    100%   100%  0.00       0.0
   carddump*     3     4    n/a     0%     n/a     0%  0.00       0.0
---------------------------------------------------------------------
     OVERALL               100%    67%    100%    67%             0.0

Structural invariant violations: 0
```

Results are written to `eval/results/` so runs can be compared.

### Layer 3 — `npm run eval:live` · does this machine actually reach all three apps

Everything above proves judgement and orchestration; none of it proves Drive is
authorized, the Todoist token is live, or Resolve is running with external
scripting enabled — which is the set of things that breaks five minutes before a
demo. The live check connects to each app for real (creating and then deleting a
throwaway Todoist task to prove writes work) and prints a pass/fail line each.

### Design choices that exist for reliability

- **The model may decline.** "No clip matches" is a first-class answer. A
  confidence below `SCENEFLOW_MATCH_THRESHOLD` (default 0.55) is downgraded to
  unmatched *by code* — a dial that can be tuned and measured, not the model's
  own restraint.
- **No stage can take down the run.** Every stage is recorded with a duration
  and an outcome; failures accumulate into `report.problems` and the run
  continues.
- **Resumability.** Downloads are cached by Drive id and the run report is
  persisted per board, so a run that dies at the Resolve stage re-runs without
  re-paying for anything.
- **Nothing is trusted twice.** Assignments are re-validated against the live
  catalog after matching, because the catalog can be empty (Drive failed) or
  stale (a clip moved mid-run).

---

## 05 · Demo video

**→ [two-minute demo](PASTE_LINK_HERE)**

---

## Repository layout

```
flow/
├── flow/                     Sceneflow — SwiftUI app (iPad + macOS)
├── sync-server/              Automerge relay (off-the-shelf)
├── flowTests/                Swift tests, incl. cross-runtime schema interop
└── agent/                    ← the hackathon build
    ├── src/
    │   ├── index.js          watcher: joins the board, reacts to comments
    │   ├── cut-cli.js        one-shot runner
    │   ├── schema.js         the Swift↔JS Automerge wire contract
    │   ├── render.js         board and single-frame → PNG
    │   ├── cut/
    │   │   ├── beats.js      board → ordered shot list (pure)
    │   │   ├── match.js      the judgement step + the repair layer (pure)
    │   │   └── run.js        the orchestrator; app injection seam
    │   └── apps/
    │       ├── drive.js          Google Drive
    │       ├── resolve.js        Resolve driver + EDL fallback
    │       ├── resolve_bridge.py Resolve's Python scripting API
    │       └── todoist.js        Todoist
    ├── test/                 40 tests, no credentials needed
    └── eval/                 golden fixtures, scoring harness, live smoke check
```

### A note on the cross-runtime schema

The Swift app and the JS agent write the *same* Automerge document, and Swift's
decoder is strict about scalar types. Automerge's JS "next" API turns a plain
string into a collaborative `Text` object, which Swift's `String` decode
rejects — and a board that fails to decode fails to *open*. Every string the
agent writes is therefore wrapped in `A.RawString`. The contract is enforced from
both sides: `npm test` on the JS side, and `flowTests/AgentInteropTests.swift`
decodes fixture bytes emitted by `agent/scripts/make-fixture.js` on the Swift
side.

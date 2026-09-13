# Sceneflow — the cut agent

**Multi-App AI Agent Hackathon · 2026**

An agent that reads a hand-drawn storyboard and assembles a graded edit from your
real footage — then files every shot you *didn't* film as a shoot list.

**Team:** Jeremy Sedillo — sedillojerm05@gmail.com
**Repository:** https://github.com/JermSed/sceneflow
**Demo video:** https://www.loom.com/share/246ff2bba8324d8a860407fea2394962

---

## Contents

1. [Project overview](#01--project-overview)
2. [External apps used](#02--external-apps-used)
3. [Setup](#03--setup)
4. [Reliability testing](#04--reliability-testing)
5. [Demo video](#05--demo-video)
6. [How it works](#how-it-works)
7. [Repository layout](#repository-layout)

---

## 01 · Project overview

### The problem

Pre-production and post-production don't talk to each other.

A director boards a scene — eight frames, each a rough sketch with a scribbled slug
line. The shoot happens. Two hundred clips land in a Drive folder named after the
date, called `C0417.MP4` through `C0421.MP4`. Now somebody, usually an assistant
editor at 1am, sits with the storyboard on one screen and the footage on the other
and does the two jobs nobody wants:

1. work out which clip is which frame, and
2. work out **which frames were never shot at all.**

The second job is the expensive one. A missed setup discovered in the edit is a
reshoot. Discovered on the day, it's five more minutes on the schedule.

### What it does

Pin a comment on a Sceneflow board:

```
@claude cut this board
```

The agent then, in a single run:

1. **Reads the storyboard in order.** A Sceneflow board is spatial, not linear, so
   shot order is inferred: connector arrows are the director stating sequence
   explicitly and win via topological order; unwired frames fall back to reading
   order, left to right, wrapping into rows.
2. **Catalogs the footage in Google Drive** — every clip in the named folder, with
   duration, resolution, shoot date, and Drive's own poster frame.
3. **Matches beats to clips as pictures.** Each storyboard frame is rendered from
   its raw strokes; each clip arrives as its poster frame. Filenames are a signal,
   never the deciding one — real camera media is called `C0042.MP4`.
4. **Builds and grades the timeline in DaVinci Resolve.** Clips are imported,
   trimmed to the matched sub-range, laid down in storyboard order, and each gets
   an ASC CDL derived from the beat's intended look. Every unshot beat becomes a
   red marker at the point in the cut where the shot belongs.
5. **Files every unshot beat to Todoist** — one task per missing frame, in a
   shoot-list project, **with the storyboard sketch attached as an image**.
6. **Reports back onto the board** as a pinned comment beside the question.

**The gaps are the product.** An edit assistant that silently drops what it can't
match is worse than no assistant. Here, *"I could not find this shot"* is a
first-class, well-typed output that lands on somebody's list.

### Why it's built on Sceneflow

Sceneflow is an existing project of mine: a native, offline-first, CRDT-based
collaborative canvas for cinematic pre-production (SwiftUI, iPad + macOS,
Automerge). The agent is **not** a special integration bolted onto it. It joins a
board exactly the way a second iPad does — a `Repo`, a WebSocket to the relay,
`repo.find(<share token>)` — and everything it says is an ordinary comment appended
to the same CRDT list the app renders.

One consequence worth stating plainly: **you can ask for a cut while offline.** The
request merges when you reconnect, the agent runs, and the report merges back. No
new sync code was written for any of this.

---

## 02 · External apps used

| App | What the agent does with it | Connection |
|---|---|---|
| **Google Drive** | Catalogs the footage folder, pulls poster frames for visual matching, downloads only the clips that make the cut | Drive API v3 via `googleapis`, OAuth2, **read-only scope** |
| **DaVinci Resolve** (Studio) | Creates/opens the project, imports media, builds the timeline, trims each clip, applies a per-shot ASC CDL grade, marks the gaps | Resolve's Python scripting API, driven through a JSON sidecar |
| **Todoist** | Finds-or-creates the shoot-list project, files one task per unshot beat, attaches the sketch | REST over HTTPS, with automatic v1/v2 version negotiation |
| *(Sceneflow)* | Trigger and report surface | Automerge CRDT over the sync relay — the agent is a **peer**, not a client |

Anthropic's API supplies the matching judgement (Claude, vision + structured tool
output).

---

## 03 · Setup

### Requirements

- Node 20+ (developed on 22)
- **DaVinci Resolve Studio** — the scripting API is Studio-only. Without it the
  agent degrades to writing a CMX3600 EDL: a real importable conform, not a mock.
- A Google account with footage in a Drive folder
- A Todoist account
- An Anthropic API key

### Install

```sh
git clone https://github.com/JermSed/sceneflow && cd sceneflow/agent
npm install
cp .env.example .env      # fill in ANTHROPIC_API_KEY and TODOIST_API_TOKEN
```

### Connect Google Drive

1. In [Google Cloud Console](https://console.cloud.google.com), create a project and
   **enable the Google Drive API**.
2. *Credentials → Create OAuth client ID → Desktop app*. Save the downloaded JSON as
   `agent/.state/drive-client.json`.
3. On the *Audience* (OAuth consent) screen, add your Google account under **Test
   users**.
4. `npm run auth:drive` — opens consent against a loopback redirect, stores the
   refresh token in `agent/.state/drive-token.json` (chmod 600, gitignored), and
   prints the account it connected as.

The scope requested is `drive.readonly`. The agent cannot modify your Drive.

### Enable Resolve scripting

Resolve → *Preferences → System → General* → **"External scripting using" → Local**.
Open a saved project (Resolve cannot create timelines inside the unsaved "Untitled
Project"). Leave Resolve running.

### Bring up the relay and the app

```sh
cd ../sync-server && npm install && npm start     # ws://localhost:3030
```

Open `flow.xcodeproj` in Xcode, run on My Mac, create a board, sketch frames, label
them, and copy the share token from the share sheet.

No board handy? `node scripts/seed-demo-board.js` generates one and prints a token.

### Verify before you rely on it

```sh
cd agent && npm run eval:live
```

```
Sceneflow cut agent — live connectivity check

  anthropic  credentials present ... ok — env credential set
  drive      folder "SceneFlowDemo" ... ok — 5 clips, poster frames available
  todoist    list "Shoot List" ... ok — project 6hVxWcQ4P9GvR4mp, 0 open task(s), write+delete ok
  resolve    scripting connection ... ok — project "SceneFlow", timeline "Sceneflow Smoke Test"

4/4 checks passed.  Ready to cut.
```

### Run it

```sh
# Watch a board and react to pinned comments (how it actually works)
npm start -- <documentId> --name "Catan night"

# Run one cut and print the full report (demos, CI, debugging)
npm run cut -- <documentId> --name "Catan night"
npm run cut -- <documentId> --dry        # EDL instead of Resolve
npm run cut -- <documentId> --no-grade   # assemble without grading
```

A comment can also carry options:
`@claude cut folder:"B-Roll Sept 12" list:Reshoots name:"Alley scene"`

---

## 04 · Reliability testing

Four layers. The first two need **no credentials and no network**.

### Layer 1 — `npm test` · 41 tests, no credentials required

The three external apps are injected through one seam (`REAL_APPS` in
`src/cut/run.js`), so the whole orchestration runs in milliseconds against
*behavioral* fakes — a fake Todoist that really stores tasks and really dedupes, not
a stub that counts calls.

```
# tests 41
# pass 41
# fail 0
```

What it asserts:

- **Ordering** — connectors beat position; a *cycle* in the arrows falls back to
  reading order instead of hanging or inventing a sequence; nearby text notes attach
  to a frame and distant ones don't.
- **Repair of model output** (`reconcile`) — a clip claimed by two beats, a
  hallucinated clip id, a beat the model forgot, an assignment for a beat that
  doesn't exist, and a grade of `slope: [99, -99, 0]` each produce a *valid, smaller*
  cut rather than a corrupt timeline. Ten adversarial cases.
- **Routing** — matched beats reach Resolve, unmatched beats reach Todoist, the two
  agree, and only clips that made the cut are downloaded.
- **Idempotency** — cutting the same board twice files **zero** duplicate tasks and
  creates no second project.
- **Partial failure** — each app is failed in turn. Todoist down still yields a
  graded timeline. Resolve unavailable still files the shoot list, degrading to an
  EDL and *saying so*. Drive unreachable puts the whole board on the shoot list
  rather than cutting a timeline out of nothing.
- **Connector internals** — the EDL is diffed against exact expected timecode
  (record times stay contiguous across a hole in the cut; ASC_SOP/ASC_SAT emitted in
  standard form); Todoist's v1→v2 fallback, 429 retry honoring `Retry-After`, and
  loud failure on a bad token run against a mocked fetch, exercising the real
  request-building code.

**Four real bugs this caught**, all of which would have been invisible in a demo:

| bug | consequence if shipped |
|---|---|
| `frameKey` sliced a UUID prefix; structured ids all collided | only the *first* missing beat ever reached Todoist |
| `saturation: null` passed a `Number.isFinite` guard as `0` | silently shipped a black-and-white cut |
| the CDL clamp allowed 4× the range the prompt asked for | the first real run came out visibly red |
| one Resolve marker per frame, consecutive gaps collide | 4 missing beats produced 2 markers |

### Layer 2 — `npm run eval` · scored against golden storyboards

Five fixture boards with known-correct answers, shaped exactly like real Automerge
documents and real Drive catalogs. The matcher runs N times per fixture and is scored
on metrics deliberately **not** averaged into one number, because the two failure
modes aren't equally bad:

- **precision** — of the clips it placed, how many belonged there
- **recall** — of the beats that had footage, how many it found
- **decline accuracy** — of the beats with *no* footage, how many it correctly
  refused to fill. *This is the number an eager model fails.*
- **exact rate** and its **run-to-run standard deviation** — can the same board
  produce a different cut?

Plus **structural invariants** on every run — no clip used twice, every beat present
and in order, no clip id outside the catalog, every CDL inside `CDL_RANGE` (the same
object the clamp uses, so the guardrail and its verification cannot drift). These are
pass/fail, and a violation exits non-zero.

Fixtures are adversarial by design:

| fixture | what it tests |
|---|---|
| `tidy` | well-named footage, full coverage — anything under 100% is a bug |
| `gaps` | two clips for six beats; the correct answer is four declines |
| `carddump` | `C0042.MP4` — filenames carry *no* signal, only the image and duration |
| `wired` | board laid out out-of-order with arrows drawn; connectors must win |
| `cycle` | arrows form a loop; must fall back, not hang |

`npm run eval -- --baseline` runs a deterministic filename-token matcher with no API
key and no network. It exists to be beaten:

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

It scores 100% on `tidy` and `gaps` and **0% on `carddump`** — which is exactly the
gap the vision matcher exists to close, and makes "did the model help?" a number
rather than a vibe. Results are written to `eval/results/`.

### Layer 3 — `npm run eval:live` · does this machine reach all three apps

Everything above proves judgement and orchestration; none of it proves Drive is
authorized, the Todoist token is live, or Resolve is running with scripting enabled —
the set of things that breaks five minutes before a demo. The live check connects to
each app for real, creating and then deleting a throwaway Todoist task to prove
writes work, and prints a pass/fail line each.

### Layer 4 — a real run, on real footage

Eight storyboard beats against five clips in Drive named `C0417.MP4`–`C0421.MP4`.
Abridged from the run report (`agent/.state/run-<docId>.json`):

```
[cut] 8 beats, ordered by connectors
[cut] Drive: 5 clips in "SceneFlowDemo"
[cut] matcher: asking claude-opus-4-8 to match 8 beats against 5 clips
[cut] matched 4/8 beats; 4 unshot
[cut]   ! beat 7: confidence 0.20 below 0.55 — treated as unshot
[cut] Drive: downloading C0417.MP4 (134 MB) ...
[resolve] importing 4 new clip(s) into the media pool
[resolve] created timeline 'Catan night — Sceneflow Cut'
[cut] Todoist: 4 task(s) filed, 0 already on the list
```

| stage | ms |
|---|---|
| `drive.catalog` | 1,495 |
| `match` | 31,967 |
| `drive.download` | 14,845 |
| `resolve.timeline` | 2,593 |
| `todoist.shotlist` | 8,563 |

`"problems": []`. Four clips placed and graded, four gap markers, four tasks filed.

**The matcher's own note on that run**, unprompted:

> *"Note conflict: beats 6 and 7 both want the hands-with-cards clip (C0420); I gave
> it to the OTS beat and flagged 7 as a gap — a human should confirm. Clip C0421
> (blurry hair/ceiling) appears to be an unusable card and was left unassigned."*

It caught a contested clip, made a call, flagged it for a human, and identified an
unusable take and refused to cut it in — from filenames that say nothing.

**The second run**, same board, clips already cached:

```
drive.download: 0ms          (cache hit)
Todoist: 0 task(s) filed, 5 already on the list
markers: 5
```

Idempotency on real infrastructure, not just in the fakes.

### Design choices that exist for reliability

- **The model may decline.** "No clip matches" is a first-class answer. Confidence
  below `SCENEFLOW_MATCH_THRESHOLD` (default 0.55) is downgraded to unmatched *by
  code* — a dial that can be tuned and measured, not the model's own restraint.
- **No stage can take down the run.** Every stage records a duration and an outcome;
  failures accumulate in `report.problems` and the run continues.
- **Resumability.** Downloads are cached by Drive file id and the report is persisted
  per board, so a run that dies at the Resolve stage re-runs without re-paying.
- **Nothing is trusted twice.** Assignments are re-validated against the live catalog
  after matching, because the catalog can be empty (Drive failed) or stale (a clip
  moved mid-run).

---

## 05 · Demo video

**→ [Two-minute demo](https://www.loom.com/share/246ff2bba8324d8a860407fea2394962)**

---

## How it works

```
  Sceneflow board                                    Sceneflow board
  (Automerge CRDT)                                   (pinned report)
        │                                                    ▲
        │  @claude cut this board                            │
        ▼                                                    │
  ┌─────────────────────────────────────────────────────────────┐
  │  beats     board → ordered shot list (connectors > position) │
  │  catalog   Google Drive: clips + poster frames               │
  │  match     Claude vision: sketch vs poster frame → assign    │
  │  reconcile deterministic repair of the model's output        │
  │  download  Google Drive: only the clips that won             │
  │  timeline  DaVinci Resolve: import, trim, order, grade, mark │
  │  shotlist  Todoist: one task per unshot beat + sketch        │
  └─────────────────────────────────────────────────────────────┘
```

**Grades are ASC CDL** — slope, offset, power, saturation. A real industry primitive
that round-trips to any NLE, and few enough numbers that a model can reason about it
and a human can read it back off the timeline to verify. The grade is a correction
applied to the footage the model can *see* in the poster frame, not a look painted
onto neutral grey.

**Idempotency lives in the external app.** Each frame carries a stable key (FNV-1a of
its UUID) embedded in Todoist task text as `[sf:KEY]`. A second run recognizes its own
prior work in an app that has never heard of Sceneflow.

---

## Repository layout

```
sceneflow/
├── flow/                     Sceneflow — SwiftUI app (iPad + macOS)
├── sync-server/              Automerge relay
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
    │   │   └── run.js        the orchestrator; app-injection seam
    │   └── apps/
    │       ├── drive.js          Google Drive
    │       ├── resolve.js        Resolve driver + EDL fallback
    │       ├── resolve_bridge.py Resolve's Python scripting API
    │       └── todoist.js        Todoist
    ├── test/                 41 tests, no credentials needed
    └── eval/                 golden fixtures, scoring harness, live smoke check
```

### A note on the cross-runtime schema

The Swift app and the JS agent write the *same* Automerge document, and Swift's
decoder is strict about scalar types. Automerge's JS "next" API turns a plain string
into a collaborative `Text` object, which Swift's `String` decode rejects — and a
board that fails to decode fails to *open*. Every string the agent writes is wrapped
in `A.RawString`. The contract is enforced from both sides: `npm test` on the JS side,
and `flowTests/AgentInteropTests.swift` decodes fixture bytes emitted by
`agent/scripts/make-fixture.js` on the Swift side.

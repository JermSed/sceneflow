# Sceneflow Assistant

A headless AI peer for Sceneflow boards. It joins a board through the
sync relay exactly like a second device — same `Repo`, same WebSocket,
same CRDT — and answers comments that mention `@assistant` (or
`@claude`) by pinning a reply comment next to the question.

Because the agent is just another Automerge peer, the app needed no
new sync code, and the collaboration properties extend to it for free:
ask a question while offline and the agent's answer merges in the next
time you connect.

## Run

```sh
npm install

# 1. Relay must be up (see ../sync-server):  npm start
# 2. Get the board's share token from the app's share sheet
#    (BoardSummary.documentIdString — the bs58 string in the link).
# 3. Credentials: export ANTHROPIC_API_KEY, or have an
#    `ant auth login` profile — the SDK finds either on its own.

node src/index.js <documentId> [--relay ws://localhost:3030]
```

The board must be announced to the relay at least once (open it in the
app while online) before the agent can find it.

### Plumbing test without an API key

`ASSISTANT_CANNED=1` replies with a fixed acknowledgement instead of
calling the model:

```sh
node scripts/e2e-device.js          # fake device: makes a board, waits
ASSISTANT_CANNED=1 node src/index.js <DOC_ID printed above>
```

## How a reply works

1. `repo.find(<share token>)` syncs the board in.
2. On every change, scan `comments` for pins that match the mention
   regex, aren't resolved, weren't authored by the agent, and have no
   comment pointing at them via `replyTo`.
3. Render the board to a PNG (`src/render.js` mirrors FieldView's
   geometry: elements centered at (x, y), frame strokes clipped, the
   question's pin ringed in red) and describe it as text (exact
   positions, distances, comment history), then send both to Claude
   with the question. Sanity-check what the model sees with
   `node scripts/render-preview.js <documentId>`.
4. Append a reply comment offset just below the original pin, carrying
   `replyTo: <original id>`.

Dedupe is CRDT-native: the "already answered" marker (`replyTo`) lives
in the same document as the question, so it survives restarts and
merges correctly across offline periods.

## The cut agent (`@claude cut`)

Answering questions is one of two things this peer does. The other is
assembling an edit across three external apps, triggered the same way
— a pinned comment:

```
@claude cut this board  folder:"SceneFlowDemo"  list:"Reshoots"  [dry]
```

| stage | app | what happens |
|---|---|---|
| `beats` | Sceneflow | board → ordered shot list; connectors beat position, cycles fall back to reading order |
| `drive.catalog` | Google Drive | every clip in the folder + its poster frame |
| `match` | Anthropic | each beat rendered as a picture vs each clip's poster frame; declines are first-class |
| `drive.download` | Google Drive | only the clips that won, cached by file id |
| `resolve.timeline` | DaVinci Resolve | import, trim, lay down in order, ASC CDL per shot, red markers on the holes |
| `todoist.shotlist` | Todoist | one task per unshot beat, sketch attached, deduped on `[sf:KEY]` |
| report | Sceneflow | pinned comment next to the question |

No stage can take down the run: each is recorded with an outcome and a
duration, failures accumulate in `report.problems`, and the report is
persisted to `.state/run-<docId>.json`.

The three apps are injected through `REAL_APPS` in `src/cut/run.js`.
That seam is why `npm test` can exercise the entire orchestration —
ordering, routing, idempotency, partial failure — with no Drive
account, no Resolve install, and no Todoist token.

### Commands

```sh
npm start -- <documentId>          # watch a board, react to comments
npm run cut -- <documentId>        # one cut, full JSON report on stdout
npm run cut -- <documentId> --dry  # write an EDL instead of driving Resolve
npm run auth:drive                 # one-time Google consent (drive.readonly)
npm test                           # 40 tests, no credentials needed
npm run eval                       # scored against golden storyboards
npm run eval -- --baseline         # deterministic matcher, no API key
npm run eval:live                  # is this machine actually connected?
```

See the root `README.md` for the full setup and the reliability write-up.

### Files added by the cut agent

- `src/cut/beats.js` — board → ordered shot list (pure)
- `src/cut/match.js` — the judgement step, and `reconcile()`, the repair layer
- `src/cut/run.js` — the orchestrator and the app-injection seam
- `src/cut-cli.js` — one-shot runner
- `src/apps/drive.js` — Google Drive (read-only OAuth)
- `src/apps/resolve.js` — Resolve driver + CMX3600 EDL fallback
- `src/apps/resolve_bridge.py` — Resolve's Python scripting API, JSON in/out
- `src/apps/todoist.js` — Todoist, with v1/v2 negotiation and retry
- `scripts/auth-drive.js` — one-time local OAuth flow
- `eval/` — golden fixtures, scoring harness, live connectivity check

## The schema contract (important)

The Swift app and this agent write the same Automerge document, and
Swift's `AutomergeDecoder` is strict about scalar types. The rules
live in `src/schema.js`; the one that bites is **strings**: automerge's
JS "next" API turns a plain JS string into a collaborative Text object,
which the Swift decoder rejects — the board would fail to open in the
app. Every string the agent writes must be wrapped in `A.RawString`.

The contract is enforced from both sides:

- `npm test` — JS side: mention/dedupe logic + scalar types after a
  save/load round trip.
- `flowTests/AgentInteropTests.swift` — Swift side: decodes fixture
  bytes produced by `scripts/make-fixture.js`. Regenerate the fixture
  (and paste the new base64 into that test) after any schema change
  here.

## Files

- `src/index.js` — CLI entry; Repo + WebSocket + watch/reply loop
- `src/schema.js` — read/write helpers honoring the Swift wire format
- `src/assistant.js` — pure logic: pending mentions, board description
- `src/render.js` — board → SVG → PNG so the model sees the sketches
- `src/respond.js` — the Claude API call (Opus 4.8, adaptive thinking, vision)
- `scripts/make-fixture.js` — emits bytes for the Swift interop test
- `scripts/e2e-device.js` — simulated device for relay-level testing
- `scripts/render-preview.js` — render a live board to PNG for eyeballing

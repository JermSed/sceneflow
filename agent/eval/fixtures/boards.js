// eval/fixtures/boards.js — golden storyboards with known answers.
//
// Each fixture is a board shaped exactly like the Automerge document
// the Swift app writes, a footage catalog shaped exactly like what
// Drive returns, and the ground truth: which clip each beat should
// match, or null where the beat was genuinely never shot.
//
// The fixtures are adversarial on purpose. A matcher that only reads
// filenames scores well on "tidy" and badly on "carddump"; a matcher
// that always guesses scores badly on "gaps" — where the right answer
// is to decline. Reporting per-fixture accuracy makes the failure
// modes visible instead of averaging them away.

let uid = 0;
const id = () => `00000000-0000-4000-8000-${String(++uid).padStart(12, "0")}`.toUpperCase();

const frame = (x, y, strokes = 3) => ({
  id: id(), x, y, z: 0, width: 800, height: 600,
  // Stroke geometry the renderer can draw; content is not the point
  // for the offline eval, presence is.
  strokes: Array.from({ length: strokes }, (_, i) => ({
    id: id(), color: 0x000000ff, width: 3,
    points: [{ x: 100 + i * 40, y: 120 }, { x: 500, y: 300 + i * 30 }, { x: 200, y: 480 }],
  })),
});

const note = (x, y, text) => ({ id: id(), x, y, z: 0, text, fontSize: 22, color: 0x111111ff });
const clip = (name, durationSeconds, extra = {}) => ({
  id: `drive-${name.replace(/[^A-Za-z0-9]/g, "")}`, name, mimeType: "video/quicktime",
  sizeBytes: 40_000_000, createdTime: "2026-09-01T18:00:00Z",
  durationSeconds, width: 3840, height: 2160, thumbnailLink: null, ...extra,
});

/** 1. TIDY — well-named footage, every beat covered. The easy case;
 * anything below 100% here is a bug, not a hard problem. */
function tidy() {
  const f = [frame(0, 0), frame(1000, 0), frame(2000, 0), frame(3000, 0)];
  const doc = {
    snapshots: f,
    texts: [
      note(0, 340, "WIDE - alley entrance, dusk"),
      note(1000, 340, "MEDIUM - Ana turns to the door"),
      note(2000, 340, "CLOSE UP - hand on the door handle"),
      note(3000, 340, "WIDE - alley empties out"),
    ],
    connectors: [], comments: [],
  };
  const clips = [
    clip("alley_wide_dusk_01.mov", 12),
    clip("ana_medium_turn_take3.mov", 6),
    clip("handle_cu_insert_02.mov", 4),
    clip("alley_wide_empty_end.mov", 9),
    clip("slate_and_sticks.mov", 3),
  ];
  const truth = {
    1: "drive-alleywidedusk01mov",
    2: "drive-anamediumturntake3mov",
    3: "drive-handlecuinsert02mov",
    4: "drive-alleywideemptyendmov",
  };
  return { name: "tidy", doc, clips, truth };
}

/** 2. GAPS — half the board was never shot. The correct answer is
 * four nulls; a matcher that fills them is actively harmful, because
 * a wrong clip in the timeline is worse than a task on the list. */
function gaps() {
  const f = [frame(0, 0), frame(1000, 0), frame(2000, 0), frame(0, 900), frame(1000, 900), frame(2000, 900)];
  const doc = {
    snapshots: f,
    texts: [
      note(0, 340, "WIDE - rooftop at golden hour"),
      note(1000, 340, "OTS - Ana over Ray's shoulder"),
      note(2000, 340, "INSERT - the letter, burning"),
      note(0, 1240, "CLOSE UP - Ray reacts"),
      note(1000, 1240, "DRONE - pull back off the roof"),
      note(2000, 1240, "WIDE - street below, night"),
    ],
    connectors: [], comments: [],
  };
  const clips = [
    clip("rooftop_wide_golden_01.mov", 14),
    clip("ana_ray_ots_take2.mov", 8),
  ];
  const truth = {
    1: "drive-rooftopwidegolden01mov",
    2: "drive-anarayotstake2mov",
    3: null, 4: null, 5: null, 6: null,
  };
  return { name: "gaps", doc, clips, truth };
}

/** 3. CARDDUMP — camera-original filenames carry no meaning, so the
 * only signal is the picture and the clip's duration/resolution.
 * This is the fixture that separates a real matcher from a string
 * comparison, and the one where the offline eval expects the
 * baseline to score near zero. */
function carddump() {
  const f = [frame(0, 0, 6), frame(1000, 0, 2), frame(2000, 0, 4)];
  const doc = {
    snapshots: f,
    texts: [
      note(0, 340, "WIDE - the whole kitchen, morning light"),
      note(1000, 340, "CLOSE UP - the kettle"),
      note(2000, 340, "MEDIUM - Ray at the table"),
    ],
    connectors: [], comments: [],
  };
  const clips = [
    clip("C0042.MP4", 22), clip("C0043.MP4", 5),
    clip("C0044.MP4", 11), clip("C0045.MP4", 2),
  ];
  // Ground truth by duration plausibility: the long take is the
  // establishing wide, the shortest is the insert.
  const truth = { 1: "drive-C0042MP4", 2: "drive-C0045MP4", 3: "drive-C0044MP4" };
  return { name: "carddump", doc, clips, truth, hard: true };
}

/** 4. WIRED — the board is out of reading order but the director
 * drew the arrows. Order is the assertion here, not matching:
 * connectors must beat position. */
function wired() {
  const a = frame(2000, 0), b = frame(0, 0), c = frame(1000, 0);
  const doc = {
    snapshots: [a, b, c],
    texts: [note(2000, 340, "shot one"), note(0, 340, "shot two"), note(1000, 340, "shot three")],
    connectors: [
      { id: id(), from: a.id, to: b.id },
      { id: id(), from: b.id, to: c.id },
    ],
    comments: [],
  };
  return { name: "wired", doc, clips: [], truth: {}, expectedOrder: [a.id, b.id, c.id], expectedOrderedBy: "connectors" };
}

/** 5. CYCLE — the arrows loop, so "sequence" is undefined. The
 * matcher must not hang or invent an order; it must fall back to
 * reading order and say so. */
function cycle() {
  const a = frame(0, 0), b = frame(1000, 0);
  const doc = {
    snapshots: [a, b],
    texts: [], comments: [],
    connectors: [
      { id: id(), from: a.id, to: b.id },
      { id: id(), from: b.id, to: a.id },
    ],
  };
  return { name: "cycle", doc, clips: [], truth: {}, expectedOrder: [a.id, b.id], expectedOrderedBy: "position" };
}

export const FIXTURES = [tidy(), gaps(), carddump(), wired(), cycle()];
export const MATCHABLE = FIXTURES.filter(f => Object.keys(f.truth).length > 0);

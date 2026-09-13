// eval/harness.js — scoring.
//
// "Did it work?" is not one number for this agent, because the two
// ways it can be wrong are not equally bad:
//
//   A FALSE FILL — putting a clip in the timeline that isn't the
//   beat — is the expensive error. It looks like success, an editor
//   has to notice it, and the beat never reaches the shoot list.
//
//   A MISS — leaving a beat unmatched that could have been matched
//   — is the cheap error. It shows up as a task on the shoot list,
//   someone glances at it and says "we shot that", and moves on.
//
// So the report separates them, and separates both from DECLINE
// ACCURACY: on beats that genuinely have no footage, did the agent
// correctly refuse to fill them? That last number is the one an
// eager model fails, and averaging it into an overall score is how
// you hide the failure.

/** Score one reconciled cut against ground truth. */
export function score(assignments, truth) {
  const m = {
    shouldMatch: 0, shouldDecline: 0,
    correctMatch: 0, falseFill: 0, wrongMatch: 0, miss: 0, correctDecline: 0,
  };
  for (const a of assignments) {
    const expected = truth[a.index];
    const got = a.clipId ?? null;
    if (expected === undefined) continue;
    if (expected === null) {
      m.shouldDecline += 1;
      got === null ? (m.correctDecline += 1) : (m.falseFill += 1);
    } else {
      m.shouldMatch += 1;
      if (got === expected) m.correctMatch += 1;
      else if (got === null) m.miss += 1;
      else m.wrongMatch += 1;
    }
  }
  const attempted = m.correctMatch + m.wrongMatch + m.falseFill;
  return {
    ...m,
    // Of the clips it placed, how many belonged there.
    precision: attempted === 0 ? null : m.correctMatch / attempted,
    // Of the beats that had footage, how many it found.
    recall: m.shouldMatch === 0 ? null : m.correctMatch / m.shouldMatch,
    // Of the beats with no footage, how many it correctly left alone.
    declineAccuracy: m.shouldDecline === 0 ? null : m.correctDecline / m.shouldDecline,
    // Every beat exactly right — the only metric a user feels.
    exact: m.correctMatch + m.correctDecline === m.shouldMatch + m.shouldDecline,
  };
}

/** Invariants that must hold no matter what the model said. A
 * violation here is a bug in the agent, not a bad prediction. */
export function checkInvariants(beats, clips, cut) {
  const violations = [];
  const clipIds = new Set(clips.map(c => c.id));

  if (cut.assignments.length !== beats.length) {
    violations.push(`returned ${cut.assignments.length} assignments for ${beats.length} beats`);
  }
  const indices = cut.assignments.map(a => a.index);
  if (new Set(indices).size !== indices.length) violations.push("a beat appears twice");
  if (indices.join() !== beats.map(b => b.index).join()) violations.push("beats are out of order");

  const used = cut.assignments.map(a => a.clipId).filter(Boolean);
  if (new Set(used).size !== used.length) violations.push("a clip is used by more than one beat");
  for (const id of used) if (!clipIds.has(id)) violations.push(`clip ${id} is not in the catalog`);

  for (const a of cut.assignments) {
    const g = a.cdl;
    if (!g) { violations.push(`beat ${a.index}: no grade`); continue; }
    const inRange = (v, lo, hi) => v.every(n => Number.isFinite(n) && n >= lo && n <= hi);
    if (!inRange(g.slope, 0.5, 2) || !inRange(g.offset, -0.2, 0.2) || !inRange(g.power, 0.5, 2)) {
      violations.push(`beat ${a.index}: grade out of range`);
    }
    if (!(g.saturation > 0 && g.saturation <= 2)) violations.push(`beat ${a.index}: saturation ${g.saturation}`);
  }
  return violations;
}

export function mean(xs) {
  const v = xs.filter(x => x != null);
  return v.length === 0 ? null : v.reduce((a, b) => a + b, 0) / v.length;
}

export function stdev(xs) {
  const v = xs.filter(x => x != null);
  if (v.length < 2) return 0;
  const m = mean(v);
  return Math.sqrt(v.reduce((s, x) => s + (x - m) ** 2, 0) / (v.length - 1));
}

export const pct = x => (x == null ? "  n/a" : `${(x * 100).toFixed(0).padStart(4)}%`);

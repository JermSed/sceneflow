#!/usr/bin/env python3
"""resolve_bridge.py — external app #2: DaVinci Resolve.

Resolve's automation surface is a Python module that only exists
inside a running Resolve install, so it cannot be driven from Node
directly. This script is the sidecar: it reads one JSON plan on
stdin, performs the whole timeline build inside a single Resolve
session, and writes one JSON result to stdout. Node never learns
anything about Resolve's object model, and this file never learns
anything about Automerge.

Every step is idempotent, because an assistant you can only run once
is an assistant nobody trusts:

  * media pool imports are keyed by file path — already-imported
    clips are reused, not duplicated;
  * the timeline is looked up by name before being created;
  * a rebuild deletes the timeline's items rather than appending a
    second copy of the cut underneath the first.

Usage (invoked by src/apps/resolve.js):
    python3 resolve_bridge.py < plan.json > result.json
"""

import json
import os
import sys

MAC_API = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
MAC_LIB = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"


def log(msg):
    """Progress goes to stderr so stdout stays a clean JSON channel."""
    print(f"[resolve] {msg}", file=sys.stderr, flush=True)


def connect():
    """Import Resolve's scripting module, setting up the search paths
    Blackmagic's installer only exports for interactive shells."""
    api = os.environ.get("RESOLVE_SCRIPT_API", MAC_API)
    lib = os.environ.get("RESOLVE_SCRIPT_LIB", MAC_LIB)
    os.environ.setdefault("RESOLVE_SCRIPT_API", api)
    os.environ.setdefault("RESOLVE_SCRIPT_LIB", lib)
    modules = os.path.join(api, "Modules")
    if modules not in sys.path:
        sys.path.append(modules)

    try:
        import DaVinciResolveScript as dvr
    except ImportError as exc:
        raise RuntimeError(
            "Could not import DaVinciResolveScript. Checked "
            f"{modules!r}. Resolve Studio must be installed; on macOS the "
            "module ships with it. Set RESOLVE_SCRIPT_API / RESOLVE_SCRIPT_LIB "
            "if you installed to a non-default location."
        ) from exc

    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        raise RuntimeError(
            "Resolve is not running, or external scripting is off. Open "
            "DaVinci Resolve and set Preferences > System > General > "
            "'External scripting using' to Local."
        )
    return resolve


def ensure_project(resolve, name):
    """Get us into a project called `name`, or say precisely why not.

    Resolve's ProjectManager is stateful in ways that make the naive
    load-then-create sequence fail constantly on a real machine:

      * `CreateProject` refuses a name that already exists *anywhere*
        in the project library, while `LoadProject` only looks in the
        CURRENT folder — so a project sitting in a bin fails both.
      * Resolve will not switch away from a project with unsaved
        changes, and reports that by returning None rather than by
        raising, so the failure reads as "could not create".

    Both return the same falsy value, which is why the first version
    of this function produced an error message that said nothing. So:
    save first, look in the root folder, and only then create — and if
    creation still fails, fall back to whatever project is open rather
    than aborting a run that could otherwise finish.
    """
    manager = resolve.GetProjectManager()

    current = manager.GetCurrentProject()
    if current is not None and current.GetName() == name:
        return current

    # Unsaved changes in the open project block every switch below.
    if current is not None:
        manager.SaveProject()

    manager.GotoRootFolder()

    existing = manager.GetProjectListInCurrentFolder() or []
    if name in existing:
        opened = manager.LoadProject(name)
        if opened:
            log(f"opened existing project {name!r}")
            return opened
        log(f"project {name!r} exists but would not load; trying a fresh name")
    else:
        opened = manager.LoadProject(name)
        if opened:
            log(f"opened existing project {name!r}")
            return opened

    created = manager.CreateProject(name)
    if created:
        log(f"created project {name!r}")
        return created

    # The name is taken somewhere we cannot reach, or the library is
    # in a state that refuses new projects here. A uniquely-named
    # project is a far better outcome than a failed run.
    from datetime import datetime
    fallback = f"{name} {datetime.now():%Y-%m-%d %H%M}"
    created = manager.CreateProject(fallback)
    if created:
        log(f"could not use {name!r}; created {fallback!r} instead")
        return created

    if current is not None:
        log(f"could not create a project; building in the open project {current.GetName()!r}")
        return current

    raise RuntimeError(
        f"Could not create or open a Resolve project named {name!r}, and no project is open. "
        f"Projects in the root folder: {existing or 'none'}. "
        f"Open any project in Resolve and try again."
    )


def index_media_pool(folder, found=None):
    """Every clip already in the pool, keyed by its file path, walking
    subfolders. Lets a re-run skip re-importing the same media."""
    if found is None:
        found = {}
    for clip in folder.GetClipList() or []:
        path = clip.GetClipProperty("File Path")
        if path:
            found[os.path.realpath(path)] = clip
    for sub in folder.GetSubFolderList() or []:
        index_media_pool(sub, found)
    return found


def import_media(project, paths):
    pool = project.GetMediaPool()
    existing = index_media_pool(pool.GetRootFolder())
    resolved = [os.path.realpath(p) for p in paths]
    missing = [p for p in resolved if p not in existing]

    if missing:
        log(f"importing {len(missing)} new clip(s) into the media pool")
        imported = pool.ImportMedia(missing) or []
        for clip in imported:
            path = clip.GetClipProperty("File Path")
            if path:
                existing[os.path.realpath(path)] = clip
    else:
        log("all clips already in the media pool")

    # Re-index once: ImportMedia can silently skip files Resolve
    # cannot decode, and we would rather report that than build a
    # timeline with holes we did not mention.
    existing = index_media_pool(pool.GetRootFolder(), existing)
    return existing, [p for p in resolved if p not in existing]


def ensure_timeline(project, name, rebuild):
    pool = project.GetMediaPool()
    for i in range(1, (project.GetTimelineCount() or 0) + 1):
        timeline = project.GetTimelineByIndex(i)
        if timeline and timeline.GetName() == name:
            if not rebuild:
                log(f"reusing timeline {name!r}")
                return timeline, False
            # Clear it in place so the timeline keeps its identity
            # (and anything the editor set on it) across rebuilds.
            items = timeline.GetItemListInTrack("video", 1) or []
            if items:
                project.SetCurrentTimeline(timeline)
                timeline.DeleteClips(items)
            log(f"cleared timeline {name!r} for rebuild")
            return timeline, False
    timeline = pool.CreateEmptyTimeline(name)
    if not timeline:
        raise RuntimeError(f"Could not create timeline {name!r}")
    log(f"created timeline {name!r}")
    return timeline, True


def build(plan):
    resolve = connect()
    project = ensure_project(resolve, plan["projectName"])
    pool = project.GetMediaPool()

    beats = plan["beats"]
    wanted = [b["clipPath"] for b in beats if b.get("clipPath")]
    pool_index, unreadable = import_media(project, wanted)

    timeline, _ = ensure_timeline(project, plan["timelineName"], plan.get("rebuild", True))
    project.SetCurrentTimeline(timeline)
    resolve.OpenPage("edit")

    placed, skipped = [], []
    for beat in beats:
        path = beat.get("clipPath")
        if not path:
            skipped.append({"beat": beat["index"], "reason": "no clip matched"})
            continue
        clip = pool_index.get(os.path.realpath(path))
        if clip is None:
            skipped.append({"beat": beat["index"], "reason": f"Resolve could not read {os.path.basename(path)}"})
            continue

        entry = {"mediaPoolItem": clip}
        # Trim to the matched sub-range when the matcher gave us one.
        # Resolve counts in frames; the plan speaks seconds because
        # that is what Drive metadata and the model both understand.
        fps = float(project.GetSetting("timelineFrameRate") or 24)
        if beat.get("startSeconds") is not None and beat.get("durationSeconds"):
            entry["startFrame"] = int(round(beat["startSeconds"] * fps))
            entry["endFrame"] = entry["startFrame"] + max(
                1, int(round(beat["durationSeconds"] * fps)) - 1
            )

        appended = pool.AppendToTimeline([entry])
        if not appended:
            skipped.append({"beat": beat["index"], "reason": "AppendToTimeline refused the clip"})
            continue
        placed.append({"beat": beat["index"], "clip": os.path.basename(path)})

    graded = grade(timeline, beats)
    marked = mark_missing(timeline, project, beats)

    return {
        "ok": True,
        "project": project.GetName(),
        "timeline": timeline.GetName(),
        "placed": placed,
        "skipped": skipped,
        "unreadable": [os.path.basename(p) for p in unreadable],
        "graded": graded,
        "markers": marked,
        "trackItemCount": len(timeline.GetItemListInTrack("video", 1) or []),
    }


def grade(timeline, beats):
    """Apply each beat's ASC CDL to the clip that landed on the
    timeline. CDL is the right primitive here: it is a real,
    industry-standard grade (slope / offset / power / saturation),
    it round-trips to any other NLE, and — unlike a node graph — it
    is a handful of numbers a model can reason about and a human can
    read back off the timeline to check the agent did what it said."""
    items = timeline.GetItemListInTrack("video", 1) or []
    with_clips = [b for b in beats if b.get("clipPath")]
    applied = []
    for item, beat in zip(items, with_clips):
        cdl = beat.get("cdl")
        if not cdl:
            continue
        ok = item.SetCDL({
            "NodeIndex": "1",
            "Slope": cdl["slope"],
            "Offset": cdl["offset"],
            "Power": cdl["power"],
            "Saturation": str(cdl["saturation"]),
        })
        if ok:
            applied.append({"beat": beat["index"], "look": beat.get("look", "")})
    return applied


def mark_missing(timeline, project, beats):
    """Unshot beats become red markers on the timeline, positioned
    where the shot belongs. The editor opening this project sees the
    holes in the cut without reading a report — and the same beats
    are the ones filed to Todoist, so the two apps agree."""
    fps = float(project.GetSetting("timelineFrameRate") or 24)
    start = int(timeline.GetStartFrame() or 0)
    cursor = start
    added = []
    for beat in beats:
        if beat.get("clipPath"):
            cursor += max(1, int(round((beat.get("durationSeconds") or 3) * fps)))
            continue
        ok = timeline.AddMarker(
            max(0, cursor - start),
            "Red",
            f"MISSING - Frame {beat['index']}",
            f"{beat.get('description', '')} [sf:{beat.get('key', '')}]",
            1,
        )
        if ok:
            added.append({"beat": beat["index"], "frame": cursor - start})
    return added


def main():
    try:
        plan = json.load(sys.stdin)
    except Exception as exc:
        json.dump({"ok": False, "error": f"bad plan on stdin: {exc}"}, sys.stdout)
        return 1
    try:
        json.dump(build(plan), sys.stdout)
        return 0
    except Exception as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        return 1


if __name__ == "__main__":
    sys.exit(main())

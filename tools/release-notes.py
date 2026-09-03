#!/usr/bin/env python3
"""Render the notes for a data release cut: what moved in the index.

A cut carries the store-path artifacts whose bytes changed, which says
nothing about what the channel did. The index diff is the interesting
part and is otherwise buried in a multi-megabyte commit diff nobody
opens, so it goes on the release, the only per-run artifact with a
stable URL and a watch notification.

The diff is taken against a git revision, `HEAD` by default. That works
because update-index.yml cuts the release *before* committing: at cut
time the working tree holds the new index and HEAD still holds the
previous one. A cut taken by hand after the commit has landed sees no
difference at all, and says so rather than reporting a row of zeroes.

Everything here is a summary of committed facts. Release notes are
mutable and unverified, so nothing reads them back: data-pins.json
stays the manifest.

Usage:
  tools/release-notes.py --files outpaths-x86_64-linux.json ...
  tools/release-notes.py --base HEAD~1
"""

import argparse
import json
import os
import subprocess
import sys

# The standing sentence, kept at the top of every cut's notes: it is what
# tells a reader the assets are addressed rather than browsed.
MANIFEST_NOTE = (
    "Automated dated cut of the store-path artifacts. Addressed by "
    "data-pins.json; assets on this tag are immutable. See "
    "docs/store-paths.md."
)

# A cut either opens its release or tops up one an earlier cut of the
# same day made. The standing sentence belongs at the top of a release,
# not repeated in a section appended below one that already carries it.
MODE_CUT = "cut"
MODE_TOP_UP = "top-up"

# A channel bump moves hundreds of attr versions at once, so the lists
# are capped. Bumps are ranked by the length of the reign that ended: a
# version that held the tip for months giving way is news, the fifth
# nightly bump of a -unstable attr is not. Arrivals and departures at
# the tip are alphabetical.
BUMPS_SHOWN = 20
ARRIVED_SHOWN = 25
GONE_SHOWN = 25


def fmt(n):
    return f"{n:,}"


def sign(delta):
    if delta == 0:
        return "—"
    return f"+{fmt(delta)}" if delta > 0 else f"-{fmt(-delta)}"


def git_show(root, base, path):
    proc = subprocess.run(
        ["git", "-C", root, "show", f"{base}:{path}"],
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    return json.loads(proc.stdout)


def git_base_label(root, base):
    proc = subprocess.run(
        ["git", "-C", root, "log", "-1", "--format=%h %cs", base],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    short, date = proc.stdout.split()
    return f"`{short}` ({date})"


def runs_of(raw):
    """history.json stores one [lo, hi] pair or a list of them; hi is
    null while the version still holds the tip."""
    if not raw:
        return []
    if isinstance(raw[0], list):
        return raw
    return [raw]


def tip_version(versions, tip):
    """The version an attr ships at revision `tip`, or None."""
    for version, raw in versions.items():
        for lo, hi in runs_of(raw):
            if lo <= tip and (hi is None or hi >= tip):
                return version
    return None


def index_facts(history, revisions, releases):
    tip = history["revisionCount"] - 1
    at_tip = {}
    package_versions = 0
    for attr, versions in history["attrs"].items():
        package_versions += len(versions)
        v = tip_version(versions, tip)
        if v is not None:
            at_tip[attr] = v
    return {
        "revisions": history["revisionCount"],
        "tip_off": tip,
        "tip_label": f"{revisions[tip]['date']}-{revisions[tip]['rev'][:12]}",
        "attrs": len(history["attrs"]),
        "at_tip": at_tip,
        "package_versions": package_versions,
        "channels": {name: rel["rev"] for name, rel in releases.items()},
    }


def reign(history, revisions, attr, version):
    """How long `version` held the tip before this cut ended it:
    (revisions, days), from its last run."""
    lo, hi = runs_of(history["attrs"][attr][version])[-1]
    if hi is None:
        hi = history["revisionCount"] - 1
    days = (_day(revisions[hi]["date"]) - _day(revisions[lo]["date"])).days
    return hi - lo + 1, days


def _day(iso):
    from datetime import date

    return date.fromisoformat(iso)


def carried_line(files):
    """Name the whole-set artifacts; a pile of period shards is a count."""
    whole = sorted(os.path.basename(f) for f in files if "/shards/" not in f)
    shards = sum(1 for f in files if "/shards/" in f)
    parts = [f"`{name}`" for name in whole]
    if shards:
        noun = "period shard" if shards == 1 else "period shards"
        parts.append(f"{fmt(shards)} {noun}")
    return "Carries " + ", ".join(parts) + "."


def store_path_rows(data_dir):
    """Per-system tip store-path counts, from the artifacts beside the
    cut. The old counts are not in git, so these rows carry no delta."""
    rows = []
    if not os.path.isdir(data_dir):
        return rows
    for name in sorted(os.listdir(data_dir)):
        if not (name.startswith("tip-outpaths-") and name.endswith(".json")):
            continue
        doc = json.load(open(os.path.join(data_dir, name)))
        count = sum(len(v) for v in doc.get("attrs", {}).values())
        rows.append((f"store paths at tip ({doc.get('system', name)})", count))
    return rows


def render(root, mode, files, base, data_dir):
    history = json.load(open(os.path.join(root, "index/history.json")))
    revisions = json.load(open(os.path.join(root, "revisions.json")))
    releases = json.load(open(os.path.join(root, "releases.json")))
    now = index_facts(history, revisions, releases)

    old_history = git_show(root, base, "index/history.json")
    old_revisions = git_show(root, base, "revisions.json")
    old_releases = git_show(root, base, "releases.json")

    out = []
    if mode == MODE_CUT:
        out.append(MANIFEST_NOTE)
        out.append("")
    if files:
        out.append(carried_line(files))
        out.append("")

    if old_history is None or old_revisions is None:
        out.append(
            f"{fmt(now['revisions'])} revisions indexed, tip "
            f"`{now['tip_label']}`. No baseline at `{base}` to diff "
            f"against; the numbers above describe the current index only."
        )
        return "\n".join(out) + "\n"

    old = index_facts(old_history, old_revisions, old_releases or {})

    if old["tip_off"] == now["tip_off"] and old["tip_label"] == now["tip_label"]:
        out.append(
            f"{fmt(now['revisions'])} revisions indexed, tip "
            f"`{now['tip_label']}` — unchanged since `{base}`. A cut taken "
            f"after the index commit landed sees no difference."
        )
        return "\n".join(out) + "\n"

    # what the channel did between the two tips
    bumped = [
        (attr, was, now["at_tip"][attr])
        for attr, was in old["at_tip"].items()
        if attr in now["at_tip"] and now["at_tip"][attr] != was
    ]
    arrived = sorted(a for a in now["at_tip"] if a not in old["at_tip"])
    gone = sorted(a for a in old["at_tip"] if a not in now["at_tip"])

    base_label = git_base_label(root, base) or f"`{base}`"
    new_revs = now["revisions"] - old["revisions"]
    out.append(
        f"{fmt(now['revisions'])} revisions indexed "
        f"({sign(new_revs)} since {base_label}), tip `{now['tip_label']}`. "
        f"At the tip: {fmt(len(bumped))} version bumps, "
        f"{fmt(len(arrived))} attrs arrived, {fmt(len(gone))} gone."
    )
    out.append("")

    rows = [
        ("revisions", now["revisions"], now["revisions"] - old["revisions"]),
        ("attrs ever indexed", now["attrs"], now["attrs"] - old["attrs"]),
        (
            "attrs at tip",
            len(now["at_tip"]),
            len(now["at_tip"]) - len(old["at_tip"]),
        ),
        (
            "package-versions",
            now["package_versions"],
            now["package_versions"] - old["package_versions"],
        ),
        (
            "channels followed",
            len(now["channels"]),
            len(now["channels"]) - len(old["channels"]),
        ),
    ]
    out.append("| | now | change |")
    out.append("| --- | --- | --- |")
    for label, value, delta in rows:
        out.append(f"| {label} | {fmt(value)} | {sign(delta)} |")
    for label, value in store_path_rows(data_dir):
        out.append(f"| {label} | {fmt(value)} | — |")
    out.append("")

    # channel movements are rare and always worth a line
    moved = [
        f"- `{name}` → `{releases[name]['rev'][:12]}` ({releases[name]['date']})"
        for name, rev in now["channels"].items()
        if old["channels"].get(name) not in (None, rev)
    ]
    new_channels = [
        f"- `{name}` first followed, at `{releases[name]['rev'][:12]}`"
        for name in now["channels"]
        if name not in old["channels"]
    ]
    if moved or new_channels:
        out.append("### Channels")
        out.append("")
        out.extend(new_channels + moved)
        out.append("")

    if bumped:
        ranked = sorted(
            bumped,
            key=lambda b: reign(old_history, old_revisions, b[0], b[1]),
            reverse=True,
        )
        out.append(f"### Version bumps at tip ({fmt(len(bumped))})")
        out.append("")
        for attr, was, is_now in ranked[:BUMPS_SHOWN]:
            revs, days = reign(old_history, old_revisions, attr, was)
            noun = "day" if days == 1 else "days"
            out.append(
                f"- `{attr}` {was} → {is_now} — ended a reign of "
                f"{fmt(days)} {noun} ({fmt(revs)} revisions)"
            )
        if len(bumped) > BUMPS_SHOWN:
            out.append("")
            out.append(f"…and {fmt(len(bumped) - BUMPS_SHOWN)} more.")
        out.append("")

    if arrived:
        out.append(f"### Arrived at tip ({fmt(len(arrived))})")
        out.append("")
        for attr in arrived[:ARRIVED_SHOWN]:
            marker = "" if attr in old_history["attrs"] else " (new attr)"
            out.append(f"- `{attr}` {now['at_tip'][attr]}{marker}")
        if len(arrived) > ARRIVED_SHOWN:
            out.append("")
            out.append(f"…and {fmt(len(arrived) - ARRIVED_SHOWN)} more.")
        out.append("")

    if gone:
        out.append(f"### Gone from tip ({fmt(len(gone))})")
        out.append("")
        for attr in gone[:GONE_SHOWN]:
            out.append(f"- `{attr}` (was {old['at_tip'][attr]})")
        if len(gone) > GONE_SHOWN:
            out.append("")
            out.append(f"…and {fmt(len(gone) - GONE_SHOWN)} more.")
        out.append("")

    return "\n".join(out).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(__file__)))
    ap.add_argument("--mode", choices=[MODE_CUT, MODE_TOP_UP], default=MODE_CUT)
    ap.add_argument("--files", nargs="*", default=[])
    ap.add_argument("--base", default="HEAD")
    ap.add_argument(
        "--data-dir",
        default=None,
        help="outpaths data dir for store-path counts "
        "(default: <root>/index/.outpaths/data)",
    )
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    data_dir = args.data_dir or os.path.join(root, "index/.outpaths/data")
    sys.stdout.write(render(root, args.mode, args.files, args.base, data_dir))


if __name__ == "__main__":
    main()

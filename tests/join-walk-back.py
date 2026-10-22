#!/usr/bin/env python3
"""Tests that tools/join-eval-listing.py walks a pair back to its newest
finished build, and that a full run and a chain of incremental runs agree.

    python3 tests/join-walk-back.py [path/to/join-eval-listing.py]

A pair's digest comes from its newest revision. When Hydra did not finish that
build, the version used to drop out of the artifacts the day the tip moved onto
it, even though the build served the day before still substituted (issue #28).
The join now steps back through the version's newest run of revisions and takes
the newest build a listing vouches for.

Six revisions, one timeline, every case it has to tell apart:

  ok      built at every revision: the plain row, no offset
  cutter  current at the tip, built at r0-r2, broken from r3: the tip row is
          r2's build, its `man` output with it
  closer  1.0 closed at r3, built at r0-r1 only: the closed row is r1's build
  back    1.0 at r0, 2.0 at r1, 1.0 again from r2 and never built there: a
          miss, because the walk stays inside the newest run and r0 is not in it
  never   never built anywhere: a miss

The timeline is joined twice: once in full at the newest cut, and once as a
full run at the second revision followed by an incremental run per revision
after it, each given only the evaluations and listings an hourly runner would
have on disk. The two must write the same rows. Listing membership is the only
proof used, so nothing touches the network.
"""
import json
import os
import pickle
import subprocess
import sys
import tempfile

DEFAULT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "tools",
    "join-eval-listing.py",
)
SYSTEM = "aarch64-darwin"
N_REVS = 6
# The cut the incremental chain starts from: the first two revisions, joined
# in full, the way a backfill seeds the hourly job.
SEED_CUT = 1


def digest(tag):
    """A 32-character digest named for what it is, so a failure reads."""
    return (tag + "-" * 32)[:32].replace("-", "0")


def outputs(attr, rev):
    """The digests an attribute evaluates to at a revision: a new build every
    revision, as a stdenv bump would give. Only cutter has a second output."""
    outs = {"out": digest(f"{attr}{rev}")}
    if attr == "cutter":
        outs["man"] = digest(f"{attr}{rev}man")
    return outs


# attr -> one version per revision, oldest first.
SHIPPED = {
    "ok": ["1.0"] * N_REVS,
    "cutter": ["1.0"] * N_REVS,
    "closer": ["1.0"] * 4 + ["2.0"] * 2,
    "back": ["1.0", "2.0"] + ["1.0"] * 4,
    "never": ["1.0"] * N_REVS,
}

# attr -> the revisions Hydra finished it at.
BUILT = {
    "ok": range(N_REVS),
    "cutter": range(3),
    "closer": [0, 1, 4, 5],
    "back": [0, 1],
    "never": [],
}


def write(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)


def index_at(cut):
    """versions.json and history.json as the indexer writes them at `cut`:
    newest offset per version, runs per version, null for what is current."""
    versions, history = {}, {}
    for attr, shipped in SHIPPED.items():
        runs = {}
        for off in range(cut + 1):
            ver = shipped[off]
            blocks = runs.setdefault(ver, [])
            if blocks and blocks[-1][1] == off - 1:
                blocks[-1][1] = off
            else:
                blocks.append([off, off])
        versions[attr], history[attr] = {}, {}
        for ver, blocks in runs.items():
            last = blocks[-1][1]
            if last == cut:
                blocks[-1][1] = None
            versions[attr][ver] = None if last == cut else last
            history[attr][ver] = blocks[0] if len(blocks) == 1 else blocks
    head = {"revisionCount": cut + 1}
    return {**head, "attrs": versions}, {**head, "attrs": history}


def write_revision(work, revs, off):
    """One revision's evaluation and listing, as tools/eval-outpaths.sh and
    tools/fetch-store-paths.py leave them on disk."""
    evaluated = {
        attr: {"name": f"{attr}-{shipped[off]}", "outputs": outputs(attr, off)}
        for attr, shipped in SHIPPED.items()
    }
    write(f"{work}/eval/{revs[off]['rev']}.{SYSTEM}.e-l.json", {"attrs": evaluated})
    listed = {
        d
        for attr, offs in BUILT.items()
        if off in offs
        for d in outputs(attr, off).values()
    }
    with open(f"{work}/paths/{off}.digests.pkl", "wb") as f:
        pickle.dump({"digests": listed}, f)


def join(script, revs, cut, offsets, out, prev=None):
    """Run the join at `cut` with only `offsets` on disk, and read back the
    rows it wrote. The head is left out: its counters say how a row was
    reached, which is exactly what differs between a full and an incremental
    run."""
    work = f"{out}.in"
    os.makedirs(f"{work}/eval")
    os.makedirs(f"{work}/paths")
    write(f"{work}/revisions.json", revs)
    versions, history = index_at(cut)
    write(f"{work}/versions.json", versions)
    write(f"{work}/history.json", history)
    for off in offsets:
        write_revision(work, revs, off)

    cmd = [
        sys.executable,
        script,
        "--revisions",
        f"{work}/revisions.json",
        "--versions",
        f"{work}/versions.json",
        "--history",
        f"{work}/history.json",
        "--eval-dir",
        f"{work}/eval",
        "--paths-dir",
        f"{work}/paths",
        "--system",
        SYSTEM,
        "--out-dir",
        out,
    ]
    if prev:
        cmd += ["--prev-dir", prev]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)

    def read(name):
        with open(f"{out}/{name}-{SYSTEM}.json") as f:
            return json.load(f)

    return {
        "closed": read("outpaths")["attrs"],
        "tip": read("tip-outpaths")["attrs"],
        "outs": read("outs"),
        "misses": read("misses"),
    }


def main():
    script = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SCRIPT
    failures = []

    def check(what, got, want):
        if got != want:
            failures.append(f"{what}: got {got!r}, want {want!r}")

    revs = [{"rev": f"{i:040d}", "date": f"2026-01-0{i + 1}"} for i in range(N_REVS)]
    tip = N_REVS - 1

    with tempfile.TemporaryDirectory() as work:
        # The backfill: every revision on disk, nothing to carry over.
        full = join(script, revs, tip, range(N_REVS), f"{work}/full")

        check("ok is written plainly", full["tip"].get("ok"), {"1.0": [digest("ok5")]})
        check(
            "cutter at the tip is its newest finished build",
            full["tip"].get("cutter"),
            {"1.0": [digest("cutter2"), "cutter-1.0", 2]},
        )
        check(
            "cutter's sibling output comes from the same build",
            full["outs"].get(digest("cutter2")),
            {"man": digest("cutter2man")},
        )
        check(
            "closer 1.0 closed at r3 is r1's build",
            full["closed"].get("closer"),
            {"1.0": [digest("closer1"), "closer-1.0", 1]},
        )
        check(
            "back 2.0 resolves at its own revision",
            full["closed"].get("back"),
            {"2.0": [digest("back1")]},
        )
        missed = {(a, v) for a, v, _ in full["misses"]}
        check(
            "back 1.0 does not reach outside its newest run",
            ("back", "1.0") in missed,
            True,
        )
        check("never misses", ("never", "1.0") in missed, True)

        # The hourly job: a full seed, then one incremental run per revision,
        # each handed the previous run's output and only the revisions from
        # the previous coverage onwards, as tools/update-outpaths.sh fetches.
        prev = f"{work}/cut{SEED_CUT}"
        join(script, revs, SEED_CUT, range(SEED_CUT + 1), prev)
        incremental = None
        for cut in range(SEED_CUT + 1, N_REVS):
            out = f"{work}/cut{cut}"
            incremental = join(script, revs, cut, range(cut - 1, cut + 1), out, prev)
            prev = out

        for key in ("closed", "tip", "outs"):
            check(f"incremental {key} matches full", incremental[key], full[key])

        # Which pairs miss, not why: an incremental run has no evaluation for
        # a pair that missed before its coverage, and says so, where the full
        # run names what it found there.
        check(
            "incremental misses the same pairs as full",
            sorted((a, v) for a, v, _ in incremental["misses"]),
            sorted((a, v) for a, v, _ in full["misses"]),
        )

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print("join-walk-back: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

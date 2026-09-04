#!/usr/bin/env python3
"""Tests what tools/consolidate-outpaths.py is willing to claim about a path.

    python3 tests/store-liveness.py [path/to/consolidate-outpaths.py]

An entry in info-indexed is a claim somebody looked, and its first field is a
404 rather than a shrug. A digest nothing has evidence for has to be left out
of the file, because a verdict once published is carried forward by every run
with nothing newer to say — so a row invented from no fetch is read back as a
finding and copied forward for as long as the artifacts live. See
docs/store-paths.md, "Absence is not death".

Four seed digests, one per case the consolidation has to tell apart, over
three small files: no crawl and no network.
"""
import gzip
import json
import os
import subprocess
import sys
import tempfile

DEFAULT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "tools",
    "consolidate-outpaths.py",
)

# A digest is 32 characters, and these four are named for the case they carry.
CRAWLED, GONE, BACK, UNSEEN = (c * 32 for c in "abcd")

SEEDS = {
    "revisionCount": 1,
    "attrs": {
        "crawled": {"1.0": [CRAWLED]},
        "gone": {"1.0": [GONE]},
        "back": {"1.0": [BACK]},
        "unseen": {"1.0": [UNSEEN]},
    },
}

# `back` is how the weekly census writes a resurrection: liveness alone, for a
# path it already knows, with no references attached.
GRAPH = [
    {
        "d": CRAWLED,
        "ok": True,
        "name": "crawled-1.0",
        "ns": 100,
        "fs": 40,
        "url": "nar/a.nar.zst",
        "refs": [],
    },
    {"d": GONE, "ok": False},
    {"d": BACK, "ok": True},
]

# The previously published cut: sizes and a name for everything it knew, `back`
# recorded dead, and references and a closure for `back` that the liveness-only
# record above must leave standing.
PREV_INFO = {
    GONE: [1, 200, 80, "gone-1.0", "nar/b.nar.zst"],
    BACK: [0, 300, 120, "back-1.0", "nar/c.nar.zst"],
}
PREV_REFS = {BACK: ["e" * 32 + "-libc-2.42"]}
PREV_CLOSURES = {BACK: [999, 2, 0]}


def write_inputs(work):
    """The three files a consolidation reads, in a directory of their own."""
    seeds = os.path.join(work, "outpaths-x86_64-linux.json")
    with open(seeds, "w") as f:
        json.dump(SEEDS, f)

    graph = os.path.join(work, "graph.jsonl.gz")
    with gzip.open(graph, "wt") as f:
        for rec in GRAPH:
            f.write(json.dumps(rec) + "\n")

    prev = os.path.join(work, "prev")
    os.makedirs(prev)
    for stem, obj in [
        ("info-indexed", PREV_INFO),
        ("refs-indexed", PREV_REFS),
        ("closures", PREV_CLOSURES),
    ]:
        with gzip.open(os.path.join(prev, f"{stem}.json.gz"), "wt") as f:
            json.dump(obj, f)

    return seeds, graph, prev


def read(out_dir, name):
    return json.load(gzip.open(os.path.join(out_dir, name), "rt"))


def main():
    script = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SCRIPT

    with tempfile.TemporaryDirectory() as work:
        seeds, graph, prev = write_inputs(work)
        out_dir = os.path.join(work, "out")
        subprocess.run(
            [
                sys.executable,
                script,
                "--seeds",
                seeds,
                "--graph",
                graph,
                "--prev-dir",
                prev,
                "--out-dir",
                out_dir,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )

        info = read(out_dir, "info-indexed.json.gz")
        refs = read(out_dir, "refs-indexed.json.gz")
        closures = read(out_dir, "closures.json.gz")

    # A digest nobody has ever looked at carries no entry. This is the whole
    # test: a `0` here renders on the site as "no longer in the cache".
    assert UNSEEN not in info, info

    # A fresh crawl is authoritative in both directions, and a death keeps the
    # sizes and name the path had — its history is still true, only its
    # liveness changed.
    assert info[CRAWLED] == [1, 100, 40, "crawled-1.0", "nar/a.nar.zst"], info
    assert info[GONE] == [0, 200, 80, "gone-1.0", "nar/b.nar.zst"], info

    # A resurrection flips liveness without claiming to know anything else, so
    # the references and closure the crawl found still stand behind it.
    assert info[BACK] == [1, 300, 120, "back-1.0", "nar/c.nar.zst"], info
    assert refs[BACK] == PREV_REFS[BACK], refs
    assert closures[BACK] == PREV_CLOSURES[BACK], closures

    print(f"{len(info)} of {len(SEEDS['attrs'])} seed digests have a verdict")


if __name__ == "__main__":
    main()

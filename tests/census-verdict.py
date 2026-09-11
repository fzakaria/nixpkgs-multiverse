#!/usr/bin/env python3
"""Tests which census outcomes tools/census.py is willing to call a death.

    python3 tests/census-verdict.py [path/to/census.py]

A census death is published: it goes into missingNar, gets appended to the
crawl graph as {"ok": false}, and from there every consolidation marks the
path dead until a later census contradicts it. So the only outcome allowed to
write one is a cache that answered. A request that ran out of retries answered
nothing, and the tool says so itself: "a digest that timed out through every
retry is unknown, not dead". See docs/store-paths.md, "Absence is not death".

The retry budget is spent on the NAR HEAD far more often than on the narinfo
GET, since narinfos are edge-cached and NAR objects are not. The census of
2026-09-06 called 30 NARs missing and cache.nixos.org served all 30 on
re-check, which is what this pins.

Four seed digests, one per outcome, with the transport stubbed: no network.
"""
import gzip
import importlib.util
import json
import os
import sys
import tempfile

DEFAULT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools", "census.py"
)

# A digest is 32 characters, and these four are named for the outcome they
# carry: both requests answered, the NAR answered 404, the NAR answered
# nothing, the narinfo answered nothing.
ALIVE, NAR_GONE, NAR_MUTE, INFO_MUTE = (c * 32 for c in "abcd")

NARINFO = "StorePath: /nix/store/{d}-pkg\nURL: nar/{d}.nar.xz\n"

# What the stubbed cache answers, per digest: the narinfo GET, then the HEAD
# of the NAR it names. None is the tool's "out of retries".
ANSWERS = {
    ALIVE: (200, 200),
    NAR_GONE: (200, 404),
    NAR_MUTE: (200, None),
    INFO_MUTE: (None, None),
}


def load(path):
    """census.py as a module. Its name is fine, but the path is a store path."""
    spec = importlib.util.spec_from_file_location("census", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stub_request(method, path):
    """The cache, answering out of ANSWERS. Keyed by the digest in the path."""
    digest = os.path.basename(path).split(".")[0]
    narinfo, nar = ANSWERS[digest]
    if method == "GET":
        body = NARINFO.format(d=digest).encode() if narinfo == 200 else b""
        return narinfo, body
    return nar, b""


def run_census(census, tmp):
    """One whole census over the four digests, into a fresh graph and result."""
    seeds = os.path.join(tmp, "outpaths-test.json")
    with open(seeds, "w") as f:
        json.dump(
            {
                "revisionCount": 1,
                "attrs": {
                    "alive": {"1.0": [ALIVE]},
                    "nar-gone": {"1.0": [NAR_GONE]},
                    "nar-mute": {"1.0": [NAR_MUTE]},
                    "info-mute": {"1.0": [INFO_MUTE]},
                },
            },
            f,
        )

    graph = os.path.join(tmp, "graph.jsonl.gz")
    with gzip.open(graph, "wt"):
        pass
    out = os.path.join(tmp, "census-results.json")

    sys.argv = [
        "census.py",
        "--seeds",
        seeds,
        "--out",
        out,
        "--graph",
        graph,
        "--threads",
        "2",
        "--date",
        "2026-09-10",
    ]
    census.main()

    with gzip.open(graph, "rt") as f:
        appended = [json.loads(line) for line in f if line.strip()]
    return json.load(open(out)), appended


def main():
    census = load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SCRIPT)
    census.RETRY_BACKOFF_SECONDS = 0
    # The cache, for both the single verdicts and the whole run below.
    census.Worker.request = lambda self, method, path: stub_request(method, path)

    # The four outcomes, each read straight off one worker's verdict. A worker
    # built this way has no queue and no stats, which is all check() needs
    # once its transport is the stub.
    worker = census.Worker.__new__(census.Worker)

    alive = worker.check(ALIVE)
    assert alive["narinfo"] and alive["nar"], alive
    assert not alive.get("err"), alive

    # A 404 on the NAR is the cache answering that the bytes are gone, which
    # is the one death worth publishing.
    gone = worker.check(NAR_GONE)
    assert gone["narinfo"] and not gone["nar"], gone
    assert not gone.get("err"), gone

    # A narinfo that never answered is unknown, which the tool already gets
    # right.
    mute_info = worker.check(INFO_MUTE)
    assert mute_info.get("err"), mute_info

    # A NAR HEAD that never answered is unknown for exactly the same reason,
    # and this is the outcome that was published as a death.
    mute_nar = worker.check(NAR_MUTE)
    assert mute_nar.get("err"), f"a timed-out NAR HEAD was called a death: {mute_nar}"

    # And what the whole run publishes: one alive, one death, two unknowns.
    with tempfile.TemporaryDirectory() as tmp:
        summary, appended = run_census(census, tmp)

    assert summary["total"] == 4, summary
    assert summary["checked"] == 2, summary
    assert summary["unreachable"] == 2, summary
    assert summary["missingNarinfo"] == [], summary
    assert summary["missingNar"] == [NAR_GONE], summary

    # Only the answered death reaches the graph. A record for either mute
    # digest would be carried forward by every consolidation after it.
    assert appended == [{"d": NAR_GONE, "ok": False}], appended

    print("a census death needs an answer from the cache")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Tests tools/shard-outs.py, which decides what a page can look up.

    python3 tests/outs-shards.py [path/to/shard-outs.py]

The artifacts it shards are 5 MB each and the reader has one digest, so the
split has to put every digest in the shard that reader will ask for and
nowhere else, under a directory named for the system it belongs to. What it
has to get right beyond that is what not to publish: a sibling that repeats
the digest being asked about answers nothing, and an entry left empty by
dropping those is a fetch that finds a key and learns nothing from it. And
outs-indexed.json.gz sits in the same directory under the same prefix, so
sharding it as if it were a system is a live mistake.
"""
import json
import os
import subprocess
import sys
import tempfile

DEFAULT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "tools",
    "shard-outs.py",
)

# The systems whose artifacts the data directory holds.
SYSTEMS = ["x86_64-linux", "aarch64-linux"]

# Four digests over three shards, in the shape outs-<system>.json has: the out
# path's digest to its siblings' digests. `jq` is the ordinary case, `ffmpeg`
# shares a shard with it, `hello` is single-output but the join recorded its
# own `out`, and `zlib` has one real sibling beside that self-reference.
OUTS = {
    "d91mwgs15hv4ajza7jn6axyiwa07ga7m": {
        "bin": "1b2h5nxkqfnjplzcp4wbmw2rdpcbrsxi",
        "dev": "vf4jc9lgsx4kya7xk1lqz9zvvw8mzhjb",
    },
    "d9zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz": {
        "lib": "9pxlmn0zw4rcpv1c8bkbdxzjkjcrfd7g",
    },
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
        "out": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
    "0zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz": {
        "out": "0zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
        "bin": "0b2h5nxkqfnjplzcp4wbmw2rdpcbrsxi",
    },
}

# A digest belongs to one system, so the alternate's artifact shares no key
# with the primary's — as the real pair does.
ALT_OUTS = {
    "b7q0hs2p0nfz2f6l2mkzkc9ph0lcxk3v": {
        "bin": "wm5xk7ns6zgg1vqcv8mnl3blx6gncc0f",
    },
}


def load(directory):
    """Every shard in a directory, as {shard key: entries}."""
    return {
        name[: -len(".json")]: json.load(open(os.path.join(directory, name)))
        for name in sorted(os.listdir(directory))
    }


def main():
    script = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SCRIPT

    with tempfile.TemporaryDirectory() as work:
        datadir = os.path.join(work, "data")
        out = os.path.join(work, "site")
        os.makedirs(datadir)
        os.makedirs(out)
        for system, outs in zip(SYSTEMS, (OUTS, ALT_OUTS)):
            with open(os.path.join(datadir, f"outs-{system}.json"), "w") as f:
                json.dump(outs, f)
        # The decoy: same directory, same prefix, gzipped, and keyed by
        # derivation name rather than by digest.
        with open(os.path.join(datadir, "outs-indexed.json.gz"), "wb") as f:
            f.write(b"\x1f\x8b not a system")

        subprocess.run([sys.executable, script, datadir, out], check=True)

        written = sorted(name for name in os.listdir(out) if name.startswith("outs"))
        primary = load(os.path.join(out, f"outs-{SYSTEMS[0]}"))
        alt = load(os.path.join(out, f"outs-{SYSTEMS[1]}"))

    # Every directory names its system, so a reader that has a digest and knows
    # the system it belongs to has the URL, with no rule to apply about which
    # one an unsuffixed directory would hold. And outs-indexed is not a system.
    assert written == ["outs-aarch64-linux", "outs-x86_64-linux"], written

    # A reader holding a digest fetches one file, named by the digest's first
    # two characters, and finds the digest in it.
    assert sorted(primary) == ["0z", "d9"], sorted(primary)
    assert set(primary["d9"]) == {
        "d91mwgs15hv4ajza7jn6axyiwa07ga7m",
        "d9zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
    }, primary["d9"]
    assert alt["b7"]["b7q0hs2p0nfz2f6l2mkzkc9ph0lcxk3v"] == {
        "bin": "wm5xk7ns6zgg1vqcv8mnl3blx6gncc0f",
    }, alt

    # Every suffix the join recorded is published: this is the index, and a
    # consumer that wants `dev` is as entitled to it as one that wants `bin`.
    assert primary["d9"]["d91mwgs15hv4ajza7jn6axyiwa07ga7m"] == {
        "bin": "1b2h5nxkqfnjplzcp4wbmw2rdpcbrsxi",
        "dev": "vf4jc9lgsx4kya7xk1lqz9zvvw8mzhjb",
    }, primary["d9"]

    # A sibling that is the path being asked about is dropped, and the entry
    # keeps what survives that.
    assert primary["0z"]["0zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"] == {
        "bin": "0b2h5nxkqfnjplzcp4wbmw2rdpcbrsxi",
    }, primary["0z"]

    # A package whose only sibling was itself is not published at all: an
    # entry a reader can find and learn nothing from costs a fetch and a
    # branch at every consumer.
    assert "aa" not in primary, primary
    assert sum(len(entries) for entries in primary.values()) == 3, primary

    print(f"{len(primary)} shards for {SYSTEMS[0]}, {len(alt)} for {SYSTEMS[1]}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Shard the sibling-output maps by digest, for readers that have one digest.

Usage: shard-outs.py <datadir> <out>
  datadir: the pinned artifacts, holding outs-<system>.json
  out:     the site tree to write into

The maps (docs/store-paths.md, "Multi-output packages") are one 5 MB document
per system, keyed by the `out` path's digest. `fast.*` reads one whole, which
is the right shape for evaluation: one file, already fetched, and a point
lookup costs nothing. A page has one digest and wants one answer, so it gets
the same split the meta and identify shards use:

  outs-<system>/<xx>.json
  {"<out digest>": {"bin": "<digest>", "lib": "<digest>", ...}}

Two characters of the digest gives around a thousand shards per system, a few
KB each. Every system is named, this one included, since a digest belongs to
exactly one of them and a reader that has to work out which directory holds
the default has been handed a rule instead of a name.

The systems are whatever artifacts are there. Which is why the glob ends in
`.json`: outs-indexed.json.gz shares the prefix and is a different artifact,
keyed by derivation name.
"""
import argparse
import collections
import glob
import json
import os

SHARD_LENGTH = 2


def shard_system(source, out_dir):
    """Split one outs-<system>.json into out_dir, returning what was kept."""
    with open(source) as f:
        outs = json.load(f)

    shards = collections.defaultdict(dict)
    kept = 0
    for digest, siblings in outs.items():
        # An output that is the path being asked about answers nothing, and an
        # entry holding only those is a fetch that finds a key and learns
        # nothing from it.
        wanted = {
            suffix: sibling for suffix, sibling in siblings.items() if sibling != digest
        }
        if not wanted:
            continue
        shards[digest[:SHARD_LENGTH]][digest] = wanted
        kept += 1

    os.makedirs(out_dir, exist_ok=True)
    for shard, entries in shards.items():
        with open(os.path.join(out_dir, f"{shard}.json"), "w") as f:
            json.dump(entries, f, separators=(",", ":"), sort_keys=True)
    return kept, len(shards)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("datadir", help="directory holding outs-<system>.json")
    parser.add_argument("out", help="the site tree to write into")
    args = parser.parse_args()

    for source in sorted(glob.glob(os.path.join(args.datadir, "outs-*.json"))):
        directory = os.path.basename(source)[: -len(".json")]
        kept, count = shard_system(source, os.path.join(args.out, directory))
        print(f"{directory}: {kept} paths over {count} shards")


if __name__ == "__main__":
    main()

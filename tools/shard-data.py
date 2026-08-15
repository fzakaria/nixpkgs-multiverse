#!/usr/bin/env python3
"""Shard the big graph artifacts by the closing period of their digests.

The whole-set consumers (the site build, mvs) always read every shard, so
file count costs them nothing — but sharding is what makes the dated release
cuts delta-sized: a period's shard freezes once the period ends and is
uploaded exactly once, so a cut re-uploads only the in-flight shards.

For each of info-indexed / refs-indexed / closures, writes:

  <stem>-YYYY.json.gz     digests whose version closed in a finished year
  <stem>-YYYY-MM.json.gz  month grain for the year the index tip is in

A digest's period is the date of the newest revision shipping any of its
versions (the offset index/versions.json records); a digest still current at
tip has not closed and rides in the tip month's shard until it does. The
yearly rollup job later merges a finished year's months into one year file.
"""
import argparse
import gzip
import json
import os
import sys
from collections import defaultdict

STEMS = ("info-indexed", "refs-indexed", "closures")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--revisions", required=True, help="revisions.json")
    ap.add_argument("--versions", required=True, help="index/versions.json")
    ap.add_argument(
        "--outpaths", nargs="+", required=True,
        help="outpaths.json and tip-outpaths.json",
    )
    ap.add_argument(
        "--data-dir", required=True, help="directory holding <stem>.json.gz"
    )
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    revisions = json.load(open(args.revisions))
    versions = json.load(open(args.versions))
    tip = versions["revisionCount"] - 1
    tip_date = revisions[tip]["date"]
    tip_year = tip_date[:4]

    # digest -> newest closing offset over every (attr, version) that resolves
    # to it. Aliased attrs share digests; the newest sighting decides.
    vattrs = versions["attrs"]
    closing = {}
    for f in args.outpaths:
        data = json.load(open(f))
        for attr, vers in data["attrs"].items():
            for ver, entry in vers.items():
                off = vattrs.get(attr, {}).get(ver)
                off = tip if off is None else off
                d = entry[0]
                if off > closing.get(d, -1):
                    closing[d] = off

    def period_of(digest):
        off = closing.get(digest, tip)
        date = revisions[off]["date"]
        # Month grain only inside the tip's own year; earlier years are
        # finished and get their final one-file form immediately.
        if date[:4] == tip_year:
            return date[:7]
        return date[:4]

    for stem in STEMS:
        src = os.path.join(args.data_dir, f"{stem}.json.gz")
        data = json.load(gzip.open(src, "rt"))
        buckets = defaultdict(dict)
        for digest, value in data.items():
            buckets[period_of(digest)][digest] = value
        for period, entries in sorted(buckets.items()):
            path = os.path.join(args.out_dir, f"{stem}-{period}.json.gz")
            with gzip.open(path, "wt") as f:
                json.dump(entries, f, separators=(",", ":"), sort_keys=True)
            print(
                f"{stem}-{period}: {len(entries)} digests, "
                f"{os.path.getsize(path):,} bytes",
                flush=True,
            )


if __name__ == "__main__":
    sys.exit(main())

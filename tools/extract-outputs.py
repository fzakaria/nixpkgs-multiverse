#!/usr/bin/env python3
"""Recover multi-output siblings from the crawl graph.

The index records only each derivation's default output. But consumers
reference the OTHER outputs (ffmpeg-7.1-lib, ffmpeg-7.1-bin), so the closure
crawl already fetched their narinfos. Join them back: for every crawled path
whose name is <indexed drv name>-<output suffix>, record the output with its
size and direct references.

Outputs:
  --out    outs-indexed.json.gz
           { drv name: [[suffix, digest, narSize, [ref basenames...]], ...] }
  --plain  outs.json (optional): { drv name: { suffix: digest } } —
           uncompressed and stripped to what the fast evaluation path needs,
           because Nix can read JSON but not gunzip it.
"""
import argparse
import gzip
import json
import os
import sys

OUTPUT_SUFFIXES = {
    "lib",
    "bin",
    "dev",
    "doc",
    "man",
    "info",
    "data",
    "debug",
    "static",
    "terminfo",
    "py",
    "dist",
    "out",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seeds", nargs="+", required=True, help="outpaths json files")
    ap.add_argument("--graph", required=True, help="crawl state, jsonl.gz")
    ap.add_argument(
        "--prev",
        help="previously published outs-indexed.json.gz — the baseline an "
        "incremental runner's delta-only graph is merged over",
    )
    ap.add_argument("--out", required=True, help="outs-indexed.json.gz")
    ap.add_argument("--plain", help="also write the eval-facing outs.json here")
    args = ap.parse_args()

    names = set()
    for f in args.seeds:
        data = json.load(open(f))
        for attr, vers in data["attrs"].items():
            for ver, entry in vers.items():
                names.add(entry[1] if len(entry) > 1 else f"{attr}-{ver}")
    print(f"{len(names)} indexed drv names", flush=True)

    # The previously published outputs are the baseline: an incremental
    # runner's graph holds only its own delta, and without the baseline the
    # emitted file would shrink to that delta.
    outs = {}
    if args.prev and os.path.exists(args.prev):
        prev = json.load(gzip.open(args.prev, "rt"))
        outs = {base: lst for base, lst in prev.items() if base in names}
        print(f"baseline: {len(outs)} drv names from {args.prev}", flush=True)

    seen_digests = set()
    with gzip.open(args.graph, "rt") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if not rec.get("ok") or not rec.get("name") or rec["d"] in seen_digests:
                continue
            name = rec["name"]
            base, _, suffix = name.rpartition("-")
            if suffix not in OUTPUT_SUFFIXES or base not in names:
                continue
            seen_digests.add(rec["d"])
            outs.setdefault(base, []).append(
                [suffix, rec["d"], rec.get("ns"), rec.get("refs") or []]
            )

    # One entry per (base, suffix): rebuilds of the same name differ only in
    # digest; keep the largest NAR as the representative.
    for base, lst in outs.items():
        best = {}
        for e in lst:
            cur = best.get(e[0])
            if cur is None or (e[2] or 0) > (cur[2] or 0):
                best[e[0]] = e
        outs[base] = sorted(best.values())

    with gzip.open(args.out, "wt") as f:
        json.dump(outs, f, separators=(",", ":"))
    print(
        f"{len(outs)} drv names with sibling outputs, "
        f"{sum(len(v) for v in outs.values())} outputs, "
        f"{os.path.getsize(args.out):,} bytes",
        flush=True,
    )

    if args.plain:
        slim = {
            base: {suffix: digest for suffix, digest, _, _ in lst}
            for base, lst in outs.items()
        }
        json.dump(
            slim, open(args.plain, "w"), separators=(",", ":"), sort_keys=True
        )
        print(f"{args.plain}: {os.path.getsize(args.plain):,} bytes", flush=True)


if __name__ == "__main__":
    sys.exit(main())

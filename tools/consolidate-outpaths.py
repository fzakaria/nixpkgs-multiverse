#!/usr/bin/env python3
"""Consolidate the narinfo crawl graph into three compact files.

  info-indexed.json.gz     digest -> [ok, narSize, fileSize, name, narUrl]
  refs-indexed.json.gz     digest -> [ref basename, ...]   (direct refs)
  closures.json.gz         digest -> [closureBytes, closurePaths, deadInClosure]

Only digests named by the seed files (outpaths.json, tip-outpaths.json)
appear as keys; the full crawl graph (intermediate paths included) feeds the
closure walk. Paths dead in today's cache but present in a 2013-era MANIFEST
take their sizes and references from the manifest, so the old era stays
measurable.

Later records in the graph win over earlier ones, so a liveness re-crawl of a
digest simply appends and this consolidation sees the freshest state.

--prev-dir points at the previously published artifacts (whole files or
period shards — every file matching <stem>*.json.gz is read). A digest the
local graph knows nothing about keeps its previous entry: the full graph was
built once, on the backfill machine, and an incremental runner only ever
crawls the delta, so without this fallback a fresh runner would shrink the
artifacts to its own delta.

A digest neither the graph nor the fallback answers for gets no entry at all.
"Nobody looked" and "we looked and it is gone" are different claims, and
info-indexed has one field to say either in, so the first is said by saying
nothing. See docs/store-paths.md, "Absence is not death".
"""
import argparse
import glob
import gzip
import json
import os
import pickle
import sys
from collections import deque


def load_seeds(seed_files):
    out = set()
    for f in seed_files:
        data = json.load(open(f))
        for vers in data["attrs"].values():
            for entry in vers.values():
                out.add(entry[0])
    return out


def load_stem(prev_dir, stem):
    """Merge <stem>.json.gz / <stem>-<period>.json.gz from prev_dir."""
    merged = {}
    for p in sorted(glob.glob(os.path.join(prev_dir, f"{stem}*.json.gz"))):
        merged.update(json.load(gzip.open(p, "rt")))
    return merged


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seeds", nargs="+", required=True, help="outpaths json files")
    ap.add_argument("--graph", required=True, help="crawl state, jsonl.gz")
    ap.add_argument(
        "--manifest-meta", help="manifest-meta.pkl from the full match (optional)"
    )
    ap.add_argument(
        "--prev-dir", help="previously published artifacts, the merge fallback"
    )
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    print("loading crawl graph...", flush=True)
    name_of, ns_of, fs_of, url_of = {}, {}, {}, {}
    alive = set()
    crawled = set()
    refs = {}
    with gzip.open(args.graph, "rt") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            d = rec["d"]
            crawled.add(d)
            if not rec.get("ok"):
                # A later dead record supersedes an earlier alive one: the
                # path fell out of the cache between crawls.
                alive.discard(d)
                continue
            alive.add(d)
            if rec.get("name"):
                name_of[d] = rec["name"]
            if rec.get("ns"):
                ns_of[d] = rec["ns"]
            if rec.get("fs"):
                fs_of[d] = rec["fs"]
            if rec.get("url"):
                url_of[d] = rec["url"]
            # Only a record that read a narinfo knows the references. The
            # census appends liveness alone when a path it had recorded dead
            # answers again, and that record must leave the crawl's reference
            # list standing rather than blanking it.
            if "refs" in rec:
                refs[d] = rec["refs"]
    print(f"{len(alive)} alive nodes in graph", flush=True)

    # The MANIFEST era: fill sizes, names and refs for paths the cache has
    # forgotten but a 2013-2016 channel manifest recorded.
    if args.manifest_meta and os.path.exists(args.manifest_meta):
        mm = pickle.load(open(args.manifest_meta, "rb"))
        filled = 0
        for d, meta in mm.items():
            if d in alive:
                continue
            if meta.get("narSize"):
                ns_of.setdefault(d, meta["narSize"])
            if meta.get("fileSize"):
                fs_of.setdefault(d, meta["fileSize"])
            if d not in refs and meta.get("refs"):
                refs[d] = [rd for rd, _ in meta["refs"]]
                for rd, rn in meta["refs"]:
                    name_of.setdefault(rd, rn)
                filled += 1
        print(f"manifest fallback filled {filled} dead digests", flush=True)

    prev_info, prev_refs, prev_closures = {}, {}, {}
    if args.prev_dir:
        prev_info = load_stem(args.prev_dir, "info-indexed")
        prev_refs = load_stem(args.prev_dir, "refs-indexed")
        prev_closures = load_stem(args.prev_dir, "closures")
        print(
            f"previous artifacts: {len(prev_info)} info, {len(prev_refs)} refs, "
            f"{len(prev_closures)} closures",
            flush=True,
        )

    idx = load_seeds(args.seeds)
    print(f"{len(idx)} indexed digests", flush=True)

    # Per-root closure: BFS with a visited set, summing NarSize. A dead or
    # uncrawled reference still counts as a path (and any size we know for it)
    # but is never expanded.
    print("computing closures...", flush=True)
    closures = {}
    for n, root in enumerate(idx):
        if root not in refs:
            continue
        seen = {root}
        q = deque([root])
        total = ns_of.get(root, 0)
        dead = 0
        while q:
            cur = q.popleft()
            for r in refs.get(cur, ()):
                if r in seen:
                    continue
                seen.add(r)
                total += ns_of.get(r, 0)
                if r in refs:
                    q.append(r)
                else:
                    dead += 1
        closures[root] = [total, len(seen), dead]
        if n % 50000 == 0:
            print(f"  {n}/{len(idx)}", flush=True)
    print(f"{len(closures)} closures computed", flush=True)

    # The local graph is authoritative for whatever it looked at — a fresh
    # dead verdict must not be papered over — and a digest it never looked at
    # keeps its previously published entry. A fresh death keeps the previous
    # sizes and name: the path's history is still true, only its liveness
    # changed.
    #
    # A digest with neither is skipped outright rather than written as dead.
    # The three ways to have looked are a crawl record, a reference list, and
    # a MANIFEST-era size — the manifest era is evidence too: the 2013 channel
    # recorded the path, and its absence from today's cache is the finding.
    info = {}
    for d in idx:
        if d not in crawled and d not in refs and d not in ns_of:
            if d in prev_info:
                info[d] = prev_info[d]
            continue
        prev = prev_info.get(d) or [0, None, None, None, None]
        info[d] = [
            1 if d in alive else 0,
            ns_of.get(d) or prev[1],
            fs_of.get(d) or prev[2],
            name_of.get(d) or prev[3],
            url_of.get(d) or prev[4],
        ]
    print(f"{len(info)} of {len(idx)} indexed digests have a verdict", flush=True)

    refs_indexed = {}
    for d in idx:
        if d in refs:
            refs_indexed[d] = [
                f"{r}-{name_of[r]}" if r in name_of else r for r in refs[d] if r != d
            ]
        elif d in prev_refs:
            refs_indexed[d] = prev_refs[d]

    for d in idx:
        if d not in closures and d in prev_closures:
            closures[d] = prev_closures[d]

    def dump(obj, name):
        path = os.path.join(args.out_dir, name)
        with gzip.open(path, "wt") as f:
            json.dump(obj, f, separators=(",", ":"))
        print(f"{name}: {os.path.getsize(path):,} bytes", flush=True)

    dump(info, "info-indexed.json.gz")
    dump(refs_indexed, "refs-indexed.json.gz")
    dump(closures, "closures.json.gz")


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Match every (attr, version) pair in the index to its store digest.

A pair is looked up in the store-paths listing of the newest revision that
shipped it (its offset in index/versions.json), by derivation name.
Candidate names, in order:

  1. pname from the tip evaluation + "-" + version   (exact for pname != attr)
  2. attr + "-" + version
  3. attr with leading underscores stripped / lowercased / underscores
     replaced by dashes, + "-" + version
  4. the bare pname                                   (unversioned drv names)

Pairs missing at their own offset walk backwards through their lifetime
(history.json runs) and take the newest revision whose listing has them.

Outputs (into --out-dir):
  outpaths.json      closed pairs: attr -> version -> [digest, name-if-differs,
                     offset-found-if-differs]
  tip-outpaths.json  current pairs, same shape (offset omitted, always tip)
  manifest-meta.pkl  digest -> {narSize, fileSize, narUrl, refs} (MANIFEST era,
                     full mode only)
  misses.json        unmatched pairs

Two modes. --full walks every fetched listing and rebuilds from scratch — the
one-time backfill, which wants every per-offset pickle on disk. --incremental
starts from the previous outpaths/tip-outpaths (state the hourly job carries
between runs), keeps every already-closed match as-is, and only resolves pairs
that closed or appeared since — so it needs listings only for the new offsets.
"""
import argparse
import json
import os
import pickle
import re
import sys
from collections import defaultdict

# How many revisions back a pair may fall from its own offset before we give
# up. Generous: hydra occasionally misses a package for weeks of bumps.
FALLBACK_LIMIT = 120

# Nix parseDrvName: the version starts at the first dash followed by a digit.
VERSION_START = re.compile(r"-(?=[0-9])")


def pname_of(drvname):
    return VERSION_START.split(drvname, 1)[0]


def candidates(tipnames, attr, ver):
    out = []
    tip = tipnames.get(attr)
    if tip:
        out.append(f"{pname_of(tip)}-{ver}")
    out.append(f"{attr}-{ver}")
    stripped = attr.lstrip("_")
    if stripped != attr:
        out.append(f"{stripped}-{ver}")
    lower = attr.lower()
    if lower != attr:
        out.append(f"{lower}-{ver}")
    # linux_hardened -> linux-hardened: attribute names use underscores where
    # derivation names use dashes.
    dashed = attr.replace("_", "-")
    if dashed != attr:
        out.append(f"{dashed}-{ver}")
        out.append(f"{dashed.lower()}-{ver}")
    # Unversioned drv names: the store path is just the pname, whatever the
    # version. Last resort because it cannot distinguish versions.
    if tip and tip == pname_of(tip):
        out.append(tip)
    seen, uniq = set(), []
    for c in out:
        if c not in seen:
            seen.add(c)
            uniq.append(c)
    return uniq


def runs_of(v):
    return [v] if v and not isinstance(v[0], list) else (v or [])


def entry_of(attr, ver, digest, name, found_off, own_off):
    """The on-disk entry: [digest, name-if-differs, offset-found-if-differs]."""
    entry = [digest]
    if name != f"{attr}-{ver}":
        entry.append(name)
    if own_off is not None and found_off is not None and found_off != own_off:
        if len(entry) == 1:
            entry.append(f"{attr}-{ver}")
        entry.append(found_off)
    return entry


def load_entry(entry, attr, ver):
    """The inverse of entry_of: entry -> (digest, name, found_off or None)."""
    digest = entry[0]
    name = entry[1] if len(entry) > 1 else f"{attr}-{ver}"
    found_off = entry[2] if len(entry) > 2 else None
    return digest, name, found_off


class Listings:
    """Per-offset {drv name -> digest} pickles, loaded at most once each."""

    def __init__(self, paths_dir):
        self.dir = paths_dir
        self.have = {
            int(f[:-4]) for f in os.listdir(paths_dir) if f.endswith(".pkl")
        }
        self.cache = {}

    def names(self, off):
        if off not in self.cache:
            data = pickle.load(open(f"{self.dir}/{off}.pkl", "rb"))
            self.cache[off] = data["names"]
        return self.cache[off]

    def meta(self, off):
        return pickle.load(open(f"{self.dir}/{off}.pkl", "rb")).get("meta")

    def lookup(self, off, cands):
        if off not in self.have:
            return None
        names = self.names(off)
        for cand in cands:
            d = names.get(cand)
            if d:
                return d, cand
        return None


def lifetime_offsets(history, listings, attr, ver, primary, tip):
    """Offsets to try after `primary`, newest first, capped."""
    offs = []
    for run in runs_of(history["attrs"].get(attr, {}).get(ver)):
        first, last = run
        last = tip if last is None else last
        offs.extend(range(first, last + 1))
    offs = sorted(
        {o for o in offs if o < primary and o in listings.have}, reverse=True
    )
    return offs[:FALLBACK_LIMIT]


def write_outputs(out_dir, n_revs, closed, tip_out, misses, total_pairs):
    def dump(obj, name):
        path = os.path.join(out_dir, name)
        json.dump(obj, open(path, "w"), separators=(",", ":"), sort_keys=True)
        print(f"{name}: {os.path.getsize(path):,} bytes", flush=True)

    dump({"revisionCount": n_revs, "attrs": closed}, "outpaths.json")
    dump({"revisionCount": n_revs, "attrs": tip_out}, "tip-outpaths.json")
    dump(sorted([a, v] for a, v in misses), "misses.json")

    n_closed = sum(len(v) for v in closed.values())
    n_tip = sum(len(v) for v in tip_out.values())
    print(
        f"closed: {n_closed} · tip: {n_tip} · total pairs {total_pairs} · "
        f"coverage {(n_closed + n_tip) / total_pairs:.1%}",
        flush=True,
    )


def match_full(args, versions, history, tipnames, listings):
    n_revs = versions["revisionCount"]
    tip = n_revs - 1

    # Pass 1: every pair at its own offset, grouped by offset so each listing
    # is consulted once for everything it could resolve.
    by_offset = defaultdict(list)
    for attr, vers in versions["attrs"].items():
        for ver, off in vers.items():
            by_offset[tip if off is None else off].append((attr, ver, off is None))

    resolved = {}  # (attr, ver) -> (digest, name, offset)
    misses = []
    for off in sorted(by_offset):
        if off not in listings.have:
            misses.extend(by_offset[off])
            continue
        for attr, ver, is_tip in by_offset[off]:
            hit = listings.lookup(off, candidates(tipnames, attr, ver))
            if hit:
                resolved[(attr, ver)] = (*hit, off)
            else:
                misses.append((attr, ver, is_tip))
    print(f"pass 1: {len(resolved)} matched, {len(misses)} missing", flush=True)

    # Pass 2: walk lifetimes backwards for the misses, newest offset first so
    # the digest recorded is the newest build that ever shipped the version.
    want = defaultdict(list)
    for attr, ver, is_tip in misses:
        primary = versions["attrs"][attr][ver]
        primary = tip if primary is None else primary
        for o in lifetime_offsets(history, listings, attr, ver, primary, tip):
            want[o].append((attr, ver))

    still = {(a, v) for a, v, _ in misses}
    for off in sorted(want, reverse=True):
        if not still:
            break
        pairs = [p for p in want[off] if p in still]
        for attr, ver in pairs:
            hit = listings.lookup(off, candidates(tipnames, attr, ver))
            if hit:
                resolved[(attr, ver)] = (*hit, off)
                still.discard((attr, ver))
    print(f"pass 2: {len(resolved)} matched, {len(still)} still missing", flush=True)

    # MANIFEST-era metadata rides along for the consolidator, which uses it to
    # size and link the paths today's cache has forgotten.
    manifest_meta = {}
    for off in sorted(listings.have):
        meta = listings.meta(off)
        if meta:
            manifest_meta.update(meta)
    pickle.dump(
        manifest_meta,
        open(os.path.join(args.out_dir, "manifest-meta.pkl"), "wb"),
        protocol=4,
    )
    print(f"manifest meta for {len(manifest_meta)} digests", flush=True)

    closed, tip_out = defaultdict(dict), defaultdict(dict)
    total = 0
    for attr, vers in versions["attrs"].items():
        total += len(vers)
        for ver, off in vers.items():
            hit = resolved.get((attr, ver))
            if not hit:
                continue
            digest, name, found_off = hit
            if off is None:
                tip_out[attr][ver] = entry_of(attr, ver, digest, name, None, None)
            else:
                closed[attr][ver] = entry_of(attr, ver, digest, name, found_off, off)
    write_outputs(args.out_dir, n_revs, closed, tip_out, still, total)


def match_incremental(args, versions, history, tipnames, listings):
    n_revs = versions["revisionCount"]
    tip = n_revs - 1

    prev = json.load(open(args.prev_outpaths))
    prev_tip = json.load(open(args.prev_tip_outpaths))
    # The offset the previous tip file's entries were found at: the tip of the
    # index it was built against.
    prev_tip_off = prev_tip["revisionCount"] - 1

    prev_closed = {
        (a, v): e for a, vers in prev["attrs"].items() for v, e in vers.items()
    }
    prev_current = {
        (a, v): e for a, vers in prev_tip["attrs"].items() for v, e in vers.items()
    }

    closed, tip_out = defaultdict(dict), defaultdict(dict)
    misses = set()
    total = kept = moved = fresh = 0
    for attr, vers in versions["attrs"].items():
        for ver, off in vers.items():
            total += 1
            cands = None

            # Still current: prefer a hit in the new bump's own listing (the
            # newest build), fall back to the digest the previous tip carried.
            if off is None:
                cands = candidates(tipnames, attr, ver)
                hit = listings.lookup(tip, cands)
                if hit:
                    digest, name = hit
                    tip_out[attr][ver] = entry_of(attr, ver, digest, name, None, None)
                    continue
                e = prev_current.get((attr, ver)) or prev_closed.get((attr, ver))
                if e:
                    digest, name, _ = load_entry(e, attr, ver)
                    tip_out[attr][ver] = entry_of(attr, ver, digest, name, None, None)
                    continue
                misses.add((attr, ver))
                continue

            # Closed, and already matched by an earlier run: keep as-is.
            e = prev_closed.get((attr, ver))
            if e is not None:
                closed[attr][ver] = e
                kept += 1
                continue

            # Newly closed. Its own offset's listing is the honest source; a
            # pair the previous run tracked at tip moves over with the digest
            # it was found under, stamped with the offset it was found at.
            cands = candidates(tipnames, attr, ver)
            hit = listings.lookup(off, cands)
            if hit:
                digest, name = hit
                closed[attr][ver] = entry_of(attr, ver, digest, name, off, off)
                fresh += 1
                continue
            e = prev_current.get((attr, ver))
            if e is not None:
                digest, name, _ = load_entry(e, attr, ver)
                found = min(prev_tip_off, off)
                closed[attr][ver] = entry_of(attr, ver, digest, name, found, off)
                moved += 1
                continue

            # Never seen before (a backfilled revision, or a listing that was
            # late): walk whatever lifetime offsets are on disk.
            for o in lifetime_offsets(history, listings, attr, ver, off + 1, tip):
                hit = listings.lookup(o, cands)
                if hit:
                    digest, name = hit
                    closed[attr][ver] = entry_of(attr, ver, digest, name, o, off)
                    fresh += 1
                    break
            else:
                misses.add((attr, ver))

    print(
        f"incremental: {kept} kept, {moved} moved from tip, {fresh} newly "
        f"matched, {len(misses)} missing",
        flush=True,
    )
    write_outputs(args.out_dir, n_revs, closed, tip_out, misses, total)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--versions", required=True, help="index/versions.json")
    ap.add_argument("--history", required=True, help="index/history.json")
    ap.add_argument("--tip-names", required=True, help="attr -> drv name at tip")
    ap.add_argument("--paths-dir", required=True, help="fetch-store-paths output")
    ap.add_argument("--out-dir", required=True)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--full", action="store_true")
    mode.add_argument("--incremental", action="store_true")
    ap.add_argument("--prev-outpaths", help="previous outpaths.json (incremental)")
    ap.add_argument(
        "--prev-tip-outpaths", help="previous tip-outpaths.json (incremental)"
    )
    args = ap.parse_args()

    if args.incremental and not (args.prev_outpaths and args.prev_tip_outpaths):
        ap.error("--incremental needs --prev-outpaths and --prev-tip-outpaths")

    os.makedirs(args.out_dir, exist_ok=True)
    versions = json.load(open(args.versions))
    history = json.load(open(args.history))
    tipnames = json.load(open(args.tip_names))
    listings = Listings(args.paths_dir)

    if args.full:
        match_full(args, versions, history, tipnames, listings)
    else:
        match_incremental(args, versions, history, tipnames, listings)


if __name__ == "__main__":
    sys.exit(main())

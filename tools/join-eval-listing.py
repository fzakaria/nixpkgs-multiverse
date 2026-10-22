#!/usr/bin/env python3
"""Join the evaluated store paths against the channel listings, per system.

The inverted join described in docs/store-paths.md. For every (attr, version)
pair in the index, take the store path the pair's closing revision evaluates to
at this system, and keep it only if that exact digest is in the listing that
revision published. The listing is a membership test on a digest here, never a
lookup by name — a name maps to one path per system, which is what handed
x86_64 users aarch64 binaries.

Nothing is guessed. A pair whose attribute did not evaluate, or whose evaluated
path Hydra did not build for this system, carries no entry at all and lands in
the misses file; `fast.*` throws for it and names the eval selector.

Listing membership is the cheap proof, not the only one. A listing describes a
single evaluation, so a path Hydra built in a neighbouring one — firefox at the
2026-08-17 tip, for instance — is absent from it while sitting in the cache all
the same. --probe-cache asks cache.nixos.org directly for the paths the listing
did not vouch for, which is a stronger proof than membership rather than a
weaker one: the narinfo either exists or it does not.

A pair whose own revision proves nothing walks back. Hydra does not finish
every build, and when the tip moves onto one it failed, the version's earlier
build still substitutes: cutter 2.5.0 on aarch64-darwin failed at 02c087f3fe67
while the build from two days before sat in the cache (issue #28). The walk
steps back through the revisions of the version's newest run in
index/history.json, newest first, and takes the first digest a listing or the
cache vouches for, recording the offset it came from. It stays inside the
newest run for the reason pins do (see docs/design.md): an older run of the
same version is a version that left and came back, and its builds are not the
ones the eval path names.

Two modes. A full run resolves every pair from the evaluations and listings on
disk — the backfill, which wants a file per revision. An incremental run is
handed the previous artifacts with --prev-dir, keeps every pair that closed
before they were cut, and recomputes only what has moved since: the pairs that
closed at a newer revision and the tip. That is what makes the hourly job need
evaluations for the new bumps alone rather than for thirteen years.

The two modes must write the same rows, so the incremental walk ends where its
evaluations do. The previous artifacts' tip row for a pair already is the walk
over every revision up to their tip, so a pair that reaches it takes that row,
or misses if there was none. tests/join-walk-back.py holds the two to agreeing.

Outputs (into --out-dir), all keyed by the same `system`:
  outpaths-<system>.json      closed pairs: attr -> version ->
                              [digest, name-if-differs, offset-if-walked]; a
                              walked row always carries the name, so the offset
                              stays third
  tip-outpaths-<system>.json  pairs still current at the newest revision indexed
  outs-<system>.json          digest -> {output suffix -> digest}, the siblings
                              of a multi-output package, keyed by the parent
                              path rather than by a derivation name that several
                              packages can claim
  misses-<system>.json        [attr, version, reason] for every pair with no entry
  manifest-meta.pkl           digest -> {narSize, fileSize, narUrl, refs} for the
                              2012-2013 bumps, whose MANIFEST carries what a
                              narinfo would and whose paths cache.nixos.org no
                              longer serves. Written once, not per system: it is
                              keyed by digest like the graph it feeds.
"""
import argparse
import http.client
import json
import os
import pickle
import sys
import threading
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

DIGEST_LEN = 32
# Reasons a pair carries no entry. Kept as an enum-ish constant set because
# they are counted, reported and asserted on.
NO_EVAL_FILE = "no-evaluation-for-revision"
NO_LISTING = "no-listing-for-revision"
NO_ATTR = "attribute-did-not-evaluate"
NO_OUT = "derivation-has-no-out-output"
NOT_BUILT = "not-in-channel-listing"
NOT_CACHED = "not-in-listing-and-not-in-cache"
MISS_REASONS = (NO_EVAL_FILE, NO_LISTING, NO_ATTR, NO_OUT, NOT_BUILT, NOT_CACHED)

CACHE_HOST = "cache.nixos.org"
USER_AGENT = "nixpkgs-multiverse"
TIMEOUT_SECONDS = 30
PROBE_RETRIES = 3
PROBE_THREADS = 32


def load_listing_meta(paths_dir, off):
    """The per-path metadata a MANIFEST-era listing carries, or {}.

    Those 2012-2013 bumps predate the binary cache's narinfos, and the paths
    they name are long gone from it, so this is the only place their sizes and
    references exist. Newer listings carry no such column and yield nothing.
    """
    path = f"{paths_dir}/{off}.pkl"
    if not os.path.exists(path):
        return {}
    with open(path, "rb") as f:
        return pickle.load(f).get("meta") or {}


def load_digests(paths_dir, off):
    """Every digest the offset's listing holds, or None when it was never
    fetched — a revision with no listing can prove nothing about a path and so
    resolves no pair."""
    path = f"{paths_dir}/{off}.digests.pkl"
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        return pickle.load(f)["digests"]


def eval_file(eval_dir, rev, system):
    """The newest evaluator's file for this (revision, system), or None.

    The evaluator hash is part of the name so that editing nix/eval-outpaths.nix
    cannot silently reuse the old logic; a directory holding both is read at its
    newest, which is what a partly re-run backfill looks like.
    """
    prefix, suffix = f"{rev}.{system}.", ".json"
    hits = [
        f
        for f in os.listdir(eval_dir)
        if f.startswith(prefix) and f.endswith(suffix) and ".errors." not in f
    ]
    if not hits:
        return None
    return os.path.join(
        eval_dir, max(hits, key=lambda f: os.path.getmtime(os.path.join(eval_dir, f)))
    )


# One HTTPS connection per probing thread, kept open across digests the way
# tools/crawl-narinfos.py does: cache.nixos.org is one host and the handshake
# costs more than the request.
_local = threading.local()


def in_cache(digest):
    """Whether cache.nixos.org has a narinfo for this digest."""
    for attempt in range(PROBE_RETRIES):
        try:
            conn = getattr(_local, "conn", None)
            if conn is None:
                conn = _local.conn = http.client.HTTPSConnection(
                    CACHE_HOST, timeout=TIMEOUT_SECONDS
                )
            conn.request(
                "HEAD", f"/{digest}.narinfo", headers={"User-Agent": USER_AGENT}
            )
            r = conn.getresponse()
            r.read()
            if r.status in (200, 404):
                return r.status == 200
        except Exception:
            pass
        # Transient failure or a 5xx: the connection is suspect either way.
        _local.conn = None
    return False


def newest_run_start(runs):
    """The first offset of a version's newest run in index/history.json, or
    None for a pair the history does not know. A run is `[first, last]`, and a
    version that left and came back has a list of them, oldest first."""
    if not runs:
        return None
    if isinstance(runs[0], list):
        return runs[-1][0]
    return runs[0]


def split_output(value, name, output):
    """(digest, basename) for one output of an entry from reduce-eval-jobs.py.

    A bare digest means the path is named the conventional way; anything longer
    is the whole `<digest>-<basename>`.
    """
    if len(value) == DIGEST_LEN:
        return value, (name if output == "out" else f"{name}-{output}")
    return value[:DIGEST_LEN], value[DIGEST_LEN + 1 :]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--revisions", required=True, help="revisions.json")
    ap.add_argument("--versions", required=True, help="index/versions.json")
    ap.add_argument(
        "--history",
        required=True,
        help="index/history.json, for the revisions a walk back may visit",
    )
    ap.add_argument("--eval-dir", required=True, help="index/.eval")
    ap.add_argument("--paths-dir", required=True, help="the listing digest pickles")
    ap.add_argument("--system", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument(
        "--prev-dir",
        help="a directory holding the previously published artifacts for this "
        "system; pairs that closed before they were cut are carried over "
        "instead of being resolved again",
    )
    ap.add_argument(
        "--probe-cache",
        action="store_true",
        help="ask cache.nixos.org about paths no listing named, and resolve the "
        "pair when the narinfo is there",
    )
    args = ap.parse_args()

    revs = json.load(open(args.revisions))
    index = json.load(open(args.versions))
    history = json.load(open(args.history))["attrs"]
    n_revs = index["revisionCount"]
    tip_offset = n_revs - 1

    # Every pair, grouped by the revision its digest must come from: its closing
    # offset, or the tip for a version still current there. One revision's
    # evaluation and listing are then loaded once, used, and dropped — the whole
    # backfill is ~8 GB of evaluations and never fits in memory at once.
    by_offset = defaultdict(list)
    for attr, versions in index["attrs"].items():
        for version, off in versions.items():
            by_offset[tip_offset if off is None else off].append((attr, version))

    # An incremental run's inheritance. `covered` is one revision back from the
    # previous artifacts' coverage, because a pair that was at their tip may
    # have closed at that revision and has to be resolved again. It is also
    # where an incremental walk back stops evaluating and reads `prev_tip`
    # instead; `walk_floor` stays None for a full run, which walks to the
    # start of the run.
    prev_closed, prev_tip, prev_outs, covered = {}, {}, {}, 0
    walk_floor = None
    prev_path = (
        f"{args.prev_dir}/outpaths-{args.system}.json" if args.prev_dir else None
    )
    if prev_path and os.path.exists(prev_path):
        prev = json.load(open(prev_path))
        prev_closed = prev["attrs"]
        covered = max(0, prev["revisionCount"] - 1)
        walk_floor = covered
        prev_tip_path = f"{args.prev_dir}/tip-outpaths-{args.system}.json"
        if os.path.exists(prev_tip_path):
            prev_tip = json.load(open(prev_tip_path))["attrs"]
        prev_outs_path = f"{args.prev_dir}/outs-{args.system}.json"
        if os.path.exists(prev_outs_path):
            prev_outs = json.load(open(prev_outs_path))
        print(f"carrying over closed pairs below offset {covered}")
    elif prev_path:
        # A system published for the first time has nothing to carry over, and
        # resolving it from scratch is the only correct thing to do — so say so
        # rather than failing on the missing file.
        print(f"no {os.path.basename(prev_path)} to carry over from; resolving in full")

    closed, tip, outs, misses, manifest_meta = {}, {}, {}, [], {}
    stats = defaultdict(int)
    # Pairs whose evaluated path the listing did not name, kept whole so that
    # --probe-cache can ask the cache about them once the walk is done.
    unvouched = []
    # digest -> whether cache.nixos.org has it, for every digest probed. The
    # walk back meets the same path at revision after revision, since most
    # bumps rebuild nothing, and asks about each one once.
    verdicts = {}

    def emit(target, attr, version, name, digest, found_off=None):
        """Record one resolved pair. The derivation name rides along only when
        it is not what a consumer would reconstruct from the pair itself, which
        is what keeps the file the size it is. A walked pair carries the offset
        its build came from, and the name in front of it to keep it third."""
        row = [digest] if name == f"{attr}-{version}" else [digest, name]
        if found_off is not None:
            row = [digest, name, found_off]
        target.setdefault(attr, {})[version] = row

    for off in sorted(by_offset):
        pairs = by_offset[off]

        # Everything this offset closed, as the previous cut resolved it. Only
        # what is missing from there is worth opening an evaluation for, and an
        # offset with nothing missing costs no file reads at all.
        if off < covered:
            inherited = {p for p in pairs if p[1] in prev_closed.get(p[0], {})}
            for attr, version in inherited:
                row = prev_closed[attr][version]
                closed.setdefault(attr, {})[version] = row
                if row[0] in prev_outs:
                    outs[row[0]] = prev_outs[row[0]]
                stats["carried"] += 1
            pairs = [p for p in pairs if p not in inherited]
            if not pairs:
                continue

        path = eval_file(args.eval_dir, revs[off]["rev"], args.system)
        if path is None:
            misses += [[attr, version, NO_EVAL_FILE] for attr, version in pairs]
            continue

        digests = load_digests(args.paths_dir, off)
        if digests is None:
            misses += [[attr, version, NO_LISTING] for attr, version in pairs]
            continue

        evaluated = json.load(open(path))["attrs"]
        # Only the oldest era has any, and only for the digests resolved here.
        listing_meta = load_listing_meta(args.paths_dir, off)

        # A version still current at the tip is what tip-outpaths.json holds;
        # everything else has closed and belongs in outpaths.json.
        target = tip if off == tip_offset else closed

        for attr, version in pairs:
            entry = evaluated.get(attr)
            if entry is None:
                misses.append([attr, version, NO_ATTR])
                continue

            name = entry["name"]
            if "out" not in entry["outputs"]:
                misses.append([attr, version, NO_OUT])
                continue

            digest, _ = split_output(entry["outputs"]["out"], name, "out")
            # Siblings are recorded by digest alone, so a consumer rebuilds
            # their path as `<digest>-<name>-<output>`. The rare output whose
            # basename does not follow that is dropped rather than described
            # wrongly — reduce-eval-jobs.py marks it by storing more than a
            # digest.
            siblings = {}
            for output, value in entry["outputs"].items():
                if output == "out" or len(value) != DIGEST_LEN:
                    continue
                siblings[output] = value
            if digest not in digests:
                # Held back for the cache probe rather than rejected here: the
                # listing not naming a path is not the same as the cache not
                # having it. Counted once the probe has had its say.
                unvouched.append((attr, version, name, digest, siblings, target))
                continue

            emit(target, attr, version, name, digest)
            stats["built"] += 1
            if digest in listing_meta:
                manifest_meta[digest] = listing_meta[digest]

            # Siblings are membership-tested one by one: a package whose `out`
            # Hydra built and whose `-doc` it did not must not advertise the doc.
            vouched = {o: d for o, d in siblings.items() if d in digests}
            if vouched:
                outs[digest] = vouched

    # The cache probe, on exactly the pairs the listings left unvouched. A hit
    # is a stronger statement than listing membership — the path is fetchable
    # right now — so it resolves the pair; a miss is the final answer for it.
    if args.probe_cache and unvouched:
        print(
            f"probing cache.nixos.org for {len(unvouched)} unvouched paths", flush=True
        )
        with ThreadPoolExecutor(PROBE_THREADS) as ex:
            found = list(ex.map(lambda u: in_cache(u[3]), unvouched))
        verdicts.update((u[3], hit) for u, hit in zip(unvouched, found))

        # The siblings of everything that came back, in one pass rather than a
        # pool per package: three quarters of the aarch64 backfill's probes were
        # hits, and a thread pool spun up per hit is what turned that join into
        # an hour of mostly thread setup.
        hits = [u for u, hit in zip(unvouched, found) if hit]
        sibling_digests = sorted({d for u in hits for d in u[4].values()})
        with ThreadPoolExecutor(PROBE_THREADS) as ex:
            cached_siblings = {
                digest
                for digest, hit in zip(
                    sibling_digests, ex.map(in_cache, sibling_digests)
                )
                if hit
            }
        verdicts.update((d, d in cached_siblings) for d in sibling_digests)

        for (attr, version, name, digest, siblings, target), hit in zip(
            unvouched, found
        ):
            if not hit:
                misses.append([attr, version, NOT_CACHED])
                continue
            emit(target, attr, version, name, digest)
            stats["probed"] += 1
            vouched = {o: d for o, d in siblings.items() if d in cached_siblings}
            if vouched:
                outs[digest] = vouched
    else:
        for attr, version, _name, _digest, _siblings, _target in unvouched:
            misses.append([attr, version, NOT_BUILT])

    # The walk back, for every pair its own revision could not prove. Each
    # pair wants the revisions of its version's newest run below its own,
    # newest first. Offsets are visited newest first across every pair at
    # once, so a revision's evaluation and listing are loaded once, as above.
    # An incremental run evaluates no further back than `walk_floor`.
    walking, want = {}, defaultdict(list)
    for attr, version, reason in misses:
        own = index["attrs"][attr][version]
        own = tip_offset if own is None else own
        first = newest_run_start(history.get(attr, {}).get(version))
        walking[(attr, version)] = (reason, own, first)
        if first is None:
            continue
        lowest = first if walk_floor is None else max(first, walk_floor + 1)
        for off in range(own - 1, lowest - 1, -1):
            want[off].append((attr, version))

    # (attr, version) -> (name, digest, offset, vouched siblings)
    walked = {}
    for off in sorted(want, reverse=True):
        pairs = [p for p in want[off] if p not in walked]
        if not pairs:
            continue

        # A revision that cannot prove anything is stepped over rather than
        # ending the walk: one failed evaluation says nothing about the
        # revisions around it.
        path = eval_file(args.eval_dir, revs[off]["rev"], args.system)
        digests = load_digests(args.paths_dir, off)
        if path is None or digests is None:
            continue
        evaluated = json.load(open(path))["attrs"]
        listing_meta = load_listing_meta(args.paths_dir, off)

        # The listing first, exactly as for a pair's own revision.
        unproven = []
        for attr, version in pairs:
            entry = evaluated.get(attr)
            if entry is None or "out" not in entry["outputs"]:
                continue
            name = entry["name"]
            digest, _ = split_output(entry["outputs"]["out"], name, "out")
            siblings = {
                o: d
                for o, d in entry["outputs"].items()
                if o != "out" and len(d) == DIGEST_LEN
            }
            if digest not in digests:
                unproven.append((attr, version, name, digest, siblings))
                continue
            vouched = {o: d for o, d in siblings.items() if d in digests}
            walked[(attr, version)] = (name, digest, off, vouched)
            if digest in listing_meta:
                manifest_meta[digest] = listing_meta[digest]

        # Then the cache, for what the listing did not name. A pair that
        # misses here keeps walking to the next revision down.
        if not args.probe_cache or not unproven:
            continue
        ask = sorted({u[3] for u in unproven} - verdicts.keys())
        with ThreadPoolExecutor(PROBE_THREADS) as ex:
            verdicts.update(zip(ask, ex.map(in_cache, ask)))
        hits = [u for u in unproven if verdicts[u[3]]]
        ask = sorted({d for u in hits for d in u[4].values()} - verdicts.keys())
        with ThreadPoolExecutor(PROBE_THREADS) as ex:
            verdicts.update(zip(ask, ex.map(in_cache, ask)))
        for attr, version, name, digest, siblings in hits:
            vouched = {o: d for o, d in siblings.items() if verdicts[d]}
            walked[(attr, version)] = (name, digest, off, vouched)

    # Where an incremental walk stops evaluating, the previous artifacts take
    # over: their tip row for a pair is that same walk, done over every
    # revision up to their tip. A pair whose newest run started after their
    # tip was never at it in this run, and gets nothing from there.
    if walk_floor is not None:
        for (attr, version), (_reason, own, first) in walking.items():
            if (attr, version) in walked or first is None or first > walk_floor:
                continue
            row = prev_tip.get(attr, {}).get(version)
            if row is None:
                continue
            name = row[1] if len(row) > 1 else f"{attr}-{version}"
            off = row[2] if len(row) > 2 else walk_floor
            walked[(attr, version)] = (name, row[0], off, prev_outs.get(row[0], {}))

    misses = []
    for (attr, version), (reason, own, _first) in walking.items():
        if (attr, version) not in walked:
            misses.append([attr, version, reason])
            continue
        name, digest, off, vouched = walked[(attr, version)]
        target = tip if own == tip_offset else closed
        emit(target, attr, version, name, digest, None if off == own else off)
        if vouched:
            outs[digest] = vouched
        stats["walked"] += 1

    # Each reason is counted on the misses that are left, so a pair the walk
    # resolved is counted once, as walked.
    for _attr, _version, reason in misses:
        stats[reason] += 1

    os.makedirs(args.out_dir, exist_ok=True)
    head = {
        "revisionCount": n_revs,
        "system": args.system,
        # Provenance: every digest in these files came from evaluating nixpkgs
        # at this system, never from a name-keyed listing lookup.
        "source": "eval",
        "vouchedByListing": stats["built"],
        "vouchedByCacheProbe": stats["probed"],
        "carriedFromPreviousCut": stats["carried"],
        "vouchedAtEarlierRevision": stats["walked"],
    }
    written = {
        f"outpaths-{args.system}.json": {**head, "attrs": dict(sorted(closed.items()))},
        f"tip-outpaths-{args.system}.json": {
            **head,
            "attrs": dict(sorted(tip.items())),
        },
        f"outs-{args.system}.json": dict(sorted(outs.items())),
        f"misses-{args.system}.json": sorted(misses),
    }
    for name, doc in written.items():
        dest = os.path.join(args.out_dir, name)
        with open(dest + ".tmp", "w") as f:
            json.dump(doc, f, separators=(",", ":"))
        os.replace(dest + ".tmp", dest)

    # Merged rather than overwritten: the file is shared by every system, and
    # the second system's run must not drop the first's digests.
    if manifest_meta:
        dest = os.path.join(args.out_dir, "manifest-meta.pkl")
        if os.path.exists(dest):
            with open(dest, "rb") as f:
                manifest_meta = pickle.load(f) | manifest_meta
        with open(dest + ".tmp", "wb") as f:
            pickle.dump(manifest_meta, f, protocol=4)
        os.replace(dest + ".tmp", dest)
        print(f"  {len(manifest_meta)} MANIFEST-era paths carry their own metadata")

    total = sum(stats.values())
    resolved = stats["built"] + stats["probed"] + stats["carried"] + stats["walked"]
    print(
        f"{args.system}: {resolved}/{total} pairs resolved "
        f"({stats['probed']} by cache probe, {stats['carried']} carried over, "
        f"{stats['walked']} at an earlier revision)"
    )
    for reason in MISS_REASONS:
        if stats[reason]:
            print(f"  {stats[reason]:>7} {reason}")
    print(
        f"  {len(closed)} attrs closed, {len(tip)} at the tip, {len(outs)} multi-output"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

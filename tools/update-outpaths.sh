#!/usr/bin/env bash
# Keeps the store-path artifacts current: fetch the channel listings the index
# has never seen, evaluate the revisions it has never evaluated, join the two
# into per-system digests, crawl cache.nixos.org for whatever the graph is
# missing, and consolidate into the artifact files a dated release cut
# publishes.
#
# The digest of a pair comes from evaluating its closing revision at an
# explicit system, and the listing is asked only whether it holds that exact
# path. That is the whole of the issue #12 fix: a listing has no System column,
# so looking a derivation NAME up in one cannot tell an x86_64 path from an
# aarch64 one. See docs/store-paths.md, and issue #12 for the bug it caused.
#
# The listings are nixos-unstable's, so they name no darwin path: 23 of
# aarch64-darwin's 16,545 paths at the 2026-08-17 tip. Darwin is carried by the
# join's cache probe instead, which is the stronger proof of the two.
#
# The whole run is incremental. Listings are fetched only for offsets with no
# pickle on disk, revisions are evaluated only where no evaluation exists, the
# join carries over every pair that closed before the previous artifacts were
# cut, and the crawler resumes from graph.jsonl.gz. State lives in
# index/.outpaths/ and index/.eval/ (both gitignored): the hourly workflow seeds
# them from the previous run's release assets and re-uploads afterwards, so a
# runner starts warm.
#
# Usage:
#   tools/update-outpaths.sh                incremental hourly update
#   tools/update-outpaths.sh --full         the one-time backfill (wants every
#                                           listing and evaluation on disk)
#   tools/update-outpaths.sh --shard        also write the period shards a
#                                           dated release cut uploads
#   tools/update-outpaths.sh --systems x86_64-linux
set -euo pipefail

# Data lives in the checkout, code lives next to this script. Under `nix run`
# those are two different places: the script is a store copy, while the state
# must stay writable in the caller's checkout, which the flake wrapper passes
# down as MULTIVERSE_ROOT.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The evaluators live in nix/, which `nix run` copies in as its own store path;
# the flake wrapper names it MULTIVERSE_NIX. See build-index.sh.
NIXDIR="${MULTIVERSE_NIX:-$(cd "$(dirname "$0")/../nix" && pwd)}"
# Both are exported because step 2 runs tools/eval-outpaths.sh as a child, and
# a child under `nix run` cannot re-derive either from its own $0.
export MULTIVERSE_ROOT="$MT"
export MULTIVERSE_NIX="$NIXDIR"

WORK="$MT/index/.outpaths"
PATHS="$WORK/paths"
DATA="$WORK/data"
GRAPH="$WORK/graph.jsonl.gz"
EVAL="$MT/index/.eval"

MODE=incremental
SHARD=0
# Every system the artifacts are published for. A system listed here without an
# evaluation simply produces no entries, so adding one is a matter of running
# the backfill for it.
SYSTEMS="x86_64-linux,aarch64-linux,aarch64-darwin"
while [ $# -gt 0 ]; do
  case "$1" in
    --full) MODE=full; shift ;;
    --shard) SHARD=1; shift ;;
    --systems) SYSTEMS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$PATHS" "$DATA" "$EVAL"

# 1. Channel listings not fetched yet. A full run wants all of them; an
#    incremental run only consults listings at or past the previous artifacts'
#    coverage, so everything older is skipped — a fresh runner fetches the new
#    bumps, not thirteen years of listings.
MINOFF=0
FIRST_SYSTEM="${SYSTEMS%%,*}"
PREV="$DATA/prev/outpaths-$FIRST_SYSTEM.json"
# An incremental run with nothing to start from would evaluate every revision
# ever indexed, which is the backfill and does not belong on an hourly runner.
if [ "$MODE" = incremental ] && [ ! -s "$PREV" ]; then
  echo "update-outpaths: no previous artifacts in $DATA/prev to update." >&2
  echo "Seed them from the latest release, or run with --full." >&2
  exit 1
fi
if [ "$MODE" = incremental ]; then
  # One revision back from the previous coverage, so the revision the last tip
  # was resolved against is on disk for the moved-from-tip entries.
  MINOFF=$(python3 -c '
import json
count = json.load(open("'"$PREV"'"))["revisionCount"]
print(max(0, count - 1))
')
fi
python3 "$HERE/fetch-store-paths.py" \
  --revisions "$MT/revisions.json" --outdir "$PATHS" --min-offset "$MINOFF"

# 2. Evaluate the revisions the join will need. A full run wants every
#    revision, which is the backfill and belongs on a big machine; an
#    incremental run wants only the offsets past the previous coverage, which
#    is a couple of revisions and fits a standard runner.
if [ "$MODE" = full ]; then
  OFFSETS=":"
else
  OFFSETS="$MINOFF:"
fi
#    A full run reaches back to 2012 and meets revisions that cannot be
#    evaluated for every published system at all — aarch64-darwin does not
#    exist before 2021, and a 2017 nixpkgs has no way to produce it. That is a
#    permanent gap in the data, not a failure of the run, and the join simply
#    finds no evaluation for those pairs. An incremental run is held to the
#    stricter standard: it evaluates revisions that landed days ago, where a
#    failure is a bug to look at rather than history being what it is.
if ! bash "$HERE/eval-outpaths.sh" --offsets "$OFFSETS" --system "$SYSTEMS"; then
  if [ "$MODE" != full ]; then
    echo "update-outpaths: evaluation failed; refusing to join a partial set" >&2
    exit 1
  fi
  echo "update-outpaths: some (revision, system) pairs did not evaluate; joining what did"
fi

# 3. Join evaluations against listings, one set of artifacts per system.
#    Incremental hands the join the previously published files, so every pair
#    that closed before them is carried over rather than resolved again.
PREV_ARG=()
if [ "$MODE" = incremental ] && [ -d "$DATA/prev" ]; then
  PREV_ARG=(--prev-dir "$DATA/prev")
fi
for system in ${SYSTEMS//,/ }; do
  python3 "$HERE/join-eval-listing.py" \
    --revisions "$MT/revisions.json" --versions "$MT/index/versions.json" \
    --eval-dir "$EVAL" --paths-dir "$PATHS" --system "$system" \
    --out-dir "$DATA" --probe-cache "${PREV_ARG[@]}"
done

# Every system's artifacts, as the crawl and consolidation seeds: the graph
# describes digests, and a digest is a digest whichever system evaluated it.
SEEDS=()
for system in ${SYSTEMS//,/ }; do
  SEEDS+=("$DATA/outpaths-$system.json" "$DATA/tip-outpaths-$system.json")
done

# 4. Crawl narinfos for digests the graph has never seen: newly resolved
#    versions and their transitive references. A runner that restored no graph
#    re-crawls all of them, which is minutes — the graph carries fetched
#    records only, so there is nothing else to start from.
python3 "$HERE/crawl-narinfos.py" --seeds "${SEEDS[@]}" --graph "$GRAPH"

# 5. Consolidate the graph into the three artifact files. The previously
#    published copies (restored into $DATA/prev-shards by the workflow) are the
#    fallback for digests this runner's graph never crawled — the full graph
#    exists only where the backfill ran.
EXTRA=""
if [ -s "$DATA/manifest-meta.pkl" ]; then
  EXTRA="--manifest-meta $DATA/manifest-meta.pkl"
fi
if [ -d "$DATA/prev-shards" ]; then
  EXTRA="$EXTRA --prev-dir $DATA/prev-shards"
fi
# shellcheck disable=SC2086
python3 "$HERE/consolidate-outpaths.py" \
  --seeds "${SEEDS[@]}" \
  --graph "$GRAPH" $EXTRA --out-dir "$DATA"

# 6. The site's view of multi-output packages, recovered from consumers'
#    closures. The fast path no longer reads this: its outs-<system>.json comes
#    from the evaluation, which reports every output directly instead of
#    inferring the ones somebody else happened to depend on.
PREV_OUTS=""
if [ -s "$DATA/prev-shards/outs-indexed.json.gz" ]; then
  PREV_OUTS="--prev $DATA/prev-shards/outs-indexed.json.gz"
fi
# shellcheck disable=SC2086
python3 "$HERE/extract-outputs.py" \
  --seeds "${SEEDS[@]}" \
  --graph "$GRAPH" $PREV_OUTS --out "$DATA/outs-indexed.json.gz"

# 7. Period shards, only when a release cut is about to upload them.
if [ "$SHARD" -eq 1 ]; then
  python3 "$HERE/shard-data.py" \
    --revisions "$MT/revisions.json" --versions "$MT/index/versions.json" \
    --outpaths "${SEEDS[@]}" \
    --data-dir "$DATA" --out-dir "$DATA/shards"
fi

echo "update-outpaths: artifacts in $DATA"

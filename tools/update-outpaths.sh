#!/usr/bin/env bash
# Keeps the store-path artifacts current: fetch the channel listings the
# index has never seen, match every (attr, version) pair to its store digest,
# crawl cache.nixos.org for whatever the graph is missing, and consolidate
# into the artifact files a dated release cut publishes.
#
# The whole run is incremental. Listings are fetched only for offsets with no
# pickle on disk, the matcher keeps every already-closed match as-is, and the
# crawler resumes from graph.jsonl.gz. State lives in index/.outpaths/
# (gitignored): the hourly workflow seeds it from the previous run's rolling
# release assets and re-uploads it afterwards, so a runner starts warm.
#
# Usage:
#   tools/update-outpaths.sh                incremental hourly update
#   tools/update-outpaths.sh --full         the one-time backfill (wants every
#                                           listing on disk; hours of work)
#   tools/update-outpaths.sh --shard        also write the period shards a
#                                           dated release cut uploads
set -euo pipefail

# Data lives in the checkout, code lives next to this script. Under `nix run`
# those are two different places: the script is a store copy, while the state
# must stay writable in the caller's checkout, which the flake wrapper passes
# down as MULTIVERSE_ROOT.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

WORK="$MT/index/.outpaths"
PATHS="$WORK/paths"
DATA="$WORK/data"
GRAPH="$WORK/graph.jsonl.gz"

MODE=incremental
SHARD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --full) MODE=full; shift ;;
    --shard) SHARD=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$PATHS" "$DATA"

# 1. Channel listings not fetched yet. A full run wants all of them; an
#    incremental run only consults listings at or past the previous
#    artifacts' coverage, so everything older is skipped — a fresh runner
#    fetches the new bumps, not thirteen years of listings.
MINOFF=0
if [ "$MODE" = incremental ] && [ -s "$DATA/outpaths.json" ]; then
  # One revision back from the previous coverage, so the listing the last
  # tip was matched against is on disk for the moved-from-tip entries.
  MINOFF=$(python3 -c '
import json
count = json.load(open("'"$DATA"'/outpaths.json"))["revisionCount"]
print(max(0, count - 1))
')
fi
python3 "$HERE/fetch-store-paths.py" \
  --revisions "$MT/revisions.json" --outdir "$PATHS" --min-offset "$MINOFF"

# 2. {attr -> drv name} at the index tip, cached per revision. The matcher
#    needs it to try pname-shaped candidates (python3 -> python3-3.12.4).
#    The tip here must be one that fetchTree can materialise, hence narHash.
TIPREV=$(python3 -c '
import json
revs = json.load(open("'"$MT"'/revisions.json"))
tip = [r for r in revs if "narHash" in r][-1]
print(tip["rev"])
')
TIPNAMES="$WORK/tip-names.$TIPREV.json"
if [ ! -s "$TIPNAMES" ]; then
  echo "extracting drv names at tip $TIPREV"
  SRC=$(nix flake prefetch --json "github:NixOS/nixpkgs/$TIPREV" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["storePath"])')
  nix-instantiate --eval --strict --json \
    --arg revPath "$SRC" "$HERE/extract-names.nix" > "$TIPNAMES.tmp"
  mv "$TIPNAMES.tmp" "$TIPNAMES"
fi

# 3. Match pairs to digests. Incremental starts from the previous artifacts,
#    which the caller must have placed in $DATA (the hourly workflow restores
#    them from the rolling release); with nothing to start from, only --full
#    can build the files, and it needs every listing from step 1.
if [ "$MODE" = full ]; then
  python3 "$HERE/match-outpaths.py" --full \
    --versions "$MT/index/versions.json" --history "$MT/index/history.json" \
    --tip-names "$TIPNAMES" --paths-dir "$PATHS" --out-dir "$DATA"
else
  if [ ! -s "$DATA/outpaths.json" ] || [ ! -s "$DATA/tip-outpaths.json" ]; then
    echo "update-outpaths: no previous artifacts in $DATA to update." >&2
    echo "Seed them from the latest release, or run with --full." >&2
    exit 1
  fi
  cp "$DATA/outpaths.json" "$WORK/prev-outpaths.json"
  cp "$DATA/tip-outpaths.json" "$WORK/prev-tip-outpaths.json"
  python3 "$HERE/match-outpaths.py" --incremental \
    --versions "$MT/index/versions.json" --history "$MT/index/history.json" \
    --tip-names "$TIPNAMES" --paths-dir "$PATHS" --out-dir "$DATA" \
    --prev-outpaths "$WORK/prev-outpaths.json" \
    --prev-tip-outpaths "$WORK/prev-tip-outpaths.json"
fi

# 4. Crawl narinfos for digests the graph has never seen: newly matched
#    versions and their transitive references.
python3 "$HERE/crawl-narinfos.py" \
  --seeds "$DATA/outpaths.json" "$DATA/tip-outpaths.json" --graph "$GRAPH"

# 5. Consolidate the graph into the three artifact files. The previously
#    published copies (restored into $DATA/prev-shards by the workflow) are
#    the fallback for digests this runner's graph never crawled — the full
#    graph exists only where the backfill ran.
EXTRA=""
if [ -s "$DATA/manifest-meta.pkl" ]; then
  EXTRA="--manifest-meta $DATA/manifest-meta.pkl"
fi
if [ -d "$DATA/prev-shards" ]; then
  EXTRA="$EXTRA --prev-dir $DATA/prev-shards"
fi
# shellcheck disable=SC2086
python3 "$HERE/consolidate-outpaths.py" \
  --seeds "$DATA/outpaths.json" "$DATA/tip-outpaths.json" \
  --graph "$GRAPH" $EXTRA --out-dir "$DATA"

# 6. Sibling outputs, plus the plain outs.json the fast eval path reads.
#    The previous published copy is the baseline for the same reason as the
#    consolidation fallback above.
PREV_OUTS=""
if [ -s "$DATA/prev-shards/outs-indexed.json.gz" ]; then
  PREV_OUTS="--prev $DATA/prev-shards/outs-indexed.json.gz"
fi
# shellcheck disable=SC2086
python3 "$HERE/extract-outputs.py" \
  --seeds "$DATA/outpaths.json" "$DATA/tip-outpaths.json" \
  --graph "$GRAPH" $PREV_OUTS --out "$DATA/outs-indexed.json.gz" --plain "$DATA/outs.json"

# 7. Period shards, only when a release cut is about to upload them.
if [ "$SHARD" -eq 1 ]; then
  python3 "$HERE/shard-data.py" \
    --revisions "$MT/revisions.json" --versions "$MT/index/versions.json" \
    --outpaths "$DATA/outpaths.json" "$DATA/tip-outpaths.json" \
    --data-dir "$DATA" --out-dir "$DATA/shards"
fi

echo "update-outpaths: artifacts in $DATA"

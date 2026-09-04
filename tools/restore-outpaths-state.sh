#!/usr/bin/env bash
# Seeds index/.outpaths/ from the published releases, so a fresh CI runner
# starts where the previous run stopped.
#
# Two sources, by freshness. The rolling release carries the hourly state (the
# previous per-system outpaths/tip-outpaths, the crawl graph, misses); the
# pinned dated assets carry the graph artifacts, restored into data/prev-shards
# as the consolidation fallback for digests this runner never crawls. Every
# pinned download is verified against the narHash in data-pins.json.
#
# The per-system files land in data/prev rather than in data: the join reads
# them as the previous cut to carry pairs over from, and writes this run's
# answer beside them.
#
# A missing rolling asset is not an error — the first run after a seed has
# no graph yet — but missing pinned artifacts are: without the fallback a
# consolidation would shrink the published files to this runner's delta.
#
# Nothing is written into the crawl graph here: it holds fetched records
# only. A run that restored none crawls every digest again, which is minutes.
set -euo pipefail

MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORK="$MT/index/.outpaths"
DATA="$WORK/data"
ROLLING_TAG="data-rolling"
ROLLING_BASE="https://github.com/fzakaria/nixpkgs-multiverse/releases/download/$ROLLING_TAG"

mkdir -p "$DATA/prev-shards" "$DATA/prev"

fetch() {
  # curl -f fails on 404 without writing the file; rolling assets may
  # legitimately not exist yet.
  curl -fsSL --retry 3 -o "$2.tmp" "$1" && mv "$2.tmp" "$2" || {
    rm -f "$2.tmp"
    return 1
  }
}

# The hourly state, freshest copy first: rolling, then the pinned cut. Which
# systems exist is data-pins.json's business, so the names come from there
# rather than from a list kept in step with it here.
mapfile -t JOIN_INPUTS < <(python3 -c '
import json
pins = json.load(open("'"$MT"'/data-pins.json"))
for name in sorted(pins["files"]):
    # `.json` and not `.json.gz`: outs-indexed.json.gz shares the prefix but
    # is a graph artifact, not a join input.
    if name.startswith(("outpaths-", "tip-outpaths-", "outs-")) and name.endswith(".json"):
        print(name)
')
for f in "${JOIN_INPUTS[@]}"; do
  if fetch "$ROLLING_BASE/$f" "$DATA/prev/$f"; then
    echo "restored $f from $ROLLING_TAG"
  fi
done
if fetch "$ROLLING_BASE/graph.jsonl.gz" "$WORK/graph.jsonl.gz"; then
  echo "restored crawl graph from $ROLLING_TAG"
fi

# Everything data-pins.json names, hash-verified. The two matcher inputs
# fall back to the pinned copy when rolling had none; the graph artifacts
# land in prev-shards for the consolidation merge.
python3 - "$MT/data-pins.json" "$DATA" <<'PY'
import json, os, subprocess, sys, urllib.request

pins_file, data = sys.argv[1:3]
pins = json.load(open(pins_file))

# What the join carries pairs over from. Everything else the pins name is a
# graph artifact and belongs in the consolidation fallback instead — including
# outs-indexed.json.gz, which shares a prefix but not the .json suffix.
JOIN_PREFIXES = ("outpaths-", "tip-outpaths-", "outs-")

fetched = failures = 0
for name, pin in sorted(pins["files"].items()):
    if name.startswith(JOIN_PREFIXES) and name.endswith(".json"):
        dest = os.path.join(data, "prev", name)
        # Rolling already provided a fresher copy.
        if os.path.exists(dest):
            continue
    else:
        dest = os.path.join(data, "prev-shards", name)

    url = f"{pins['baseUrl']}/{pin['tag']}/{name}"
    req = urllib.request.Request(url, headers={"User-Agent": "nixpkgs-multiverse"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest + ".tmp", "wb") as out:
        out.write(r.read())

    got = subprocess.run(
        ["nix", "hash", "path", "--sri", "--type", "sha256", dest + ".tmp"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if got != pin["narHash"]:
        print(f"HASH MISMATCH for {name}: pinned {pin['narHash']}, got {got}")
        os.remove(dest + ".tmp")
        failures += 1
        continue
    os.replace(dest + ".tmp", dest)
    fetched += 1

print(f"restored {fetched} pinned artifacts, {failures} failures")
sys.exit(1 if failures else 0)
PY

echo "state restored under $WORK"

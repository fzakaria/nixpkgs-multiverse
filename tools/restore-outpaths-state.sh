#!/usr/bin/env bash
# Seeds index/.outpaths/ from the published releases, so a fresh CI runner
# starts where the previous run stopped.
#
# Two sources, by freshness. The rolling release carries the hourly state
# (previous outpaths/tip-outpaths, the crawl graph, misses); the pinned
# dated assets carry the graph artifacts, restored into data/prev-shards as
# the consolidation fallback for digests this runner never crawls. Every
# pinned download is verified against the narHash in data-pins.json.
#
# A missing rolling asset is not an error — the first run after a seed has
# no graph yet — but missing pinned artifacts are: without the fallback a
# consolidation would shrink the published files to this runner's delta.
set -euo pipefail

MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORK="$MT/index/.outpaths"
DATA="$WORK/data"
ROLLING_TAG="data-rolling"
ROLLING_BASE="https://github.com/fzakaria/nixpkgs-multiverse/releases/download/$ROLLING_TAG"

mkdir -p "$DATA/prev-shards"

fetch() {
  # curl -f fails on 404 without writing the file; rolling assets may
  # legitimately not exist yet.
  curl -fsSL --retry 3 -o "$2.tmp" "$1" && mv "$2.tmp" "$2" || {
    rm -f "$2.tmp"
    return 1
  }
}

# The hourly state, freshest copy first: rolling, then the pinned cut.
for f in outpaths.json tip-outpaths.json; do
  if fetch "$ROLLING_BASE/$f" "$DATA/$f"; then
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

MATCHER_INPUTS = {"outpaths.json", "tip-outpaths.json"}

fetched = failures = 0
for name, pin in sorted(pins["files"].items()):
    if name in MATCHER_INPUTS:
        dest = os.path.join(data, name)
        # Rolling already provided a fresher copy.
        if os.path.exists(dest):
            continue
    elif name == "outs.json":
        # Derived from the graph on every run; nothing restores it.
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

# No rolling graph means the crawler would start cold and re-crawl thirteen
# years of narinfos. Instead, seed it with a STUB record per already-pinned
# digest: the crawler skips stubs as roots (their artifacts are published
# truth) but still crawls one natively the first time a new root's closure
# walk touches it, and the consolidator ignores stubs entirely — its answers
# for them come from the prev-shards fallback.
if [ ! -s "$WORK/graph.jsonl.gz" ]; then
  python3 - "$DATA" "$WORK/graph.jsonl.gz" <<'PY'
import gzip, json, os, sys

data, graph = sys.argv[1:3]
digests = set()
for f in ("outpaths.json", "tip-outpaths.json"):
    p = os.path.join(data, f)
    if not os.path.exists(p):
        continue
    for vers in json.load(open(p))["attrs"].values():
        for entry in vers.values():
            digests.add(entry[0])

with gzip.open(graph, "wt") as out:
    for d in sorted(digests):
        out.write(json.dumps({"d": d, "ok": True, "stub": True}) + "\n")
print(f"seeded the crawl graph with {len(digests)} stubs")
PY
fi

echo "state restored under $WORK"

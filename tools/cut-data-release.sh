#!/usr/bin/env bash
# Cuts (or tops up) a dated data release: uploads every artifact whose bytes
# differ from what data-pins.json already pins, then repoints the pins.
#
# Cuts are change-driven and delta-sized by construction. A finished year's
# shard hashes identically to its pin and is skipped forever; a normal cut
# uploads the whole-set files plus the current month's shards — a few MB.
# Assets on a dated tag are immutable by convention (never overwritten,
# never deleted); the narHash pins fail closed if the convention is ever
# violated.
#
# Needs `gh` authenticated with repo scope, and the artifacts already built
# by update-outpaths.sh --shard.
#
# Usage:
#   tools/cut-data-release.sh              # tag data-<today, UTC>
#   tools/cut-data-release.sh data-20260901
set -euo pipefail

MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$MT/index/.outpaths/data"
TAG="${1:-data-$(date -u +%Y%m%d)}"

if [ ! -d "$DATA/shards" ]; then
  echo "cut-data-release: no $DATA/shards; run update-outpaths.sh --shard first" >&2
  exit 1
fi

# The cut's candidate set: the whole-set files the fast path and mvs fetch —
# one triple per system, since a store path belongs to one — the tip snapshot
# frozen for this cut, and every period shard.
CANDIDATES=()
while IFS= read -r f; do
  CANDIDATES+=("$f")
done < <(find "$DATA" -maxdepth 1 \
  \( -name 'outpaths-*.json' -o -name 'tip-outpaths-*.json' -o -name 'outs-*.json' \) \
  | sort)
CANDIDATES+=("$DATA/outs-indexed.json.gz")
while IFS= read -r f; do
  CANDIDATES+=("$f")
done < <(find "$DATA/shards" -name '*.json.gz' | sort)

# Only bytes that moved get uploaded: compare each candidate's narHash to
# the pinned one.
CHANGED=()
for f in "${CANDIDATES[@]}"; do
  name=$(basename "$f")
  current=$(nix hash path --sri --type sha256 "$f")
  pinned=$(python3 -c "
import json, sys
pins = json.load(open('$MT/data-pins.json'))
print(pins['files'].get('$name', {}).get('narHash', ''))
")
  if [ "$current" != "$pinned" ]; then
    CHANGED+=("$f")
  fi
done

if [ ${#CHANGED[@]} -eq 0 ]; then
  echo "cut-data-release: every artifact matches its pin; nothing to cut"
  exit 0
fi
echo "cutting $TAG with ${#CHANGED[@]} changed file(s)"

# The day's first cut opens the release; a later run the same day is a
# top-up and `gh release create` never runs for it.
MODE="cut"
if gh release view "$TAG" > /dev/null 2>&1; then
  MODE="top-up"
fi

# What moved in the index this run, rendered from the working tree
# against HEAD. That comparison holds because update-index.yml cuts
# before it commits, so HEAD is still the previous index;
# release-notes.py says so rather than reporting zeroes when it is not.
# A notes failure never fails the cut: the standing sentence stands in.
NOTES=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$NOTES" "$BODY"' EXIT
python3 "$HERE/release-notes.py" --root "$MT" --mode "$MODE" --files "${CHANGED[@]}" > "$NOTES" \
  || echo "Automated dated cut of the store-path artifacts. Addressed by data-pins.json; assets on this tag are immutable. See docs/store-paths.md." > "$NOTES"

# A top-up keeps the notes of the cut that opened the release — they
# describe a different run — and gains this cut's section below them.
if [ "$MODE" = "cut" ]; then
  gh release create "$TAG" \
    --title "Store-path artifacts, ${TAG#data-}" \
    --notes-file "$NOTES"
else
  {
    gh release view "$TAG" --json body --jq .body
    printf '\n---\n\n'
    cat "$NOTES"
  } > "$BODY"
  gh release edit "$TAG" --notes-file "$BODY"
fi

gh release upload "$TAG" "${CHANGED[@]}"
bash "$HERE/bump-data-pin.sh" "$TAG" "${CHANGED[@]}"

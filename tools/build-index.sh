#!/usr/bin/env bash
# Builds index/versions.json from revisions.json.
#
# For each revision: check it out with `git archive` into a temp directory,
# extract {attr: version} for every top-level attribute, and compute the
# revision's narHash from the same checkout. One pass produces both.
#
# The checkout deliberately never enters the nix store. Forcing `drv.version`
# does not copy a tree into the store, so indexing costs one ~280 MB scratch
# directory at a time and zero store growth — measured. Materialising each
# revision into the store instead would need ~519 GB for the full revision set.
#
# Usage:
#   tools/build-index.sh                 # index every revision
#   tools/build-index.sh -n 30           # first 30 revisions only (smoke test)
#   tools/build-index.sh --merge-only    # rebuild the index from cache, no eval
#   tools/build-index.sh --incremental   # only revisions the index has never
#                                        # covered, merged into the existing one
#   tools/build-index.sh -j 64           # extract that many revisions at once
set -euo pipefail

# Data lives in the checkout, code lives next to this script. Under `nix run`
# those are two different places: the script is a store copy, while
# revisions.json and index/ must stay writable in the caller's checkout, which
# the flake wrapper passes down as MULTIVERSE_ROOT.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Exported because -j re-invokes this script per revision; the children must
# land on the same checkout rather than re-deriving it from their own $0.
export MULTIVERSE_ROOT="$MT"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The Nix half of the code — the evaluators this script drives nix-instantiate
# with — lives in nix/, one level up from the scripts. `nix run` copies the two
# directories in separately, so the flake wrapper names this one explicitly
# rather than letting it be derived from $0.
NIXDIR="${MULTIVERSE_NIX:-$(cd "$(dirname "$0")/../nix" && pwd)}"
# Optional. Point NIXPKGS at a clone to check revisions out of it rather than
# downloading them; with no clone every revision is materialised through
# `nix flake prefetch` instead.
NIXPKGS="${NIXPKGS:-}"
REVFILE="$MT/revisions.json"
OUT="$MT/index/versions.json"
WORK="$MT/index/.per-rev"
LIMIT=0
MERGE_ONLY=0
INCREMENTAL=0
JOBS=1
SUBCOMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) LIMIT="${2:-0}"; shift 2 ;;
    --merge-only) MERGE_ONLY=1; shift ;;
    --incremental) INCREMENTAL=1; shift ;;
    -j) JOBS="${2:-1}"; shift 2 ;;
    # Internal: how -j hands one revision to a child invocation.
    --extract-one) SUBCOMMAND=extract-one; EXTRACT_OFF="$2"; EXTRACT_SHA="$3"; EXTRACT_LABEL="$4"; shift 4 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$WORK"
FAILURES=0

# The extraction cache is keyed by the extractor's own hash as well as the
# revision. Without this, editing extract-versions.nix leaves every cached file
# silently stale and a "successful" rebuild quietly reuses the old logic.
# tools/cache-key.sh is what build-history.sh reads the same key out of.
# shellcheck source=cache-key.sh
. "$HERE/cache-key.sh"
EXTRACTOR_HASH=$(extractor_hash "$NIXDIR")

# One revision: materialise it, extract {attr: version}, and record its narHash
# beside the extraction. Deliberately touches no shared file, so that -j can run
# as many of these at once as the machine has cores.
extract_one() {
  local off=$1 sha=$2 label=$3
  local dest="$WORK/$sha.$EXTRACTOR_HASH.json"
  local tmp="" src narhash prefetched n start=$SECONDS

  if [ -s "$dest" ]; then
    echo "  $label: cached"
    return 0
  fi

  # Two ways to get the tree. The clone is preferred: `git archive` into a
  # scratch directory costs no store space and no download. Without a usable
  # clone — CI, or a revision the clone has never fetched — `nix flake prefetch`
  # downloads the GitHub tarball into the store instead and hands back the very
  # narHash that builtins.fetchTree will later expect.
  if [ -n "$NIXPKGS" ] && git -C "$NIXPKGS" cat-file -e "$sha^{commit}" 2>/dev/null; then
    tmp=$(mktemp -d)
    if ! git -C "$NIXPKGS" archive "$sha" 2>/dev/null | tar -x -C "$tmp"; then
      rm -rf "$tmp"
      echo "  $label: CHECKOUT FAILED (rev not in clone? try git fetch)"
      return 1
    fi
    src="$tmp"
    # narHash from the same checkout: identical to what fetchTree computes for
    # the GitHub tarball, since nixpkgs sets no export-ignore attributes.
    narhash=$(nix hash path --sri --type sha256 "$tmp" 2>/dev/null || true)
  else
    if ! prefetched=$(nix flake prefetch --json "github:NixOS/nixpkgs/$sha" 2>/dev/null); then
      echo "  $label: FETCH FAILED (no clone, and GitHub would not serve $sha)"
      return 1
    fi
    src=$(printf '%s' "$prefetched" | python3 -c 'import json,sys; print(json.load(sys.stdin)["storePath"])')
    narhash=$(printf '%s' "$prefetched" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])')
  fi

  if nix-instantiate --eval --strict --json \
       --arg revPath "$src" --arg attrs 'null' \
       "$NIXDIR/extract-versions.nix" > "$dest.tmp" 2>"$dest.err"; then
    mv "$dest.tmp" "$dest"
    n=$(python3 -c "import json;print(len(json.load(open('$dest'))))")
    if [ -n "$narhash" ]; then
      printf '%s' "$narhash" > "$WORK/$sha.narhash"
    fi
    # One line per revision, emitted whole: with -j these interleave, and a
    # half-written line from another worker lands in the middle otherwise.
    echo "  $label: $n attrs in $((SECONDS - start))s"
  else
    rm -f "$dest.tmp"
    echo "  $label: EVAL FAILED ($((SECONDS - start))s): $(grep -m1 -o 'error:.*' "$dest.err" | head -c 55)"
    [ -n "$tmp" ] && rm -rf "$tmp"
    return 1
  fi

  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}

# Re-entry point for -j: the parallel driver below runs this script once per
# revision, and each of those invocations lands here.
if [ "$SUBCOMMAND" = "extract-one" ]; then
  extract_one "$EXTRACT_OFF" "$EXTRACT_SHA" "$EXTRACT_LABEL"
  exit $?
fi

if [ "$MERGE_ONLY" -eq 0 ]; then
  # `revisionCount` records how many revisions the committed index was built
  # against, so everything at or past that offset is exactly what an incremental
  # run has never looked at.
  mapfile -t TARGETS < <(python3 -c "
import json, os
revs = json.load(open('$REVFILE'))
sel = list(enumerate(revs))
if $INCREMENTAL:
    covered = json.load(open('$OUT'))['revisionCount'] if os.path.exists('$OUT') else 0
    sel = [(i, r) for i, r in sel if i >= covered]
if $LIMIT: sel = sel[:$LIMIT]
for i, r in sel: print(i, r['rev'], r['date'])
")
  echo "indexing ${#TARGETS[@]} revisions   extractor=$EXTRACTOR_HASH"

  if [ "$JOBS" -gt 1 ]; then
    # xargs exits 123 when any child did, which is all the failure signal the
    # merge below needs — the children report their own revisions by name.
    if ! printf '%s\n' "${TARGETS[@]}" | xargs -P "$JOBS" -L 1 bash "$0" --extract-one; then
      FAILURES=1
    fi
  else
    for line in "${TARGETS[@]}"; do
      set -- $line
      extract_one "$1" "$2" "$3" || FAILURES=$((FAILURES + 1))
    done
  fi
  echo

  # Fold the per-revision narHash files back in. Deferred to here because the
  # -j children cannot each rewrite revisions.json: they would race and the
  # last writer would drop every hash the others had just recorded.
  python3 - "$REVFILE" "$WORK" <<'PY'
import json, os, sys

revfile, work = sys.argv[1:3]
revs = json.load(open(revfile))
recorded = 0
for r in revs:
    p = os.path.join(work, r['rev'] + '.narhash')
    if not os.path.exists(p):
        continue
    h = open(p).read().strip()
    if h and r.get('narHash') != h:
        r['narHash'] = h
        recorded += 1
if recorded:
    json.dump(revs, open(revfile, 'w'), indent=1)
print(f"narHash: {recorded} newly recorded")
PY
fi

# Merge whatever the cache holds into { revisionCount, attrs }.
#
# Values are offsets into revisions.json and only the NEWEST revision shipping
# each version is kept, so the index stays flat as revisions are added rather
# than growing a per-revision entry for every unchanged package.
#
# An incremental merge folds only the new offsets into the committed index
# instead of rebuilding from index/.per-rev. That is what makes the whole thing
# runnable on CI, where the cache does not exist and a rebuild from an empty
# cache would silently produce an empty index.
python3 - "$WORK" "$EXTRACTOR_HASH" "$OUT" "$REVFILE" "$INCREMENTAL" <<'PY'
import json, os, sys
work, ehash, out, revfile, incremental = sys.argv[1:6]
incremental = incremental == "1"
revs = json.load(open(revfile))

# Offsets below this were already folded in by an earlier run; a full rebuild
# reconsiders all of them.
covered = 0
attrs = {}
if incremental and os.path.exists(out):
    prior = json.load(open(out))
    covered, attrs = prior['revisionCount'], prior['attrs']
    # A version still current at the newest revision covered is stored with a
    # null offset — see the dump below. Resolve it against the count the file
    # carries, which is the one that wrote those nulls, not len(revs): a
    # revision appended since is a revision this index has not looked at.
    tip = covered - 1
    for versions in attrs.values():
        for version, off in versions.items():
            if off is None:
                versions[version] = tip

indexed = 0
for off in range(covered, len(revs)):          # oldest first: later writes win
    p = os.path.join(work, f"{revs[off]['rev']}.{ehash}.json")
    if not os.path.exists(p):
        # An incremental run must not claim coverage past a revision it failed
        # to extract, or that revision is skipped for good. Stop here and let
        # the next run retry it.
        if incremental:
            print(f"stopping at offset {off}: no extraction on disk, will retry next run")
            break
        continue
    indexed += 1
    for attr, version in json.load(open(p)).items():
        attrs.setdefault(attr, {})[version] = off
    covered = off + 1

# A full rebuild has considered every revision, whether or not each one left an
# extraction behind; an incremental run only claims the prefix it got through.
if not incremental:
    covered = len(revs)

# A version still shipping in the newest revision covered is written as null
# rather than as that offset, because that offset moves every single run.
# Recording it literally means an append rewrites the entry of every version
# that did *not* change — 24,854 of 31,819 attributes on a typical revision —
# and git stores that as ~140 KB of scattered edits rather than the ~3 KB that
# actually changed. Readers substitute revisionCount - 1; see docs/design.md.
tip = covered - 1
open_ended = {
    attr: {version: (None if off == tip else off) for version, off in versions.items()}
    for attr, versions in attrs.items()
}
json.dump({"revisionCount": covered, "attrs": open_ended}, open(out, 'w'), sort_keys=True)
pairs = sum(len(v) for v in attrs.values())
merged = f"{indexed} new" if incremental else f"{indexed}/{len(revs)}"
print(f"index: {merged} revisions merged, covering {covered}/{len(revs)}, "
      f"{len(attrs):,} attrs, {pairs:,} (attr, version) pairs")
print(f"       -> {out} ({os.path.getsize(out)/1e6:.2f} MB)")
PY

# An incremental run indexes revisions that landed on nixos-unstable days ago;
# one of those failing to evaluate is a bug to look at, not a casualty to shrug
# off, and the index that comes out stops short of the revisions.json beside it.
# Failing here is what keeps the update job from committing that pair.
#
# A full rebuild is held to a looser standard on purpose: it reaches back to
# 2015, and a handful of those revisions will never evaluate on a current Nix.
if [ "$INCREMENTAL" -eq 1 ] && [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES revision(s) failed to index; index left behind revisions.json" >&2
  exit 1
fi

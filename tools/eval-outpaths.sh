#!/usr/bin/env bash
# Evaluates nixpkgs revisions with nix-eval-jobs to get exact store paths.
#
# One file per (revision, system) under index/.eval, holding every top-level
# attribute's outputs. This is the digest source the store-path artifacts are
# joined from: the channel listing says what Hydra built, and an evaluation at
# an explicit `system` says which path that is. The name-keyed listing lookup
# this replaces handed x86_64 users aarch64 binaries for two thirds of the
# index (issue #12); see docs/store-paths.md.
#
# Revisions are checked out with `git archive` into a scratch directory, the
# way tools/build-index.sh does, and never enter the store. That the digests
# survive this was worth checking rather than assuming, since forcing `outPath`
# does hash trees the expression imports: evaluating the 2026-08-17 tip out of
# two differently-named plain directories and out of the store's `-source` path
# gives byte-identical outputs for all 24,346 attributes.
#
# It is also what makes the backfill parallel. Materialising into the store
# instead puts every job behind the nix daemon adding a 280 MB tree, which on a
# 256-core machine was the whole bottleneck — and it costs 430 GB of store
# across the revision set, against a few hundred MB of scratch per job here.
#
# Usage:
#   tools/eval-outpaths.sh                        every revision, x86_64-linux
#   tools/eval-outpaths.sh --system aarch64-linux
#   tools/eval-outpaths.sh --system x86_64-linux,aarch64-linux
#   tools/eval-outpaths.sh --offsets 1500:        offset range (python slice)
#   tools/eval-outpaths.sh --offsets 14,154,939   named offsets, comma separated
#   tools/eval-outpaths.sh -n 5                   first 5 revisions (smoke test)
#   tools/eval-outpaths.sh -j 8                   that many revisions at once
#   tools/eval-outpaths.sh --workers 4 --max-memory 4096
#   tools/eval-outpaths.sh --topup               fold the listed package sets
#                                                into existing evaluations
#
# --topup is for the case where nix/nested-sets.nix gained or lost a set and
# nothing else changed. Adding a set can only add rows to an evaluation — the
# list is read in one branch, which fires for one attribute, which reported
# nothing before — so the rows already on disk are still exactly right and
# re-deriving them costs 52 seconds a file against 3. It refuses to run when
# the evaluator half of the key has moved too, since then the old rows are the
# thing in question; --assume-additive overrides that for a change you have
# checked by hand.
set -euo pipefail

# Data lives in the checkout, code lives next to this script. Under `nix run`
# those are two different places: the script is a store copy, while index/ must
# stay writable in the caller's checkout, which the flake wrapper passes down as
# MULTIVERSE_ROOT. Exported because -j re-invokes this script per revision.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export MULTIVERSE_ROOT="$MT"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The evaluator this script drives nix-eval-jobs with lives in nix/, which
# `nix run` copies in as its own store path. See build-index.sh.
NIXDIR="${MULTIVERSE_NIX:-$(cd "$(dirname "$0")/../nix" && pwd)}"
export MULTIVERSE_NIX="$NIXDIR"
# Optional, and worth having: a clone every revision can be checked out of.
# Without one every revision is downloaded through `nix flake prefetch`
# instead, which is both slower and serialised behind the nix daemon.
NIXPKGS="${NIXPKGS:-}"
export NIXPKGS
REVFILE="$MT/revisions.json"
WORK="$MT/index/.eval"

# -j re-invokes this script per revision and the children re-run this parsing,
# so every setting the child also needs is read back out of the environment the
# parent exported it into rather than reset to the default here. The names are
# namespaced because the environment they travel through is also a CI job's.
SYSTEM="${EVAL_SYSTEM:-x86_64-linux}"
OFFSETS=":"
LIMIT=0
JOBS=1
# Per-revision evaluation is split across nix-eval-jobs workers, each of which
# recycles when it hits --max-memory. Six at 3 GB walks the whole top level of a
# 2026 revision in ~50 seconds; the defaults are sized for one revision on a
# laptop, and -j on a big machine wants them lower.
WORKERS="${EVAL_WORKERS:-6}"
MAXMEM="${EVAL_MAXMEM:-3072}"
# Nix's evaluator recursion limit, set here rather than left to whatever the
# host's Nix defaults to: texlive's `un_adj` recursion overruns the older
# default of 10,000 and takes the whole run down with it, so the same revision
# resolves 16,859 attributes on one machine and none on another. An explicit
# ceiling makes coverage a property of nixpkgs, not of the runner.
CALLDEPTH="${EVAL_CALLDEPTH:-100000}"
# Fold the listed package sets into the evaluations already on disk instead of
# re-running them whole. See the header, and tools/cache-key.sh for when it is
# safe.
TOPUP="${EVAL_TOPUP:-0}"
ASSUME_ADDITIVE="${EVAL_ASSUME_ADDITIVE:-0}"
SUBCOMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --system) SYSTEM="$2"; shift 2 ;;
    --offsets) OFFSETS="$2"; shift 2 ;;
    -n) LIMIT="${2:-0}"; shift 2 ;;
    -j) JOBS="${2:-1}"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --max-memory) MAXMEM="$2"; shift 2 ;;
    --topup) TOPUP=1; shift ;;
    --assume-additive) ASSUME_ADDITIVE=1; shift ;;
    # Internal: how -j hands one revision to a child invocation.
    --eval-one) SUBCOMMAND=eval-one; EVAL_SHA="$2"; EVAL_LABEL="$3"; shift 3 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
EVAL_SYSTEM="$SYSTEM"
EVAL_WORKERS="$WORKERS"
EVAL_MAXMEM="$MAXMEM"
EVAL_CALLDEPTH="$CALLDEPTH"
EVAL_TOPUP="$TOPUP"
EVAL_ASSUME_ADDITIVE="$ASSUME_ADDITIVE"
export EVAL_SYSTEM EVAL_WORKERS EVAL_MAXMEM EVAL_CALLDEPTH EVAL_TOPUP EVAL_ASSUME_ADDITIVE

if ! command -v nix-eval-jobs >/dev/null 2>&1; then
  echo "eval-outpaths: nix-eval-jobs is not on PATH." >&2
  echo "Enter the dev shell (nix develop), or run through nix run .#eval-outpaths." >&2
  exit 1
fi

mkdir -p "$WORK"

# The cache is keyed by the evaluator's own hash as well as by revision and
# system. Without it, editing eval-outpaths.nix leaves every cached file
# silently stale and a "successful" rerun quietly reuses the old logic. The key
# has two halves, evaluator and package-set list, so that a program can tell
# which of them moved; tools/cache-key.sh is where that is spelled out.
# shellcheck source=cache-key.sh
. "$HERE/cache-key.sh"
EVALUATOR_HASH=$(evaluator_hash "$NIXDIR")
EVAL_KEY=$(eval_key "$NIXDIR")
export EVALUATOR_HASH EVAL_KEY

# The newest full evaluation on disk for one (revision, system), whatever key
# it was written under, or nothing. Newest-by-mtime is the rule
# join-eval-listing.py already reads these files by, so a top-up folds into the
# same file the join would have used.
newest_eval() {
  local sha=$1 system=$2 f
  f=$(ls -t "$WORK/$sha.$system."*.json 2>/dev/null | grep -v '\.errors\.json$' | head -1) || true
  printf '%s' "$f"
}

# One (revision, system) topped up: evaluate only the package sets
# nix/nested-sets.nix names, and fold their rows into the full evaluation
# already on disk.
#
# The nested rows are replaced rather than appended, so one operation covers
# every edit to the list — a set removed from it loses the rows it used to
# contribute, which an append would leave behind forever.
topup_system() {
  local sha=$1 label=$2 system=$3 src=$4
  local dest="$WORK/$sha.$system.$EVAL_KEY.json"
  local base baseKey start=$SECONDS

  if [ -s "$dest" ]; then
    echo "  $label $system: cached"
    return 0
  fi

  # A (revision, system) with no evaluation at all is a skip rather than a
  # failure: aarch64-darwin cannot be evaluated from a nixpkgs older than 2021
  # at all, so a full-range top-up meets hundreds of these and an exit code
  # that counted them would never mean anything. A run against a cache that is
  # simply empty says so on every line instead.
  base=$(newest_eval "$sha" "$system")
  if [ -z "$base" ]; then
    echo "  $label $system: skipped, no evaluation to top up"
    return 0
  fi

  # The evaluator half of the base file's key. A file written before the key
  # was split carries one hash and no dash, so its whole key is compared —
  # which will not match, and that is correct: it was produced by a different
  # evaluator.
  baseKey=$(basename "$base" .json); baseKey=${baseKey##*.}
  if [ "${baseKey%%-*}" != "$EVALUATOR_HASH" ] && [ "$ASSUME_ADDITIVE" -eq 0 ]; then
    echo "  $label $system: base was built by evaluator ${baseKey%%-*}, not $EVALUATOR_HASH — refusing"
    return 1
  fi

  # Only the listed sets. `attrs` takes a Nix expression, so the list is read
  # from the same file the key is computed over rather than spelled again here.
  if ! nix-eval-jobs \
      --workers "$WORKERS" --max-memory-size "$MAXMEM" --no-instantiate \
      --option max-call-depth "$CALLDEPTH" \
      --arg revPath "$src" --argstr system "$system" \
      --arg attrs "import $NIXDIR/nested-sets.nix" \
      "$NIXDIR/eval-outpaths.nix" > "$dest.jsonl" 2> "$dest.err"; then
    rm -f "$dest.jsonl"
    echo "  $label $system: TOPUP FAILED ($((SECONDS - start))s): $(grep -m1 -o 'error:.*' "$dest.err" | head -c 55)"
    return 1
  fi

  python3 "$HERE/reduce-eval-jobs.py" \
    --jobs "$dest.jsonl" --rev "$sha" --system "$system" \
    --out "$dest.nested" --errors "$dest.nested.errors" > /dev/null

  if ! python3 "$HERE/merge-nested-eval.py" \
      --base "$base" --nested "$dest.nested" --out "$dest.merged" \
      --base-errors "${base%.json}.errors.json" \
      --nested-errors "$dest.nested.errors" \
      --out-errors "$WORK/$sha.$system.$EVAL_KEY.errors.json" > "$dest.count"; then
    rm -f "$dest.jsonl" "$dest.err" "$dest.nested" "$dest.nested.errors" "$dest.merged" "$dest.count"
    echo "  $label $system: MERGE FAILED"
    return 1
  fi

  # Named last, so an interrupted top-up leaves no file the join would read as
  # a finished one.
  mv "$dest.merged" "$dest"
  rm -f "$dest.jsonl" "$dest.err" "$dest.nested" "$dest.nested.errors"
  echo "  $label $system: topped up to $(cat "$dest.count") in $((SECONDS - start))s"
  rm -f "$dest.count"
  return 0
}

# One (revision, system): walk every top-level attribute of a materialised
# source and reduce the run to the per-revision file.
eval_system() {
  local sha=$1 label=$2 system=$3 src=$4
  local dest="$WORK/$sha.$system.$EVAL_KEY.json"
  local start=$SECONDS

  if [ "$TOPUP" -eq 1 ]; then
    topup_system "$sha" "$label" "$system" "$src"
    return $?
  fi

  if [ -s "$dest" ]; then
    echo "  $label $system: cached"
    return 0
  fi

  # nix-eval-jobs reports a failing attribute as a JSON line and carries on, so
  # a non-zero exit here means the run itself died — a revision modern Nix
  # cannot read at all, which keeps no file rather than a partial one.
  if ! nix-eval-jobs \
      --workers "$WORKERS" --max-memory-size "$MAXMEM" --no-instantiate \
      --option max-call-depth "$CALLDEPTH" \
      --arg revPath "$src" --argstr system "$system" \
      "$NIXDIR/eval-outpaths.nix" > "$dest.jsonl" 2> "$dest.err"; then
    # The partial JSONL goes; the stderr stays, since a revision modern Nix
    # cannot read is worth keeping the trace of.
    rm -f "$dest.jsonl"
    echo "  $label $system: EVAL FAILED ($((SECONDS - start))s): $(grep -m1 -o 'error:.*' "$dest.err" | head -c 55)"
    return 1
  fi

  python3 "$HERE/reduce-eval-jobs.py" \
    --jobs "$dest.jsonl" --rev "$sha" --system "$system" \
    --out "$dest" --errors "$WORK/$sha.$system.$EVAL_KEY.errors.json" \
    > "$dest.count"
  # The raw run is worth keeping only while it is unreduced: the JSONL is a
  # few hundred MB across a backfill and the stderr trace is larger still, and
  # the per-attribute reason survives in the errors file either way.
  rm -f "$dest.jsonl" "$dest.err"

  # One line per (revision, system), emitted whole: with -j these interleave,
  # and a half-written line from another worker lands in the middle otherwise.
  echo "  $label $system: $(cat "$dest.count") in $((SECONDS - start))s"
  rm -f "$dest.count"
  return 0
}

# One revision, for every system asked for. Touches no shared state, so -j can
# run as many of these at once as the machine has memory for.
eval_one() {
  local sha=$1 label=$2
  local src="" tmp="" failures=0 wanted=0 system

  # Nothing to check out when every system already has its file — the
  # difference between a resumed backfill costing a stat and costing a
  # download.
  for system in ${SYSTEM//,/ }; do
    [ -s "$WORK/$sha.$system.$EVAL_KEY.json" ] || wanted=1
  done
  if [ "$wanted" -eq 0 ]; then
    echo "  $label: cached"
    return 0
  fi

  # The clone first: `git archive` into scratch costs no store space, no
  # download and no daemon round trip. The scratch lives under the work
  # directory rather than in $TMPDIR, which on a big machine is often tmpfs —
  # 32 jobs holding a 280 MB checkout each is not something to put in RAM.
  if [ -n "$NIXPKGS" ] && git -C "$NIXPKGS" cat-file -e "$sha^{commit}" 2>/dev/null; then
    mkdir -p "$WORK/tmp"
    tmp=$(mktemp -d "$WORK/tmp/$sha.XXXXXX")
    if ! git -C "$NIXPKGS" archive "$sha" 2>/dev/null | tar -x -C "$tmp"; then
      rm -rf "$tmp"
      echo "  $label: CHECKOUT FAILED (rev not in clone? try git fetch)"
      return 1
    fi
    src="$tmp"
  else
    if ! src=$(nix flake prefetch --json "github:NixOS/nixpkgs/$sha" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["storePath"])'); then
      echo "  $label: FETCH FAILED (no clone, and GitHub would not serve $sha)"
      return 1
    fi
  fi

  for system in ${SYSTEM//,/ }; do
    eval_system "$sha" "$label" "$system" "$src" || failures=$((failures + 1))
  done

  [ -n "$tmp" ] && rm -rf "$tmp"
  return $((failures > 0))
}

# Re-entry point for -j: the parallel driver below runs this script once per
# revision, and each of those invocations lands here.
if [ "$SUBCOMMAND" = "eval-one" ]; then
  eval_one "$EVAL_SHA" "$EVAL_LABEL"
  exit $?
fi

# --offsets is a comma-separated list of python slices and bare indices, so
# that a validation run can name the four revisions it cares about and a
# backfill can hand over a contiguous range.
mapfile -t TARGETS < <(python3 -c "
import json
revs = list(enumerate(json.load(open('$REVFILE'))))
sel = []
for part in '$OFFSETS'.split(','):
    sel += revs[slice(*[int(x) if x else None for x in part.split(':')])] if ':' in part else [revs[int(part)]]
if $LIMIT: sel = sel[:$LIMIT]
for i, r in sel: print(r['rev'], f\"{i}:{r['date']}\")
")
if [ "$TOPUP" -eq 1 ]; then
  echo "topping up ${#TARGETS[@]} revisions   systems=$SYSTEM   key=$EVAL_KEY"
else
  echo "evaluating ${#TARGETS[@]} revisions   systems=$SYSTEM   key=$EVAL_KEY"
fi

FAILURES=0
if [ "$JOBS" -gt 1 ]; then
  # xargs exits 123 when any child did, which is all the failure signal needed
  # here — the children report their own revisions by name.
  if ! printf '%s\n' "${TARGETS[@]}" | xargs -P "$JOBS" -L 1 bash "$0" --eval-one; then
    FAILURES=1
  fi
else
  for line in "${TARGETS[@]}"; do
    # shellcheck disable=SC2086
    set -- $line
    eval_one "$1" "$2" || FAILURES=$((FAILURES + 1))
  done
fi

echo "eval-outpaths: per-revision files in $WORK"
[ "$FAILURES" -eq 0 ]

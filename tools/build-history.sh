#!/usr/bin/env bash
# Builds index/history.json from the extraction cache index/.per-rev holds.
#
# Where index/versions.json records only the NEWEST revision shipping each
# version, this records *when each version was present* — as run-length ranges
# of revision offsets. That is what turns the index from a lookup table into a
# timeline: version lifetimes, "what did nixpkgs have on date D", and package
# removals all fall out of it, none of which the newest-only encoding can answer.
#
# It lives in its own file rather than inside versions.json on purpose.
# multiverse.nix parses versions.json on every evaluation that resolves a
# version, and history is ~48% larger. Measured, that is ~40-50 ms of
# builtins.fromJSON that a plain `mv.version "python3" "3.8.9"` would pay
# forever to carry data it never reads.
#
# This tool never evaluates a revision. It only folds together what
# build-index.sh already extracted, which is why a full rebuild is seconds
# rather than the days a re-extraction would take.
#
# Usage:
#   tools/build-history.sh                # rebuild from the whole cache
#   tools/build-history.sh --incremental  # fold in only what is new
set -euo pipefail

# Same split as build-index.sh: data in the caller's checkout, code beside this
# script, which under `nix run` are two different places.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The evaluators live in nix/, which `nix run` copies in as its own store path;
# the flake wrapper names it MULTIVERSE_NIX. See build-index.sh.
NIXDIR="${MULTIVERSE_NIX:-$(cd "$(dirname "$0")/../nix" && pwd)}"
REVFILE="$MT/revisions.json"
OUT="$MT/index/history.json"
WORK="$MT/index/.per-rev"
INCREMENTAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --incremental) INCREMENTAL=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Keyed by the extractor's hash exactly as build-index.sh keys it, so the two
# files can never be built from different extraction logic. One definition,
# read out of the same file by both, because the promise in that sentence used
# to rest on two scripts spelling the same formula.
# shellcheck source=cache-key.sh
. "$HERE/cache-key.sh"
EXTRACTOR_HASH=$(extractor_hash "$NIXDIR")

if [ ! -d "$WORK" ]; then
  echo "build-history: no extraction cache at $WORK" >&2
  echo "  history is folded from what build-index.sh extracted; run that first." >&2
  exit 1
fi

python3 - "$WORK" "$EXTRACTOR_HASH" "$OUT" "$REVFILE" "$INCREMENTAL" <<'PY'
import json, os, sys

work, ehash, out, revfile, incremental = sys.argv[1:6]
incremental = incremental == "1"
revs = json.load(open(revfile))

# On disk a version with one unbroken run is [first, last]; one with gaps is a
# list of those pairs. 91.6% of pairs are single-run, so collapsing the common
# case is worth the one isinstance check it costs a reader.
#
# A run still open at the newest revision covered is written [first, null]
# rather than [first, tip], because that tip moves on every run: closing those
# runs literally means an append rewrites the end offset of every version that
# did *not* change — 24,854 of 31,819 attributes on a typical revision — which
# git stores as ~140 KB of scattered edits rather than the ~3 KB that actually
# changed. Readers substitute revisionCount - 1; see docs/design.md.
def pack(runs, tip):
    ended = [[first, None] if last == tip else [first, last] for first, last in runs]
    return ended[0] if len(ended) == 1 else ended

# The inverse, and the reason `tip` is threaded through rather than taken from
# len(revs): a null resolves against the count of the file that wrote it, so an
# index sitting behind revisions.json still ends where it says it ends.
def unpack(v, tip):
    runs = [v] if v and not isinstance(v[0], list) else v
    return [[first, tip if last is None else last] for first, last in runs]

covered = 0
skipped = []
attrs = {}
if incremental and os.path.exists(out):
    prior = json.load(open(out))
    if prior['revisionCount'] > len(revs):
        sys.exit(f"build-history: history covers {prior['revisionCount']} revisions "
                 f"but revisions.json has {len(revs)}; revisions.json was reordered")
    covered, skipped = prior['revisionCount'], prior['skipped']
    attrs = {
        a: {v: unpack(r, covered - 1) for v, r in vs.items()}
        for a, vs in prior['attrs'].items()
    }

# The last offset actually folded in, which is what decides whether the next one
# extends a run or starts a new one. Not `off - 1`: a skipped revision must not
# break a run, because a revision nobody extracted is a revision nobody has
# evidence about either way.
prev = covered - 1
indexed = 0

for off in range(covered, len(revs)):
    p = os.path.join(work, f"{revs[off]['rev']}.{ehash}.json")
    if not os.path.exists(p):
        # An incremental run must not fold offset N+1 while N is missing: doing
        # so would punch a hole into every run that spans the two and record it
        # as a genuine absence. Stop and let the next run pick it up once
        # build-index.sh has extracted it.
        if incremental:
            # build-index.sh extracts starting from versions.json's own
            # revisionCount. If versions.json already covers this offset, that
            # extraction has been and gone and nothing will ever produce it
            # again — history is stuck here, not merely behind. The two files
            # have to advance together, so say so instead of quietly stopping
            # at the same offset on every future run.
            vcount = 0
            vfile = os.path.join(os.path.dirname(out), 'versions.json')
            if os.path.exists(vfile):
                vcount = json.load(open(vfile))['revisionCount']
            if off < vcount:
                sys.exit(
                    f"build-history: offset {off} has no extraction, but versions.json "
                    f"already covers {vcount} revisions, so build-index.sh will never "
                    f"extract it again.\n"
                    f"  history.json and index/versions.json have to cover the same "
                    f"revisions to stay in step.\n"
                    f"  Fix by re-extracting from a full cache: tools/build-index.sh "
                    f"(cached revisions are skipped), then rerun this without "
                    f"--incremental."
                )
            print(f"stopping at offset {off}: no extraction on disk, will retry next run")
            break
        # A full rebuild reaches back to 2013 and some of those revisions will
        # never evaluate on a current Nix. Record them so a consumer can tell
        # "absent here" from "never looked here", and carry on.
        skipped.append(off)
        continue

    indexed += 1
    for attr, version in json.load(open(p)).items():
        runs = attrs.setdefault(attr, {}).setdefault(version, [])
        if runs and runs[-1][1] == prev:
            runs[-1][1] = off
        else:
            runs.append([off, off])
    prev = off
    covered = off + 1

# Trailing skips are not coverage: `covered` only advances on a revision that
# was actually folded in, so a skip past the last extraction leaves it alone.
skipped = sorted(set(s for s in skipped if s < covered))

packed = {a: {v: pack(r, covered - 1) for v, r in vs.items()} for a, vs in attrs.items()}
json.dump({"revisionCount": covered, "skipped": skipped, "attrs": packed},
          open(out, 'w'), sort_keys=True)

pairs = sum(len(v) for v in attrs.values())
gapped = sum(1 for vs in attrs.values() for r in vs.values() if len(r) > 1)
merged = f"{indexed} new" if incremental else f"{indexed}/{len(revs)}"
print(f"history: {merged} revisions merged, covering {covered}/{len(revs)}, "
      f"{len(attrs):,} attrs, {pairs:,} (attr, version) pairs")
print(f"         {gapped:,} pairs ({100 * gapped / pairs:.2f}%) are non-contiguous, "
      f"{len(skipped)} revision(s) skipped")
print(f"         -> {out} ({os.path.getsize(out) / 1e6:.2f} MB)")
PY

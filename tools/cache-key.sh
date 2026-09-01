#!/usr/bin/env bash
# The cache keys the per-revision artifacts are addressed by, in one place.
#
# Each key is the hash of everything that decides what an evaluator produces:
# the evaluator itself, and the package-set list it walks. Editing either has
# to move the key, or the next run silently reuses files built under the old
# logic and reports success.
#
# Shared rather than repeated because the two index builders must agree exactly
# — build-history.sh folds the very files build-index.sh wrote, and a formula
# duplicated in both scripts is one edit away from a hash that matches nothing
# on disk and a history built from zero revisions.
#
# Sourced, not executed: `. "$HERE/cache-key.sh"`, with the nix/ directory
# passed to each function, since under `nix run` it is a store path the caller
# knows and this file cannot derive.

# Key for tools/build-index.sh and tools/build-history.sh: index/.per-rev.
extractor_hash() {
  cat "$1/extract-versions.nix" "$1/nested-sets.nix" | sha256sum | cut -c1-8
}

# Key for tools/eval-outpaths.sh: index/.eval. A different evaluator over the
# same list, so the list counts here too — a package set added to it has no
# store paths until this key moves and the evaluations are redone.
evaluator_hash() {
  cat "$1/eval-outpaths.nix" "$1/nested-sets.nix" | sha256sum | cut -c1-8
}

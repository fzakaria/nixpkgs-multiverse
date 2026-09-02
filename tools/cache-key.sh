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

# Key for tools/eval-outpaths.sh: index/.eval. Two halves rather than one
# number, because the two inputs differ in what a change to them can do.
#
# `nested-sets.nix` appears once in the evaluator, in a branch that fires only
# for the attribute it names, and that attribute produced no row before — a
# package set is a non-derivation attrset, which projects to `{}` and is
# neither reported nor recursed into. So a list edit can only ADD rows to an
# evaluation. It can never move or drop one.
#
# `eval-outpaths.nix` has no such guarantee: flip `allowUnfree` in the config it
# passes nixpkgs and thousands of rows should disappear, and a cached file that
# kept them looks perfectly plausible while naming builds nobody makes.
#
# Splitting them means a program can tell which one moved. Same left half and a
# different right half is a list edit, which `--topup` can fold into the
# evaluations already on disk in 3 seconds a file; a different left half means
# the rows themselves are in question and the 52-second full pass is the only
# honest answer.
evaluator_hash() {
  sha256sum "$1/eval-outpaths.nix" | cut -c1-8
}

nested_list_hash() {
  sha256sum "$1/nested-sets.nix" | cut -c1-8
}

# The whole key as it appears in a filename: <evaluator>-<list>.
eval_key() {
  echo "$(evaluator_hash "$1")-$(nested_list_hash "$1")"
}

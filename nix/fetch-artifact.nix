# One pinned store-path artifact, as a fixed-output derivation. Separate from
# data.nix so checks.nix can aim this exact fetcher at a colliding file.
#
# fetchurl, not fetchTree: fetchTree downloads during evaluation, and nothing
# reads these until a build does. recursiveHash: data-pins.json records NAR
# hashes, not flat ones. unsafeDiscardReferences: Nix scans output for the bare
# hash part of every store path in the input closure — which is what these
# artifacts are lists of — and a fixed-output derivation may not have references
# at all. __structuredAttrs is explicit because fetchurl sets it only from 26.05
# on, and the discard is ignored without it.
{ pkgs }:
{ url, hash }:
pkgs.fetchurl {
  inherit url hash;
  recursiveHash = true;
  derivationArgs = {
    __structuredAttrs = true;
    unsafeDiscardReferences.out = true;
  };
}

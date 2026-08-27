# The pinned store-path artifacts, assembled into one directory.
#
# Each file is fetched by the {tag, narHash} records in data-pins.json —
# hash-verified, so an overwritten release asset fails closed — and nothing is
# fetched until something builds a site or a database out of this.
#
# pkgs.fetchurl rather than builtins.fetchTree, which is what makes that last
# sentence true. fetchTree is an eval-time builtin: the store path it returns is
# content-addressed, so it cannot be known until the bytes are on disk, and
# interpolating one into a builder downloads it during evaluation. Every
# consumer here only ever hands these files to a build — nothing reads them at
# eval time — so a fixed-output derivation defers the whole ~300 MB to build
# time, where a remote builder can do the work and a binary cache can substitute
# the result. multiverse.nix's own fetchArtifact stays on fetchTree, because it
# does readFile what it fetches.
#
# recursiveHash, because data-pins.json records the NAR hash of each file rather
# than the flat hash of its bytes. The pins verify unchanged either way.
{ pkgs }:
let
  pins = builtins.fromJSON (builtins.readFile ../data-pins.json);
  fetched = builtins.mapAttrs (
    name: pin:
    pkgs.fetchurl {
      url = "${pins.baseUrl}/${pin.tag}/${name}";
      hash = pin.narHash;
      recursiveHash = true;
    }
  ) pins.files;
in
# Symlinks rather than copies: the consumers glob this directory and open what
# they find, so a copy would only be a second ~300 MB of store.
pkgs.linkFarm "multiverse-data" fetched

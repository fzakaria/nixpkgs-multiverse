# The pinned store-path artifacts, assembled into one directory.
#
# Each file is fetched by the {tag, narHash} records in data-pins.json —
# hash-verified, so an overwritten release asset fails closed — and nothing is
# fetched until something builds a site or a database out of this. See
# fetch-artifact.nix for how one file becomes a derivation, and why.
{ pkgs }:
let
  fetchArtifact = import ./fetch-artifact.nix { inherit pkgs; };
  pins = builtins.fromJSON (builtins.readFile ../data-pins.json);
  fetched = builtins.mapAttrs (
    name: pin:
    fetchArtifact {
      url = "${pins.baseUrl}/${pin.tag}/${name}";
      hash = pin.narHash;
    }
  ) pins.files;
in
# Symlinks rather than copies: the consumers glob this directory and open what
# they find, so a copy would only be a second ~300 MB of store.
pkgs.linkFarm "multiverse-data" fetched

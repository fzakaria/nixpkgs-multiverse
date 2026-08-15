# Extracts {attrname -> derivation name} for a single vendored revision.
#
# The store-path matcher (tools/match-outpaths.py) resolves an (attr, version)
# pair to a derivation name before it can look the name up in a channel's
# store-paths listing, and `pname` frequently differs from the attribute
# (python3 -> python3-3.12.4). This is the evaluation that closes that gap.
#
# Mirrors the total-eval style of tools/extract-versions.nix: any attribute
# that fails to evaluate (broken package, unfree assertion, platform mismatch)
# yields null rather than aborting the whole extraction.
{
  revPath,
  system ? builtins.currentSystem,
}:

let
  entry = import revPath;

  args = {
    inherit system;
    config = {
      allowAliases = true;
      allowUnfree = true;
      allowBroken = false;
    };
  };

  # nixpkgs only grew an `overlays` argument in 17.03 — 16.09 takes exactly
  # { config, system } — and handing a function an argument it does not declare
  # is a hard error, so the empty list is offered only where it is accepted.
  pkgs =
    if (builtins.functionArgs entry) ? overlays then
      entry (args // { overlays = [ ]; })
    else
      entry args;

  nameOf =
    n:
    let
      attempt = builtins.tryEval (
        let
          drv = pkgs.${n};
        in
        if !(builtins.isAttrs drv) then
          null
        else if !((drv.type or "") == "derivation") then
          null
        else if builtins.isString (drv.name or null) then
          drv.name
        else
          null
      );
    in
    if attempt.success then attempt.value else null;

  names =
    let
      attempt = builtins.tryEval (builtins.attrNames pkgs);
    in
    if attempt.success then attempt.value else [ ];

  pairs = map (n: {
    name = n;
    value = nameOf n;
  }) names;

  # Drop the nulls so the emitted JSON only carries attributes we resolved.
  resolved = builtins.filter (p: p.value != null) pairs;
in
builtins.listToAttrs resolved

# The root attrset nix-eval-jobs walks to get {attr -> output -> store path}
# for a single vendored revision, at one explicit system. Top-level attributes,
# plus the children of the package sets nix/nested-sets.nix lists, keyed the way
# the version index keys them: `jetbrains.idea`.
#
# This is the evaluation half of the inverted join in docs/store-paths.md.
# The channel's
# store-paths listing cannot say which system a path was built for, so it
# cannot turn a derivation name into a digest; an evaluation can, because the
# system is an input to it. The listing keeps its other job — deciding whether
# Hydra built a path at all — as a membership test on the digest this produces.
#
# Mirrors nix/extract-versions.nix in how it enters nixpkgs, and differs from it
# in who does the forcing: that one is a single nix-instantiate over the whole
# attrset, while nix-eval-jobs hands each
# top-level name to a worker that evaluates `root.<name>` by itself. Everything
# expensive therefore has to live inside a value, never in the attrset that
# lists them, or the parent process pays for all of nixpkgs at once.
{
  revPath,
  system ? builtins.currentSystem,
  # When null, walk every top-level attribute. Otherwise a list of names.
  attrs ? null,
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

  # Attribute names to walk. `attrNames` does not force any value, so the
  # parent process gets the whole list for the price of the fixpoint alone.
  names =
    if attrs != null then
      attrs
    else
      let
        attempt = builtins.tryEval (builtins.attrNames pkgs);
      in
      if attempt.success then attempt.value else [ ];

  # The package sets whose children the version index carries, so their store
  # paths have to be resolved too. The same list nix/extract-versions.nix walks:
  # a set indexed there and skipped here would have versions and no digests, and
  # every `fast.*` on it would fall back to an evaluation.
  nestedSets = import ./nested-sets.nix;

  # A value handed to nix-eval-jobs, or an empty attrset when it is not one to
  # report. An empty attrset is neither reported nor recursed into, which is
  # what keeps `haskellPackages` and friends — every one of which sets
  # recurseForDerivations — out of a run that did not ask for them.
  projectDrv = v: if builtins.isAttrs v && (v.type or "") == "derivation" then v else { };

  # Derivations, plus the listed package sets one level deep. The filter runs in
  # the worker that forces the attribute rather than here, so listing the root
  # still costs nothing.
  #
  # A listed set is handed over with its children projected the same way and the
  # marker nix-eval-jobs recurses on, so its workers report them as
  # `<set>.<child>` — exactly the key the version index uses. Projecting the
  # children is what holds the walk to one level: a set inside a listed set
  # becomes an empty attrset rather than another level to descend.
  project =
    n:
    let
      v = pkgs.${n};
    in
    if builtins.isAttrs v && (v.type or "") != "derivation" && builtins.elem n nestedSets then
      builtins.mapAttrs (_: projectDrv) v // { recurseForDerivations = true; }
    else
      projectDrv v;
in
builtins.listToAttrs (
  map (n: {
    name = n;
    value = project n;
  }) names
)

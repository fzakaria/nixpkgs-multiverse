# Tests nix/extract-versions.nix — the per-revision extractor build-index.sh
# drives — against tests/fixtures/fake-rev, a hand-written stand-in for a
# nixpkgs tree:
#
#   nix eval --json -f tests/extract.nix --apply 'f: f { }'
#
# What it checks: that top-level attributes still come out as they always did,
# that the direct children of a listed package set come out as `<set>.<child>`,
# that an unlisted set stays out, and that neither a throwing attribute nor a
# throwing child costs the extraction everything around it.
{
  system ? "x86_64-linux",
}:
let
  extract =
    nestedSets:
    import ../nix/extract-versions.nix {
      inherit system nestedSets;
      revPath = ./fixtures/fake-rev;
    };

  # The extractor as build-index.sh runs it, and the same tree with the
  # allow-list emptied — the difference between the two is exactly what the
  # nested pass contributes.
  withJetbrains = extract [ "jetbrains" ];
  topLevelOnly = extract [ ];

  # A name in the list that the revision does not have. 2016 has no
  # `jetbrains`, and every revision before a set is introduced is that case.
  withMissingSet = extract [
    "jetbrains"
    "setThisRevisionDoesNotHave"
  ];

  committed = import ../nix/nested-sets.nix;
in

# Top-level extraction is unchanged: an explicit `version` is preferred, a
# version parsed out of the derivation name is the fallback, and anything that
# is not a derivation is absent rather than null.
assert topLevelOnly.hello == "2.12.2";
assert topLevelOnly.ripgrep == "14.1.0";
assert !(topLevelOnly ? lib);
assert !(topLevelOnly ? explodingSet);

# An empty list means no nested pass at all, which is the behaviour every
# revision indexed before this feature existed was extracted under.
assert !(builtins.any (n: builtins.match ".*\\..*" n != null) (builtins.attrNames topLevelOnly));

# The children of a listed set are keyed by the path they are reached at.
assert withJetbrains."jetbrains.idea" == "2024.1";
assert withJetbrains."jetbrains.jdk" == "21.0.3";

# One level deep, so a set inside a listed set is neither indexed as a package
# nor recursed into.
assert !(withJetbrains ? "jetbrains.plugins");
assert !(withJetbrains ? "jetbrains.plugins.ideavim");

# `recurseForDerivations` is not what decides this — the list is. An unlisted
# set is invisible however it marks itself.
assert !(withJetbrains ? "pythonPackages.requests");

# A child that throws is dropped, and the rest of its set survives it.
assert !(withJetbrains ? "jetbrains.rider");
assert withJetbrains ? "jetbrains.idea";

# The set marker itself is not a package.
assert !(withJetbrains ? "jetbrains.recurseForDerivations");

# Listing a set the revision does not have is not an error: it contributes
# nothing and everything else still comes out.
assert withMissingSet == withJetbrains;

# The nested pass adds only nested keys — it must not disturb the top-level
# extraction that 1,541 cached revisions were produced under.
assert builtins.intersectAttrs topLevelOnly withJetbrains == topLevelOnly;

# The committed list is a list of strings, and is what ships jetbrains.
assert builtins.isList committed;
assert builtins.all builtins.isString committed;
assert builtins.elem "jetbrains" committed;

{
  topLevel = builtins.length (builtins.attrNames topLevelOnly);
  nested =
    builtins.length (builtins.attrNames withJetbrains)
    - builtins.length (builtins.attrNames topLevelOnly);
  sets = builtins.length committed;
}

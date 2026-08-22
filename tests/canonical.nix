# Tests the canonical-name API — versionsOf, revOf, versions, latest, solve —
# over the groups precomputed into index/versions.json. Structural only: no
# hardcoded versions (they drift as the index is re-cut) and nothing forces a
# value that would fetch a tree. Evaluated strictly, offline, like tests/index.nix:
#
#   nix eval --json -f tests/canonical.nix --apply 'f: f { }'
{
  system ? "x86_64-linux",
}:
let
  mv = import ../multiverse.nix { inherit system; };

  goRaw = builtins.attrNames mv.index.attrs.go; # raw `go` alias versions
  goCanon = mv.versionsOf "go"; # merged canonical view
  sorted = builtins.all (
    i: builtins.compareVersions (builtins.elemAt goCanon i) (builtins.elemAt goCanon (i + 1)) < 0
  ) (builtins.genList (i: i) (builtins.length goCanon - 1));

  # A version the merged view has but the raw `go` alias never did — the case
  # the pre-canonical resolver could not build, since `go` at no revision
  # shipped it. It lives in a sibling (go_1_NN), which the chokepoint resolves.
  siblingOnly = builtins.head (builtins.filter (v: !(mv.index.attrs.go ? ${v})) goCanon);

  # solvePins keys its result by the handle the caller passed, never the
  # resolved sibling — reading only the keys forces no derivation.
  solveKeys = builtins.attrNames (mv.solvePins { go = siblingOnly; });
in
# The generated section exists and covers the seed names.
assert mv.index.canonical ? go && mv.index.canonical ? python;

# Canonical `go` is a strict superset of the raw `go` alias: every alias version
# survives, and at least one exists the alias never had (a late go_1_25 patch).
assert builtins.all (v: builtins.elem v goCanon) goRaw;
assert builtins.length goCanon > builtins.length goRaw;
assert builtins.any (v: !(mv.index.attrs.go ? ${v})) goCanon;
assert sorted;

# versions exposes canonical keys without forcing a fetch. `latest` is
# deliberately the raw attribute, not the canonical group, so it is not asserted
# to carry sibling-only versions — only that it keys the plain attributes.
assert builtins.all (v: mv.versions.go ? ${v}) goCanon;
assert mv.latest ? go && mv.latest ? python;

# fast.versions exposes the same canonical keys, keyed off the eval index.
assert builtins.all (v: mv.fast.versions.go ? ${v}) goCanon;

# The chokepoint: a sibling-only version resolves through every version-selector
# surface — versions (flake attrpath), revOf (label), and the plan/solve path —
# none of which the raw `go` alias could serve.
assert mv.versions.go ? ${siblingOnly};
assert mv.revOf "go" siblingOnly != null;
assert solveKeys == [ "go" ];

# revOf resolves a canonical version to a real revision label, null otherwise.
assert mv.revOf "go" (builtins.head goCanon) != null;
assert mv.revOf "go" "0.0.0-not-a-version" == null;

# python spans both majors in the merged view, disambiguated by version.
assert builtins.any (v: builtins.compareVersions v "3.0" < 0) (mv.versionsOf "python");
assert builtins.any (v: builtins.compareVersions v "3.0" >= 0) (mv.versionsOf "python");

{
  goRaw = builtins.length goRaw;
  goCanon = builtins.length goCanon;
  pythonCanon = builtins.length (mv.versionsOf "python");
  siblingOnly = siblingOnly;
}

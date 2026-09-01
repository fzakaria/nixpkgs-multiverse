# Tests the index-backed query API — versionsOf, revOf, releases, revisions —
# against the committed JSON files, by evaluating this file strictly:
#
#   nix eval --json -f tests/index.nix --apply 'f: f { }'
#
# Nothing here fetches a tree, so the test runs anywhere, offline included.
{
  system ? "x86_64-linux",
}:
let
  mv = import ../multiverse.nix { inherit system; };

  versions = mv.versionsOf "python3";
  count = builtins.length versions;

  # True when every adjacent pair of `versions` ascends under the
  # version-aware comparator, i.e. versionsOf really is sorted.
  sorted = builtins.all (
    i: builtins.compareVersions (builtins.elemAt versions i) (builtins.elemAt versions (i + 1)) < 0
  ) (builtins.genList (i: i) (count - 1));

  # A revision label is a date plus a 12-character commit prefix.
  labelPattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{12}";

  # Nested attribute names: the children of the package sets
  # nix/nested-sets.nix lists, which the extractor walks one level into. Held
  # here rather than in tests/extract.nix because what is under test is the
  # committed index — that the rebuild after a list edit actually happened, and
  # that what it produced has the shape every reader assumes.
  nestedSets = import ../nix/nested-sets.nix;

  # An index key as its path: "hello" is one segment, "jetbrains.idea" is two.
  segmentsOf = attr: builtins.filter builtins.isString (builtins.split "\\." attr);

  indexedNames = builtins.attrNames mv.index.attrs;
  nestedNames = builtins.filter (n: builtins.length (segmentsOf n) > 1) indexedNames;
  parentsOf = names: map (n: builtins.head (segmentsOf n)) names;

  # A representative nested attribute. `jetbrains.idea` has shipped since 2018
  # and is the reason the allow-list exists, so a thin answer here is the index
  # being wrong rather than the package being niche.
  ideaVersions = mv.versionsOf "jetbrains.idea";

  # Not reached through multiverse.nix, which never reads it: stats.json exists
  # for the site's charts. It is still committed data derived from the same
  # revisions, so it is held to the same count.
  stats = builtins.fromJSON (builtins.readFile ../index/stats.json);
in

# python3 predates the start of the index, so a thin result here means the
# index is broken, not that the package is niche.
assert count > 10;
assert sorted;

# revOf answers with a revision label for a version the index knows, and with
# null for one it does not.
assert builtins.match labelPattern (mv.revOf "python3" (builtins.head versions)) != null;
assert mv.revOf "python3" "0.0.0-not-a-version" == null;

# Every listed package set actually reached the index. A name added to
# nix/nested-sets.nix without re-extracting leaves the list and the index
# disagreeing, and every reader would quietly behave as though the set were
# never listed — this is the assertion that says so instead.
assert builtins.all (
  set: builtins.any (n: builtins.head (segmentsOf n) == set) nestedNames
) nestedSets;

# And nothing reached it that was not listed. The extractor walks the list, so
# a nested name from anywhere else means the index was built by something other
# than the extractor beside it.
assert builtins.all (parent: builtins.elem parent nestedSets) (parentsOf nestedNames);

# One level deep, exactly. A three-segment key would mean the walk recursed,
# and every consumer that splits a name into set and child would be wrong.
assert builtins.all (n: builtins.length (segmentsOf n) == 2) nestedNames;

# A nested name is a key of a flat attrset that happens to hold a dot, never a
# level of nesting — the property every quoted installable rests on. The set
# itself carries no version, so it is not a key at all.
assert mv.index.attrs ? "jetbrains.idea";
assert !(mv.index.attrs ? jetbrains);
assert mv.versions ? "jetbrains.idea";
assert !(mv.versions ? jetbrains);
assert mv.latest ? "jetbrains.idea";

# Nested attributes answer the index queries top-level ones do. Neither of
# these forces a derivation: resolving one would fetch a whole nixpkgs.
assert builtins.length ideaVersions > 3;
assert builtins.match labelPattern (mv.revOf "jetbrains.idea" (builtins.head ideaVersions)) != null;

# And the history index carries them too, so lifetimes, `lastSeen` and the
# site's timeline work on a nested name the same way.
assert mv.history.attrs ? "jetbrains.idea";

# Every tracked release appears in the release table.
assert builtins.length mv.releases > 20;
assert builtins.all (r: mv.releaseTips ? ${r}) mv.releases;

# The revision array is date-ordered oldest first, which offsetOnOrBefore
# (and therefore every date selector) depends on.
assert builtins.all (
  i: (builtins.elemAt mv.revisions i).date <= (builtins.elemAt mv.revisions (i + 1)).date
) (builtins.genList (i: i) (builtins.length mv.revisions - 1));

# Every revision is a nixos-unstable channel bump that Hydra published, so
# every revision carries the name the nix-releases archive filed it under. The
# exceptions used to be the 22 release branch-off commits, which were on no
# channel at all and so had no name: they were dropped from the index rather
# than special-cased, because a nameless revision has no store-paths listing,
# and every consumer of `name` -- the store-path fetch, the archive links on
# the site, the build counter in stats -- had to carry a branch for a revision
# that could never answer them.
assert builtins.all (r: r ? name && r.name != "") mv.revisions;

# Every committed file covers exactly the same revisions.
#
# multiverse.nix and mvs both *tolerate* an index that stops short of
# revisions.json, because that is a real intermediate state of a checkout
# between appending a revision and indexing it. Nothing committed is ever
# allowed to be in it: tools/build-index.sh exits non-zero on a partial
# incremental run, which fails the update job before it can commit the pair.
# This is where that stops being a property of the pipeline and starts being a
# property of the repository — the tolerance downstream means a file that falls
# behind produces answers that are merely stale rather than wrong, so nothing
# else would ever fail and say so.
#
# index/stats.json is the one that proved this necessary: nothing rebuilt it for
# a day, and it sat two revisions behind the history it aggregates while every
# other check passed.
assert mv.index.revisionCount == builtins.length mv.revisions;
assert mv.history.revisionCount == builtins.length mv.revisions;
assert stats.revisionCount == builtins.length mv.revisions;

{
  nestedAttrs = builtins.length nestedNames;
  ideaVersions = builtins.length ideaVersions;
  pythonVersions = count;
  releases = builtins.length mv.releases;
  revisions = builtins.length mv.revisions;
}

# Tests mv.installables: the exact-match keys that make revisions addressable
# from a flake attrpath — releases split at the dot (`"25"."05"`), and every
# revision by full commit, 12-character prefix, and label. Exercised by
# evaluation only:
#
#   nix eval --json -f tests/installables.nix --apply 'f: f { }'
#
# The key-shape assertions build attrsets of thunks and fetch nothing; the
# three leaf assertions force one release tree and the tip tree.
{
  system ? "x86_64-linux",
}:
let
  mv = import ../multiverse.nix { inherit system; };
  inst = mv.installables;

  # The newest release the index tracks, split the way the keys are.
  newestRelease = builtins.elemAt mv.releases (builtins.length mv.releases - 1);
  parts = builtins.match "([0-9]+)\\.([0-9]+)" newestRelease;
  major = builtins.elemAt parts 0;
  minor = builtins.elemAt parts 1;

  # Tip is already materialised by the other tests, so its keys make the
  # cheapest revision leaves to force.
  tipRev = mv.tip.multiverse.rev;
  tipLabel = mv.tip.multiverse.label;
in

# Every tracked release appears as major.minor.
assert builtins.all (
  name:
  let
    p = builtins.match "([0-9]+)\\.([0-9]+)" name;
  in
  p != null && inst ? ${builtins.elemAt p 0} && inst.${builtins.elemAt p 0} ? ${builtins.elemAt p 1}
) mv.releases;

# A revision selector resolves to a real nixpkgs rather than to anything keyed
# by the index, which is the one place a name the index spells `jetbrains.idea`
# is genuinely two attributes. Every index-keyed tree — `versions`, `latest`,
# all of `fast` — holds it as a single key instead, and the two spellings are
# not interchangeable in either direction.
assert mv.tip ? jetbrains;
assert mv.tip.jetbrains ? idea;
assert !(mv.tip ? "jetbrains.idea");

# Every revision is addressable by full commit and 12-character prefix...
assert builtins.all (r: inst ? ${r.rev} && inst ? ${builtins.substring 0 12 r.rev}) mv.revisions;

# ...and by label.
assert builtins.all (l: inst ? ${l}) mv.revs;

# One leaf of each key kind forces to a real derivation. `tip` is not an
# installables key — it sits on the API attrset itself — but the README
# documents `#tip.hello`, so it is pinned down here with the others.
assert mv.tip.hello ? drvPath;
assert inst.${major}.${minor}.hello ? drvPath;
assert inst.${tipRev}.hello ? drvPath;
assert inst.${tipLabel}.hello ? drvPath;

{
  release = "${major}.${minor}";
  tip = tipLabel;
  keys = builtins.length (builtins.attrNames inst);
}

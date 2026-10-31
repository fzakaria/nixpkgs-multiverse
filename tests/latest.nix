# Tests which version `latest` and `fast.latest` pick, by evaluating this file
# strictly:
#
#   nix eval --json -f tests/latest.nix --apply 'f: f { }'
#
# `latest` means the version nixpkgs shipped most recently, never the greatest
# version string. The two disagree wherever upstream changed how it numbers
# releases: llama-cpp went from build numbers (10408) to 0.x semver, and
# alacritty from a date (2018-08-30) to 0.17.0. compareVersions ranks the old
# spelling of both above the new one.
#
# Which revision a derivation came from is asked of a stand-in nixpkgs rather
# than a real one: fetchRevision hands back a one-file tree whose every package
# carries the commit it was served for. Nothing here fetches a tree, so the
# test runs anywhere, offline included. The store-path data is the vendored
# fixture tests/fast.nix reads.
{
  system ? "x86_64-linux",
}:
let
  # The attributes the stand-in tree serves. Every name a test below resolves
  # through `latest` has to be listed, or resolveIn throws for it.
  served = [
    "alacritty"
    "hello"
    "llama-cpp"
    "MPlayer"
  ];

  # A nixpkgs whose every package is a plain attrset naming the commit it was
  # served for, carrying the recorded narHash so multiverse's check passes.
  fetchRevision = r: {
    outPath = builtins.toFile "stand-in-nixpkgs.nix" ''
      { system, config ? { }, overlays ? [ ] }:
      let
        drv = { type = "derivation"; servedRev = "${r.rev}"; };
      in
      { ${builtins.concatStringsSep " " (map (n: "${n} = drv;") served)} }
    '';
    lastModified = 0;
    inherit (r) rev narHash;
  };

  fetchArtifact = { name, ... }: ../tests/fixtures/fast-data + "/${name}";

  mv = import ../multiverse.nix { inherit system fetchRevision fetchArtifact; };

  # The commit at an offset into revisions.json, and the newest one the index
  # covers.
  revAt = i: (builtins.elemAt mv.revisions i).rev;
  tipRev = revAt (mv.index.revisionCount - 1);

  # The greatest version string, which is what `latest` used to answer.
  greatestVersionOf =
    attr:
    let
      vers = mv.versionsOf attr;
    in
    builtins.elemAt vers (builtins.length vers - 1);
in

# An attribute still in nixpkgs: the newest version is whatever the tip ships,
# and `latest` resolves at the tip. llama-cpp and alacritty both hold an old
# version string that outranks the current one, and history only grows, so
# that stays true however far either package moves on.
assert mv.latestVersionOf "llama-cpp" == mv.versionAt "llama-cpp" "tip";
assert mv.latestVersionOf "llama-cpp" != greatestVersionOf "llama-cpp";
assert mv.latest.llama-cpp.servedRev == tipRev;
assert mv.latestVersionOf "alacritty" == mv.versionAt "alacritty" "tip";
assert mv.latestVersionOf "alacritty" != greatestVersionOf "alacritty";
assert mv.latest.alacritty.servedRev == tipRev;

# An attribute nixpkgs removed: the last version it shipped, resolved at the
# last revision that shipped it. MPlayer had "34586" and then "1.1" before it
# was renamed away in 2012, and is frozen there for good.
assert mv.latestVersionOf "MPlayer" == "1.1";
assert mv.latest.MPlayer.servedRev == revAt mv.index.attrs.MPlayer."1.1";

# A name the index has never seen has no newest version.
assert mv.latestVersionOf "not-an-attribute" == null;

# fast.latest ranks only the versions that have a store path. The
# fixture holds llama-cpp at 10408 and at 0.2.0, the build-number spelling and
# the first semver release after it, so recency picks 0.2.0 and the version
# string would pick 10408.
assert mv.fast.latest.llama-cpp.version == "0.2.0";

# Where the store-path index has a version the eval index does not, that
# version is still the newest there is to serve. `jetbrains.idea` 2024.1 is
# only in the fixture.
assert mv.fast.latest."jetbrains.idea".version == "2024.1";

{
  llamaCpp = mv.latestVersionOf "llama-cpp";
  alacritty = mv.latestVersionOf "alacritty";
  fastLlamaCpp = mv.fast.latest.llama-cpp.version;
}

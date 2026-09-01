# A stand-in nixpkgs for tests/extract.nix: the smallest tree that exercises
# every branch the extractor has to survive on a real revision.
#
# The "derivations" are plain attrsets carrying `type = "derivation"`, which is
# all extract-versions.nix ever looks at — it reads `version` and `name` and
# never builds anything, so a fixture does not need a store path to be a
# faithful subject.
{
  system,
  config,
  overlays ? [ ],
}:
let
  drv = name: version: {
    type = "derivation";
    inherit name version;
  };
in
{
  # A plain versioned package, and one whose version is only in its name.
  hello = drv "hello-2.12.2" "2.12.2";
  ripgrep = {
    type = "derivation";
    name = "ripgrep-14.1.0";
  };

  # Not a derivation, so it carries no version and must not be indexed.
  lib = {
    fakeLib = true;
  };

  # A listed set: its direct children are indexed as `jetbrains.<child>`.
  jetbrains = {
    recurseForDerivations = true;
    idea = drv "idea-ultimate-2024.1" "2024.1";
    jdk = drv "jetbrains-jdk-21.0.3" "21.0.3";
    # A child that throws when forced. One broken package must not cost us the
    # rest of the set.
    rider = throw "rider is broken at this revision";
    # A nested set inside a listed set. Indexing is one level deep, so this
    # contributes nothing rather than recursing.
    plugins = {
      recurseForDerivations = true;
      ideavim = drv "ideavim-2.0" "2.0";
    };
  };

  # An unlisted set, walked by nothing. This is the whole point of the
  # allow-list: haskellPackages and friends stay out of the index.
  pythonPackages = {
    recurseForDerivations = true;
    requests = drv "python3.13-requests-2.32.3" "2.32.3";
  };

  # A top-level attribute that throws when forced, which every real revision
  # has a few of.
  explodingSet = throw "this attribute does not evaluate";
}

# Tests the two fetcher hooks by pointing each at a fixture and checking that
# what comes back is what the ordinary API resolves through:
#
#   nix eval --json -f tests/mirrors.nix --apply 'f: f { }'
#
# A fetcher returns the fetched thing rather than arguments for fetching it, so
# a fixture path is a complete answer and nothing here touches the network, a
# mirror, or a parallel dry-run path that could drift from the real one.
#
# data-pins.json moves with every data release, so nothing below asserts a
# literal tag or hash — only that the fetcher is handed them.
{
  system ? "x86_64-linux",
}:
let
  plain = import ../multiverse.nix { inherit system; };

  # A fetcher serving tests/fixtures/fetcher-tree in place of nixpkgs, carrying
  # the hash the index recorded so multiverse's check passes.
  honest = import ../multiverse.nix {
    inherit system;
    fetchRevision = r: {
      outPath = ../tests/fixtures/fetcher-tree;
      lastModified = 0;
      inherit (r) rev narHash;
    };
  };

  # The same fetcher, one attribute off: a tree that is not the indexed one.
  liar = import ../multiverse.nix {
    inherit system;
    fetchRevision = r: {
      outPath = ../tests/fixtures/fetcher-tree;
      lastModified = 0;
      inherit (r) rev;
      narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };

  # An artifact fetcher reading a directory it names itself, which is all a
  # local vendor ever needed to be.
  vendored = import ../multiverse.nix {
    inherit system;
    fetchArtifact = { name, ... }: ../tests/fixtures/fast-data + "/${name}";
  };

  # A fetcher that destructures all four arguments with no ellipsis: evaluating
  # it at all is the assertion that each one is passed.
  strict = import ../multiverse.nix {
    inherit system;
    fetchArtifact =
      {
        name,
        tag,
        narHash,
        baseUrl,
      }:
      ../tests/fixtures/fast-data + "/${name}";
  };

  someRev = builtins.elemAt plain.revs (builtins.length plain.revs - 1);
  someRelease = builtins.elemAt plain.releases (builtins.length plain.releases - 1);
  releases = builtins.fromJSON (builtins.readFile ../releases.json);
  dataPins = builtins.fromJSON (builtins.readFile ../data-pins.json);
  artifact = "outpaths-${system}.json";

  mvLib = import ../nix/lib.nix;
in

# --- fetchRevision: a selector resolves through the fetcher's tree -----------
#
# The proof that the fetcher was used, rather than GitHub: the attribute below
# exists only in the fixture.
assert (honest.at someRev).servedByTheFetcher;
assert (honest.at someRev).system == system;

# --- fetchRevision: provenance still describes the revision, not the tree ----
#
# The fetcher decides where the bytes come from; it does not get to rename the
# revision they stand for.
assert (honest.at someRev).multiverse.label == someRev;

# --- fetchRevision: the recorded narHash is checked, not merely requested ----
#
# A fetcher returning the tree itself never calls fetchTree, so nothing but
# multiverse's own check stands between a wrong tree and derivations no digest
# in the store-path index describes. `liar` differs only in that hash.
assert !(builtins.tryEval (liar.at someRev).servedByTheFetcher).success;

# --- every release tip carries a narHash, so treeFor covers releases too -----
#
# The field is not optional. fetch-releases.sh records it for a tip that moved
# and carries it forward for one that did not, so a release resolves through
# the same checked path an indexed revision does — no second road, and `at
# "26.05"` verified exactly as `at "2026-08-19"` is.
assert builtins.all (r: releases.${r} ? narHash) (builtins.attrNames releases);
assert (honest.at someRelease).servedByTheFetcher;
assert !(builtins.tryEval (liar.at someRelease).servedByTheFetcher).success;

# --- fetchArtifact: the fast path reads what the fetcher returned ------------
#
# The fixture digests are the ones tests/fast.nix uses, so a hit here means the
# whole fast path was served by a fetcher that fetched nothing at all.
assert vendored.fast.versions.hello."2.12.2".name == "hello-2.12.2";
assert
  vendored.fast.versions.ffmpeg."9.0".outputs == [
    "out"
    "lib"
  ];

# --- fetchArtifact: the fetcher is handed the pin, not a URL -----------------
#
# `strict` names name, tag, narHash and baseUrl with no ellipsis, so resolving
# anything through it fails unless all four arrive.
assert strict.fast.versions.hello."2.12.2".name == "hello-2.12.2";

# --- both fetchers reach the entry points a configuration actually uses ------
assert builtins.functionArgs mvLib.readLock ? fetchRevision;
assert builtins.functionArgs mvLib.readLock ? fetchArtifact;
assert builtins.functionArgs mvLib.pinOverlay ? fetchRevision;
assert builtins.functionArgs mvLib.pinOverlay ? fetchArtifact;

{
  inherit system;
  treeFromFetcher = (honest.at someRev).servedByTheFetcher;
  fastFromFetcher = vendored.fast.versions.hello."2.12.2".name;
}

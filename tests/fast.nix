# Tests the fast fake-derivation path against a vendored fixture, by
# evaluating this file strictly:
#
#   nix eval --json -f tests/fast.nix --apply 'f: f { }'
#
# fetchArtifact reads tests/fixtures/fast-data, so nothing here fetches
# the pinned release assets — the test runs anywhere, offline included, and
# keeps running unchanged as the real pins move.
#
# The fixture supplies digests only. Which revision `tip` names, and which
# version each attribute has there, still come from the checkout's own
# revisions.json and index/history.json — that is the whole point of `tip`
# being a selector. So the tip fixture must carry a digest for whatever
# version of `hello` the newest indexed revision ships; when nixpkgs bumps
# hello, add the new pair to every
# tests/fixtures/fast-data/tip-outpaths-<system>.json.
#
# The fixture holds one set of files per system it covers — x86_64-linux,
# aarch64-linux and aarch64-darwin, with distinct digests so a test cannot pass
# by reading the wrong one — which is what lets this suite run unchanged on any
# of them. A system it does not cover must throw rather than be handed a
# neighbour's digests, and riscv64-linux is the fixture for that.
#
# No assertion forces an outPath (or any sibling output) on purpose: current
# Nix realises `path = true` string context the moment the string is forced,
# which would ask the store to substitute the fixture's made-up digests. The
# path mechanics have a live smoke test instead:
#
#   nix shell .#fast.versions.hello."2.12.2".out -c hello
{
  system ? "x86_64-linux",
}:
let
  mv = import ../multiverse.nix {
    inherit system;
    fetchArtifact = { name, ... }: ../tests/fixtures/fast-data + "/${name}";
  };

  # A fixture entry under a nested index name — a child of a package set
  # nix/nested-sets.nix lists. Only the fixture carries it, since the committed
  # index has no nested attributes until it is re-extracted, so it is reachable
  # through `fast.latest`, which unions the store-path index's keys in, and not
  # through `fast.versions`, which is keyed by the eval index alone.
  #
  # What this pins down is that a dotted name is one key holding a dot rather
  # than two levels of attrset — the distinction every fast selector rests on.
  nestedFake = mv.fast.latest."jetbrains.idea";
  nestedKeyed = nestedFake.name == "idea-2024.1" && nestedFake.version == "2024.1";

  # `fast.latest` is a flat attrset, so the dotted name is a key of it and the
  # set has no `jetbrains` of its own to descend into.
  nestedFlat = !(mv.fast.latest ? jetbrains);

  # A fake under a nested name is a fake like any other: no drvPath, and the
  # outputs it does have hang off it directly.
  nestedDrvPathThrows = !(builtins.tryEval nestedFake.drvPath).success;

  # The importer knob under test: unmatched pairs fall back to the real
  # derivation instead of throwing.
  mvEval = import ../multiverse.nix {
    inherit system;
    fetchArtifact = { name, ... }: ../tests/fixtures/fast-data + "/${name}";
    fastFallback = "eval";
  };

  # Two copies of the base fixture, each with one number changed: the
  # revision count one artifact claims to have been built against, set past
  # the end of revisions.json. One artifact per copy, so a guard wired to
  # only one of the two files still fails this.
  mvTipAhead = import ../multiverse.nix {
    inherit system;
    fetchArtifact = { name, ... }: ../tests/fixtures/fast-data-tip-ahead + "/${name}";
  };
  mvClosedAhead = import ../multiverse.nix {
    inherit system;
    fetchArtifact = { name, ... }: ../tests/fixtures/fast-data-closed-ahead + "/${name}";
  };

  # A system the fixture has no artifacts for. Issue #12 was fast handing an
  # x86_64-linux user aarch64 binaries; the shape of the fix is that a system
  # is served from its own file or not at all.
  mvForeign = import ../multiverse.nix {
    system = "riscv64-linux";
    fetchArtifact = { name, ... }: ../tests/fixtures/fast-data + "/${name}";
  };

  hello = mv.fast.version "hello" "2.12.2";
  ffmpeg = mv.fast.version "ffmpeg" "9.0";
  tipHello = mv.fast.tip.hello;

  # tryEval only catches `throw`, and only when the throw is what the forced
  # value IS, so each probe forces exactly the attribute whose failure it
  # asserts.
  missThrows = !(builtins.tryEval (mv.fast.version "hello" "0.0.0-nope")).success;
  releaseRefuses = !(builtins.tryEval (mv.fast.at "25.05")).success;
  drvPathThrows = !(builtins.tryEval hello.drvPath).success;

  # With fastFallback = "eval" a matched pair must still come back fake; the
  # fake is recognisable by its throwing drvPath.
  fallbackHello = mvEval.fast.version "hello" "2.12.2";

  # An attribute the store-path index never saw at any version. Hydra
  # evaluates nixpkgs with allowUnfree = false, so vscode has no path to
  # record and the fixture has no entry for it either. The tree is keyed by
  # the eval index regardless, so the miss arrives as the module's own throw
  # naming the eval selector, rather than as a bare missing attribute from
  # Nix that no fallback could ever intercept.
  unfreeKeyed = mv.fast.versions ? vscode;
  unfreeThrows = !(builtins.tryEval mv.fast.versions.vscode."1.107.0").success;

  # `latest` gets the same key for the same reason, but by union rather than
  # by swap: an attribute the store-path index does know must keep choosing
  # its newest *matched* version, since that is the only one fast can serve.
  unfreeLatestKeyed = mv.fast.latest ? vscode;
  unfreeLatestThrows = !(builtins.tryEval mv.fast.latest.vscode).success;

  # `tip` is a selector, not a snapshot: the same revision `at "tip"` names,
  # resolved the same way. Asserted as a key-set identity, because the two
  # spellings once disagreed — `tip` keyed off tip-outpaths.json while
  # `at "tip"` keyed off the history — and that is the shape the regression
  # would take again.
  tipKeys = builtins.attrNames mv.fast.tip;
  atTipKeys = builtins.attrNames (mv.fast.at "tip");

  # The consequence of that key set for an attribute the store-path data has
  # never covered: it is addressable under `tip` exactly as it is under
  # `versions` and `latest`, so the miss arrives as the module's own throw
  # naming the eval selector, rather than as a bare missing attribute Nix
  # raises before any fallback could intercept it.
  tipUnfreeKeyed = mv.fast.tip ? vscode;
  tipUnfreeThrows = !(builtins.tryEval mv.fast.tip.vscode).success;

  # An artifact claiming more revisions than revisions.json holds is refused,
  # the way index/versions.json and index/history.json already are. Each probe
  # asks for a pair its own fixture covers, so the only thing that can fail
  # the lookup is the guard.
  tipAheadRefused = !(builtins.tryEval (mvTipAhead.fast.version "hello" "2.12.3")).success;
  closedAheadRefused = !(builtins.tryEval (mvClosedAhead.fast.version "hello" "2.12.2")).success;

  # The pair the fixture covers for x86_64-linux, asked for as another system:
  # the answer is a throw, not the x86_64 digest.
  foreignSystemRefused = !(builtins.tryEval (mvForeign.fast.version "hello" "2.12.2")).success;
in

# A fake walks and quacks like a derivation.
assert hello.type == "derivation";
assert hello.name == "hello-2.12.2";
assert hello.pname == "hello" && hello.version == "2.12.2";
assert hello.system == system;
assert hello.outputs == [ "out" ];

# The entry's recorded drv name wins over attr-version, and the sibling
# outputs from outs-<system>.json — keyed there by ffmpeg's own digest —
# surface in the outputs list, with the stray "out" suffix dropped rather than
# shadowing the default output.
assert ffmpeg.name == "ffmpeg-9.0";
assert
  ffmpeg.outputs == [
    "out"
    "lib"
  ];
assert ffmpeg ? lib;

# `tip` serves the version its revision ships, read off the history index —
# not whatever the store-path snapshot happened to hold when the pin was cut.
# Those two answers diverge for a whole UTC day every time a second channel
# bump lands before the next dated data release is cut.
assert tipHello.version == mv.versionAt "hello" "tip";

# The two spellings of the same revision agree on every key, and an
# attribute with no store path is one of those keys.
assert tipKeys == atTipKeys;
assert tipUnfreeKeyed;
assert tipUnfreeThrows;

# A pin that disagrees with revisions.json about the length of history is
# refused rather than read, for both store-path artifacts.
assert tipAheadRefused;
assert closedAheadRefused;

# A store path belongs to one system. Asking as another one gets nothing,
# which is the whole of issue #12.
assert foreignSystemRefused;

# Every fake carries the lazy escape hatch to the real derivation. Only its
# presence is asserted: forcing it would fetch a whole nixpkgs revision.
assert hello ? eval;

# The honesty contract: misses throw, releases refuse, drvPath says why.
assert missThrows;
assert releaseRefuses;
assert drvPathThrows;

# fastFallback changes what happens to misses, not to hits.
assert fallbackHello.name == hello.name;
assert !(builtins.tryEval fallbackHello.drvPath).success;

# An attribute with no store path at any version is still addressable, and
# still throws. The fallback half of this is not asserted: forcing it under
# fastFallback = "eval" is the eval path, which fetches a whole nixpkgs
# revision — the same reason `hello ? eval` above stops at presence.
assert unfreeKeyed;
assert unfreeThrows;
assert unfreeLatestKeyed;
assert unfreeLatestThrows;

# A nested index name — a child of a package set nix/nested-sets.nix lists — is
# one flat key of the index holding a dot, not two levels of it. Every fast
# selector is keyed that way, and the selector a fake suggests has to be
# spelled so it parses: `nix build` splits an attribute path on unquoted dots,
# so the attribute needs quoting exactly the way the version already does.
assert nestedKeyed;
assert nestedFlat;
assert nestedDrvPathThrows;

# The union must not disturb the attributes the store-path index does cover:
# `latest` still means the newest version with a path, which for an attribute
# whose newer versions Hydra never built is older than the newest known.
assert mv.fast.latest.hello.version == "2.12.3";
assert mv.fast.latest.ffmpeg.version == "9.0";

{
  helloName = hello.name;
  ffmpegOutputs = ffmpeg.outputs;
  tipHelloVersion = tipHello.version;
}

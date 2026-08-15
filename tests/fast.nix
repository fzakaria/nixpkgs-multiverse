# Tests the fast fake-derivation path against a vendored fixture, by
# evaluating this file strictly:
#
#   nix eval --json -f tests/fast.nix --apply 'f: f { }'
#
# dataOverride points at tests/fixtures/fast-data, so nothing here fetches
# the pinned release assets — the test runs anywhere, offline included, and
# keeps running unchanged as the real pins move.
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
    dataOverride = ../tests/fixtures/fast-data;
  };

  # The importer knob under test: unmatched pairs fall back to the real
  # derivation instead of throwing.
  mvEval = import ../multiverse.nix {
    inherit system;
    dataOverride = ../tests/fixtures/fast-data;
    fastFallback = "eval";
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
in

# A fake walks and quacks like a derivation.
assert hello.type == "derivation";
assert hello.name == "hello-2.12.2";
assert hello.pname == "hello" && hello.version == "2.12.2";
assert hello.system == "x86_64-linux";
assert hello.outputs == [ "out" ];

# The entry's recorded drv name wins over attr-version, and the sibling
# outputs from outs.json surface in the outputs list — with the stray "out"
# suffix dropped rather than shadowing the default output.
assert ffmpeg.name == "ffmpeg-9.0";
assert
  ffmpeg.outputs == [
    "out"
    "lib"
  ];
assert ffmpeg ? lib;

# The tip snapshot serves what was current when the pin was cut.
assert tipHello.version == "2.12.3";

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

{
  helloName = hello.name;
  ffmpegOutputs = ffmpeg.outputs;
  tipHelloVersion = tipHello.version;
}

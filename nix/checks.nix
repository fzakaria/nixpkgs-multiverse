# `nix flake check` runs the test suite.
#
# The eval tests return a small summary attrset only after their assertions
# hold, so serialising the summary into a derivation makes *evaluation* the test
# — the build step just writes it out. compose is a real build: three Pythons
# from three revisions in one buildEnv.
{ pkgs, system }:
let
  evalTest =
    name: file:
    pkgs.runCommand name {
      summary = builtins.toJSON (import file { inherit system; });
    } ''echo "$summary" > $out'';
in
{
  index = evalTest "test-index" ../tests/index.nix;
  flake-at = evalTest "test-flake-at" ../tests/flake-at.nix;
  installables = evalTest "test-installables" ../tests/installables.nix;
  module = evalTest "test-module" ../tests/module.nix;
  history = evalTest "test-history" ../tests/history.nix;
  lock = evalTest "test-lock" ../tests/lock.nix;
  minimize = evalTest "test-minimize" ../tests/minimize.nix;
  fast = evalTest "test-fast" ../tests/fast.nix;
  mirrors = evalTest "test-mirrors" ../tests/mirrors.nix;
  compose = (import ../tests/compose.nix { inherit system; }).env;

  # That a fetched artifact survives Nix' reference scan. Real data never
  # collides against the release pin every other check builds on — which is how
  # the overlay shipped broken — so the collision is constructed: a file holding
  # the bare hash part of a path in the fetch's own input closure. The
  # assertions carry the check, because a fixed-output path is decided by name
  # and hash alone: once built, a dropped discard would not rebuild. Regenerate
  # the hash with `nix hash path` if the probe strings change.
  data-refs =
    let
      dep = builtins.toFile "refscan-dep" "multiverse reference-scan probe\n";
      # The reference rides the string context, which is what puts `dep` into
      # the fetch's input closure for the scanner to find.
      depHash = builtins.substring 0 32 (baseNameOf dep);
      collide = builtins.toFile "refscan-collide.json" ''{"refscan-dep":{"1":["${depHash}"]}}'';
      artifact = import ./fetch-artifact.nix { inherit pkgs; } {
        url = "file://${collide}";
        hash = "sha256-d6l6GfTP+VS5xZN39E4duj3ZwktbCI+eY/WnbOXYo04=";
      };
    in
    assert artifact.__structuredAttrs;
    assert artifact.unsafeDiscardReferences.out;
    artifact;

  # Every in-repository markdown link, against the headings that actually exist.
  # Both renderers — GitHub and tools/render-docs.py — derive anchors from
  # heading text, so renaming a heading breaks links in both and neither says
  # so: the browser just scrolls to the top. The tree is reassembled here
  # because the checker resolves `../` links relative to the file holding them.
  docs-links = pkgs.runCommand "check-docs-links" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p repo/docs repo/.github/workflows
    cp ${../README.md} repo/README.md
    cp ${../LICENSE} repo/LICENSE
    cp ${../multiverse_lotr.jpg} repo/multiverse_lotr.jpg
    cp ${../docs}/*.md ${../docs}/*.svg repo/docs/
    cp ${../.github/workflows}/*.yml repo/.github/workflows/
    cd repo
    python3 ${../tools/check-links.py} README.md docs/*.md | tee $out
  '';

  # The browser suite over the built site. Everything else here is a pure build;
  # this one is not, and cannot be: the page imports Preact from jsdelivr at run
  # time, so a sandboxed build has no way to render it at all. __noChroot is what
  # buys the network.
  #
  # That requires `sandbox = relaxed` in nix.conf. Without it the check fails
  # immediately — "derivation has '__noChroot' set, but that's not allowed when
  # 'sandbox' is 'true'" — and the ways around it are
  #   nix flake check --option sandbox relaxed
  # or `nix.settings.sandbox = "relaxed"` on the host. ci.yml passes the option;
  # `nix run .#test-site` needs none of it.
  #
  # `relaxed` unsandboxes only derivations that ask for it by name, so every
  # other check here still builds exactly as before.
  #
  # Impure, but cached against its inputs like any other derivation: it reruns
  # when the site or the specs change, not on every check.
  site =
    pkgs.runCommand "check-site"
      {
        __noChroot = true;
        nativeBuildInputs = [ pkgs.multiverse-site-tests ];
      }
      ''
        test-site 2>&1 | tee $out
      '';
}

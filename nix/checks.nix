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
  extract = evalTest "test-extract" ../tests/extract.nix;
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
  # The mini-repo carries everything a document can name, not just the prose:
  # the code, because a link into the tree is exactly the kind that rots —
  # docs/nix-api.md points at nix/nested-sets.nix, and a reader following that
  # after the file moved is worse off than one never offered the link — and the
  # data files, which docs/design.md links to so a reader can go and look at the
  # shapes it describes. Those cost a rebuild whenever the index moves, which is
  # a second, and buys the same guarantee for the same reason.
  docs-links = pkgs.runCommand "check-docs-links" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p repo/docs repo/.github/workflows repo/nix repo/tools repo/index
    cp ${../README.md} repo/README.md
    cp ${../LICENSE} repo/LICENSE
    cp ${../multiverse_lotr.jpg} repo/multiverse_lotr.jpg
    cp ${../docs}/*.md ${../docs}/*.svg repo/docs/
    cp ${../.github/workflows}/*.yml repo/.github/workflows/
    cp ${../nix}/*.nix repo/nix/
    cp ${../tools}/*.sh ${../tools}/*.py repo/tools/
    cp ${../revisions.json} repo/revisions.json
    cp ${../releases.json} repo/releases.json
    cp ${../data-pins.json} repo/data-pins.json
    cp ${../index}/*.json repo/index/
    cd repo
    python3 ${../tools/check-links.py} README.md docs/*.md | tee $out
  '';

  # tools/merge-nested-eval.py, the one piece of --topup that decides what ends
  # up in the file the join reads. Its inputs are two small JSON documents, so
  # the whole thing is testable without evaluating a revision — which is the
  # reason to have the merge in a script of its own rather than inline in the
  # shell.
  topup-merge = pkgs.runCommand "check-topup-merge" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p work && cd work

    # A full evaluation carrying one stale nested row, as a revision indexed
    # under an older package-set list would.
    cat > base.json <<'JSON'
    {"rev":"abc","system":"x86_64-linux","attrCount":3,"errorCount":1,
     "attrs":{"hello":{"name":"hello-2.12.2","outputs":{"out":"aaaa"}},
              "ripgrep":{"name":"ripgrep-14.1.0","outputs":{"out":"bbbb"}},
              "gone.child":{"name":"gone-1.0","outputs":{"out":"cccc"}}}}
    JSON
    cat > base.errors.json <<'JSON'
    {"broken":"error: no","gone.child2":"error: stale"}
    JSON
    cat > nested.json <<'JSON'
    {"rev":"abc","system":"x86_64-linux","attrCount":1,"errorCount":1,
     "attrs":{"jetbrains.idea":{"name":"idea-2025.3.1","outputs":{"out":"dddd"}}}}
    JSON
    cat > nested.errors.json <<'JSON'
    {"jetbrains.rider":"error: unfree"}
    JSON

    python3 ${../tools/merge-nested-eval.py} --base base.json --nested nested.json       --out merged.json --base-errors base.errors.json       --nested-errors nested.errors.json --out-errors merged.errors.json

    # A base built for another revision, and a nested run that reported a
    # top-level attribute: both would corrupt the merged file, so both have to
    # be refused rather than merged.
    sed 's/"rev":"abc"/"rev":"zzz"/' nested.json > wrong-rev.json
    sed 's/jetbrains.idea/hello/' nested.json > stray.json
    for bad in wrong-rev stray; do
      if python3 ${../tools/merge-nested-eval.py} --base base.json            --nested $bad.json --out /dev/null 2>/dev/null; then
        echo "merge accepted $bad.json, which it must refuse" >&2
        exit 1
      fi
    done

    python3 - <<'PY' | tee $out
    import json
    m = json.load(open("merged.json"))
    errors = json.load(open("merged.errors.json"))

    # Top-level rows carry across untouched — the whole point, since deriving
    # them again is what costs the 52 seconds.
    assert m["attrs"]["hello"]["outputs"]["out"] == "aaaa", m
    assert m["attrs"]["ripgrep"]["outputs"]["out"] == "bbbb", m

    # The new list's rows arrive.
    assert m["attrs"]["jetbrains.idea"]["outputs"]["out"] == "dddd", m

    # And a row from a set no longer on the list is gone, which is why this
    # replaces the nested half rather than appending to it.
    assert "gone.child" not in m["attrs"], m
    assert "gone.child2" not in errors, errors

    assert m["attrCount"] == 3, m
    assert m["rev"] == "abc" and m["system"] == "x86_64-linux", m
    assert errors == {"broken": "error: no", "jetbrains.rider": "error: unfree"}, errors
    assert m["errorCount"] == 2, m
    print(f"merged {m['attrCount']} attrs, {m['errorCount']} errors")
    PY
  '';

  # The retry in tools/fetch-store-paths.py, with the transport stubbed — see
  # tests/fetch-retry.py for what the policy is and why it is worth pinning.
  # The script is passed by store path rather than found relative to the test,
  # since under `nix build` the two arrive as separate store paths.
  fetch-retry = pkgs.runCommand "check-fetch-retry" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${../tests/fetch-retry.py} ${../tools/fetch-store-paths.py} | tee $out
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

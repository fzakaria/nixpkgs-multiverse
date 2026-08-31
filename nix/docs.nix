# docs/*.md rendered to /docs/*.html. The same markdown is what GitHub shows in
# the repository, so the two never disagree.
{ pkgs }:
let
  inherit (import ./site-origin.nix) siteOrigin;
in
pkgs.runCommand "nixpkgs-multiverse-docs"
  {
    nativeBuildInputs = [
      # pygments highlights the docs' code blocks at build time, which is what
      # keeps a highlighter and its CDN out of the pages themselves. The other
      # scripts here need plain python3, and one interpreter serves both.
      (pkgs.python3.withPackages (ps: [ ps.pygments ]))
      pkgs.cmark-gfm
    ];
  }
  ''
    mkdir -p $out
    python3 ${../tools/render-docs.py} \
      ${pkgs.cmark-gfm}/bin/cmark-gfm ${../docs} $out \
      ${siteOrigin} "__STORE_PATH__"
  ''

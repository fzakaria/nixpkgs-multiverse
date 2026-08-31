# The deployable site: the static files from site/ plus the data products
# site-data.nix builds.
#
# The data is copied in rather than fetched from raw.githubusercontent.com so
# that versions.json and revisions.json always deploy atomically — the offsets in
# one are only valid against the other.
{ pkgs, self }:
pkgs.runCommand "nixpkgs-multiverse-site" { } ''
  mkdir -p $out
  cp -r ${pkgs.multiverse-site-data}/* $out/
  chmod -R u+w $out
  # -r because the page is a tree of ES modules under js/, not one script file.
  cp -r ${../site}/* $out/
  chmod -R u+w $out

  # The output path is known before building, so the page can name the very
  # store path it is served out of (a benign self-reference).
  substituteInPlace $out/js/app.js --replace-fail "__STORE_PATH__" "$out"
  if [ -d $out/docs ]; then
    for f in $out/docs/*.html; do
      substituteInPlace "$f" --replace-fail "__STORE_PATH__" "$out"
    done
  fi

  # The whole module tree is hashed as one unit and the directory renamed
  # js.<hash>, which is the multi-file form of the old app.<hash>.js: the served
  # HTML and every module it pulls in can never be a mismatched pair across
  # deploys, and the tree could be cached immutably. Hashing runs after the
  # substitutions above, so the name covers exactly the bytes served. Modules
  # import each other by relative path, so renaming the directory breaks nothing.
  hash=$(find $out/js -type f -name '*.js' | LC_ALL=C sort |
    xargs sha256sum | sha256sum | cut -c1-12)
  mv $out/js "$out/js.$hash"
  substituteInPlace $out/index.html --replace-fail "./js/app.js" "./js.$hash/app.js"
''

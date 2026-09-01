# Extracts {attrname -> version} for a single vendored revision.
#
# Called once per revision by tools/build-index.sh. Kept deliberately total:
# any attribute that fails to evaluate (broken package, unfree assertion,
# platform mismatch) yields null rather than aborting the whole extraction,
# because a 2023 revision evaluated on a 2026 Nix will always have some
# casualties and one of them must not cost us the other 100k attributes.
{
  revPath,
  system ? builtins.currentSystem,
  # When null, extract every top-level attribute. Otherwise a list of names.
  attrs ? null,
  # Package sets to walk one level into, indexed as `<set>.<child>`. Read from
  # the committed list by default; tests pass their own. build-index.sh folds
  # the same file into EXTRACTOR_HASH, so adding a name re-extracts every
  # revision rather than leaving half the cache built under the old list.
  nestedSets ? import ./nested-sets.nix,
}:

let
  entry = import revPath;

  args = {
    inherit system;
    config = {
      allowAliases = true;
      allowUnfree = true;
      allowBroken = false;
    };
  };

  # nixpkgs only grew an `overlays` argument in 17.03 — 16.09 takes exactly
  # { config, system } — and handing a function an argument it does not declare
  # is a hard error, so the empty list is offered only where it is accepted.
  # Without this every pre-17.03 revision fails extraction outright.
  pkgs =
    if (builtins.functionArgs entry) ? overlays then
      entry (args // { overlays = [ ]; })
    else
      entry args;

  # Version of an already-forced value, or null if it cannot be determined.
  # Prefers the explicit `version` attribute and falls back to parsing the
  # derivation name, which is all the older revisions expose for some packages.
  # A value that is not a derivation — a package set, `lib`, a plain string —
  # has no version, and that is how nested sets stay out of their own listing.
  versionOfValue =
    drv:
    let
      parsed = (builtins.parseDrvName (drv.name or "")).version;
    in
    if !(builtins.isAttrs drv) then
      null
    else if !(drv.type or "" == "derivation") then
      null
    else if drv ? version && builtins.isString drv.version then
      drv.version
    else if parsed != "" then
      parsed
    else
      null;

  # Version of one attribute of `set`, or null if forcing it throws. This is
  # the totality the whole extractor rests on: a broken package yields null and
  # its neighbours are extracted anyway.
  versionIn =
    set: name:
    let
      attempt = builtins.tryEval (versionOfValue set.${name});
    in
    if attempt.success then attempt.value else null;

  # Attribute names to walk. Guard the readDir-free `attrNames` behind tryEval
  # too, since forcing the top-level attrset can itself fail on old revisions.
  names =
    if attrs != null then
      attrs
    else
      let
        attempt = builtins.tryEval (builtins.attrNames pkgs);
      in
      if attempt.success then attempt.value else [ ];

  present = builtins.filter (n: builtins.hasAttr n pkgs) names;

  pairs = map (n: {
    name = n;
    value = versionIn pkgs n;
  }) present;

  # The direct children of one listed set, keyed by the path they are reached
  # at. Forcing the set is guarded on its own: a set that throws contributes
  # nothing, which is the same answer as a revision that does not have it.
  childrenOf =
    setName:
    let
      attempt = builtins.tryEval (
        let
          set = pkgs.${setName};
        in
        if !(builtins.isAttrs set) then
          [ ]
        else
          map (child: {
            name = "${setName}.${child}";
            value = versionIn set child;
          }) (builtins.attrNames set)
      );
    in
    if attempt.success then attempt.value else [ ];

  # One level deep, over the sets this revision actually has. A name listed
  # before nixpkgs introduced it — or after it dropped it — is not an error:
  # every revision older than `jetbrains` is that case.
  nested =
    let
      attempt = builtins.tryEval (builtins.filter (n: builtins.hasAttr n pkgs) nestedSets);
    in
    if attempt.success then builtins.concatMap childrenOf attempt.value else [ ];

  # Drop the nulls so the emitted JSON only carries attributes we resolved.
  resolved = builtins.filter (p: p.value != null) (pairs ++ nested);
in
builtins.listToAttrs resolved

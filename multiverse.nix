# A nixpkgs multiverse: every indexed revision reachable from a single evaluation.
#
# Revisions are *fetched*, not vendored. A revision fetched into the store
# yields byte-identical derivations to a checked-out tree — store paths derive
# from content and basename, never from location — so everything
# Hydra built stays a cache hit while the repo itself holds only an index.
#
# Two properties shape this file:
#
#   1. The version axis must never become top-level attributes. Nix parses a
#      file in full before it can look anything up in it, so a flat attrset of
#      every (package, version) pair would be paid for by every evaluation,
#      including ones that touch nothing.
#
#   2. Cost is per *revision touched*, not per package. Revisions are memoised
#      below so that asking for five packages out of one revision instantiates
#      it exactly once. Revisions nobody asks for are never fetched at all.
{
  system ? builtins.currentSystem,
  config ? { },
  overlays ? [ ],
  # What `fast.*` does for a version the store-path index has no digest for.
  #   "throw" — fail loudly, naming the eval selector to use. The default:
  #             nothing called fast should quietly start a ~378 MB fetch.
  #   "eval"  — fall back to the real derivation transparently. For scripts
  #             that want coverage over predictability.
  fastFallback ? "throw",
  # How one nixpkgs revision becomes a tree, given the record naming it: a
  # revisions.json entry ({ rev, date, name, narHash }) or a releases.json one,
  # which carries no narHash. Return a `builtins.fetchTree` result — `flakeAt`
  # hands it out as flake sourceInfo, so outPath, rev, narHash and lastModified
  # all have to be there.
  #
  # A mirror may fetch however it likes; multiverse checks the narHash of what
  # comes back against the one the index recorded, because the index records
  # digests for the trees those hashes name.
  fetchRevision ?
    r:
    builtins.fetchTree (
      {
        type = "github";
        owner = "NixOS";
        repo = "nixpkgs";
        inherit (r) rev;
      }
      // (if r ? narHash then { inherit (r) narHash; } else { })
    ),
  # How one pinned data artifact becomes a readable path, given its file name,
  # the data-pins.json entry for it ({ tag, narHash }) and that file's baseUrl.
  #
  # Returning a path rather than fetch arguments is what lets a fetcher pull a
  # whole tree and index into it — one git ref holding every artifact, say — or
  # hand back a local file and fetch nothing. Verification is the fetcher's
  # from here: these are JSON this evaluation parses, not trees that have to
  # match what Hydra built.
  fetchArtifact ?
    {
      name,
      tag,
      narHash,
      baseUrl,
    }:
    (builtins.fetchTree {
      type = "file";
      url = "${baseUrl}/${tag}/${name}";
      inherit narHash;
    }).outPath,
}:

let
  # One ordered array of every known revision, oldest first: every entry is a
  # nixos-unstable channel bump. Append-only and immutable, because
  # index/versions.json addresses it by offset — see checkedIndex below.
  revisions = builtins.fromJSON (builtins.readFile ./revisions.json);

  # { "26.05" = { rev, date, build, name }; ... } — the current tip of each
  # release channel, which is a different kind of thing entirely.
  #
  # A release moves. Backports land on release-26.05 for the whole life of the
  # release, and `at "26.05"` follows them, exactly as
  # github:NixOS/nixpkgs/nixos-26.05 does. That is why these are not entries in
  # revisions.json: an offset there must mean the same tree forever, or every
  # version the index recorded against it becomes a claim about a tree that has
  # moved on. Nothing here is ever indexed, so nothing here can go stale.
  releaseTable = builtins.fromJSON (builtins.readFile ./releases.json);

  # { revisionCount, attrs = { attr = { version = <offset into revisions>; }; } }
  #
  # An offset of `null` means the newest revision the file covers, which is
  # revisionCount - 1. Writing that offset out literally would move it on every
  # version still current whenever a revision is appended, rewriting most of the
  # file to say nothing changed; see docs/design.md. `versionsFor` resolves it,
  # and nothing above that sees a null.
  #
  # Only the NEWEST revision shipping each version is recorded. Keeping the full
  # list is what makes an index grow with revision count rather than with
  # content: a package that never changes version would otherwise accumulate one
  # entry per revision — ~47 KB for a single version of a single package at this
  # scale, and ~103 MB across the index. Newest-only projects to ~5.4 MB for the
  # same coverage.
  #
  # Newest is also the build-correct choice: the most patched build, and the one
  # Hydra produced most recently, so the most likely to still substitute.
  # "Which revisions *also* had this version" is a history question — it belongs
  # in tooling built from index/.per-rev, not in a file parsed on every eval.
  index = builtins.fromJSON (builtins.readFile ./index/versions.json);

  nRevs = builtins.length revisions;
  offsets = builtins.genList (i: i) nRevs;
  revAt = i: builtins.elemAt revisions i;

  # The index stores bare offsets, so it is only valid against the revision list
  # it was built from. Appending revisions is safe; reordering is not, and this
  # catches that rather than silently resolving to the wrong commit.
  #
  # Covering *fewer* revisions than revisions.json holds is the ordinary state
  # between an append and the indexing run that catches up to it — the offsets
  # already recorded still point where they did. Only a count that runs past the
  # end of the array proves the two files disagree about what offset 0 is.
  checkedIndex =
    if (index.revisionCount or null) == null || index.revisionCount > nRevs then
      throw ''
        multiverse: index/versions.json was built against ${toString (index.revisionCount or 0)}
        revisions but revisions.json now has ${toString nRevs}. Re-run tools/build-index.sh.
      ''
    else
      index;

  attrIndex = checkedIndex.attrs;

  # A human handle for a revision: date plus short rev. Release names are
  # deliberately not used here — a release name resolves to a moving channel
  # tip, so labelling a fixed offset with one would name a tree that `at` no
  # longer returns.
  labelOf =
    i:
    let
      r = revAt i;
    in
    "${r.date}-${builtins.substring 0 12 r.rev}";

  # Newest revision dated on or before `date`. Revisions are date-ordered, so a
  # left fold keeping the last match is enough.
  offsetOnOrBefore =
    date: builtins.foldl' (acc: i: if (revAt i).date <= date then i else acc) null offsets;

  # "08" is not valid JSON — leading zeros are forbidden — so the month and day
  # fields cannot go straight through fromJSON.
  toInt =
    s:
    builtins.fromJSON (
      if builtins.substring 0 1 s == "0" && builtins.stringLength s > 1 then
        builtins.substring 1 (builtins.stringLength s - 1) s
      else
        s
    );

  # A YYYY-MM-DD date as a day number, so two dates can be subtracted. This is
  # Howard Hinnant's days_from_civil: shift the year to start in March, which
  # puts the leap day last and makes the month-length pattern regular, then
  # count eras of 400 years. Nix divides integers by truncation, and every date
  # here is well after 1970, so the negative-year branch never runs.
  dayOf =
    date:
    let
      parts = builtins.match "([0-9]{4})-([0-9]{2})-([0-9]{2})" date;
      y0 = toInt (builtins.elemAt parts 0);
      m = toInt (builtins.elemAt parts 1);
      d = toInt (builtins.elemAt parts 2);
      y = if m <= 2 then y0 - 1 else y0;
      era = y / 400;
      yoe = y - era * 400;
      doy = (153 * (m + (if m > 2 then -3 else 9)) + 2) / 5 + d - 1;
      doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    in
    if parts == null then
      throw "multiverse: '${date}' is not a YYYY-MM-DD date"
    else
      era * 146097 + doe - 719468;

  # First revision whose commit hash starts with `sha`.
  offsetOfRev =
    sha:
    builtins.foldl' (
      acc: i:
      if acc != null then
        acc
      else if builtins.substring 0 (builtins.stringLength sha) (revAt i).rev == sha then
        i
      else
        acc
    ) null offsets;

  # Offset for a YYYY-MM-DD date, a commit hash prefix, or a revision label
  # (`YYYY-MM-DD-<hex>`, the handle revOf and revs hand out, so their output
  # feeds straight back in). Release names never reach here — `at` resolves
  # those against releases.json, which is not part of this array.
  resolve =
    sel:
    let
      labelParts = builtins.match "([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9a-f]+)" sel;
    in
    if labelParts != null then
      # A label names an exact revision, so resolve the commit prefix and
      # ignore the date half — decoration, not a search key.
      let
        i = offsetOfRev (builtins.elemAt labelParts 1);
      in
      if i == null then throw "multiverse: no revision matches label '${sel}'" else i
    else if builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" sel != null then
      let
        i = offsetOnOrBefore sel;
      in
      if i == null then throw "multiverse: no revision on or before ${sel}" else i
    else
      let
        i = offsetOfRev sel;
      in
      if i == null then
        throw "multiverse: '${sel}' is not a release name, a YYYY-MM-DD date, a revision label, or a known commit"
      else
        i;

  # One fetched tree, checked against the hash its record carries.
  #
  # Every record carries one: build-index.sh hashes a revision from the
  # checkout it already makes to extract versions, and fetch-releases.sh hashes
  # a channel tip when it moves. So a release is not a special case here, and
  # `at "26.05"` is verified exactly as an indexed selector is.
  #
  # The check sits outside the fetch so it holds however a fetcher got the
  # tree, including mechanisms builtins.fetchTree never sees.
  treeFor =
    r:
    let
      tree = fetchRevision r;
    in
    if tree.narHash == r.narHash then
      tree
    else
      throw ''
        multiverse: fetchRevision returned a tree for ${r.rev} hashing
        ${tree.narHash}, but ${r.narHash} was recorded. Store paths derive from
        content, so that tree yields derivations no digest in the store-path
        index describes. Serve the same bytes, or drop the fetcher.
      '';

  pathFor =
    i:
    let
      r = revAt i;
    in
    if r ? narHash then
      treeFor r
    else
      throw "multiverse: revision ${labelOf i} has no narHash; re-run tools/build-index.sh";

  # Whether a revision can be turned into a tree at all. fetchTree needs a
  # narHash, and a revision appended by fetch-unstable-revisions.sh has none
  # until build-index.sh reaches it. Asking for such a revision by name is
  # still an error — pathFor says so plainly — but nothing should *land* on one
  # by walking off the end of the array.
  materialisable = i: (revAt i) ? narHash;

  newestMaterialisable = builtins.foldl' (acc: i: if materialisable i then i else acc) null offsets;

  # The offset `tip` and `flakeAt "tip"` resolve to, with the empty-index
  # failure named once instead of at every call site.
  checkedTipOffset =
    if newestMaterialisable == null then
      throw "multiverse: no revision has a narHash; run tools/build-index.sh"
    else
      newestMaterialisable;

  # A selector's date, read straight out of revisions.json or releases.json.
  # Nothing is materialised to answer this, which is the whole reason a window
  # takes a selector rather than a package set: provenance rides *on* a package
  # set, so reading a date off one means fetching that entire revision first.
  dateOfSelector =
    sel:
    if sel == "tip" then
      if newestMaterialisable == null then
        throw "multiverse: no revision has a narHash; run tools/build-index.sh"
      else
        (revAt newestMaterialisable).date
    else if releaseTable ? ${sel} then
      releaseTable.${sel}.date
    else
      (revAt (resolve sel)).date;

  # Newest materialisable revision at least `days` older than `date`, as an
  # instance. Always searches the unstable revision list: an anchor only
  # supplies the date, so `behind "26.05" 7` means "unstable as it stood a week
  # before the 26.05 channel tip", not a walk back along release-26.05.
  instanceBehind =
    date: days:
    let
      cutoff = dayOf date - days;
      i = builtins.foldl' (
        acc: i: if materialisable i && dayOf (revAt i).date <= cutoff then i else acc
      ) null offsets;
    in
    if i == null then
      throw "multiverse: nothing is ${toString days} days before ${date}; the index reaches back to ${(revAt 0).date}"
    else
      instances.${toString i};

  # nixpkgs only grew an `overlays` argument in 17.03 — 16.09 takes exactly
  # { config, system } — and handing a function an argument it does not declare
  # is a hard error, not an ignored extra. Every revision is imported through
  # here so that the argument is offered only where it is accepted.
  importRevision =
    path:
    let
      entry = import path;
      accepted = builtins.functionArgs entry;
    in
    if accepted ? overlays then
      entry { inherit system config overlays; }
    else if overlays == [ ] then
      entry { inherit system config; }
    else
      throw "multiverse: this revision predates the `overlays` argument, which nixpkgs gained in 17.03, so it cannot take the overlays you passed";

  # Every package set carries where it came from. An imported nixpkgs has no
  # idea which revision produced it — `lib.version` reads "26.11pre-git" for a
  # fetched tree, and `path` is content-addressed — so without this, `at` hands
  # back something you cannot ask any further questions about, and `behind`
  # could only ever take a selector rather than a package set.
  tagged = provenance: pkgs: pkgs // { multiverse = provenance; };

  # Memoise per revision, keyed by offset. listToAttrs is lazy in its values, so
  # building this costs one thunk per revision and fetches nothing.
  instances = builtins.listToAttrs (
    map (i: {
      name = toString i;
      value = tagged {
        inherit (revAt i) rev date;
        label = labelOf i;
      } (importRevision (pathFor i));
    }) offsets
  );

  # Memoised the same way as instances, and just as lazy: naming a release
  # costs a thunk, forcing one costs a fetch.
  releaseInstances = builtins.mapAttrs (
    name: r: tagged (r // { release = name; }) (importRevision (treeFor r))
  ) releaseTable;

  # A fetched revision as a *flake* attrset: the value `inputs.nixpkgs` would
  # have been, had the revision been declared as a flake input. Shaped after
  # what Nix's own call-flake.nix constructs — outputs first, then sourceInfo,
  # so source metadata wins any collision, then the bookkeeping attributes.
  # `pathFor` and `treeFor` both return a fetchTree result, which is
  # exactly the sourceInfo attrset this needs (outPath, rev, narHash,
  # lastModified, ...).
  #
  # config and overlays deliberately do NOT apply here: a real flake input
  # never sees the consumer's nixpkgs config, so neither does this one. Use
  # `at` for a configured package set.
  mkFlakeInstance =
    provenance: sourceInfo:
    let
      # nixpkgs' own flake.nix has taken exactly `{ self }` since it appeared
      # in 20.03, so this fix-point is all call-flake.nix does for it. Trees
      # older than that get the two outputs the nixpkgs flake is consumed
      # through, synthesised the same vanilla way the real flake.nix builds
      # them.
      outputs =
        if builtins.pathExists (sourceInfo.outPath + "/flake.nix") then
          (import (sourceInfo.outPath + "/flake.nix")).outputs { self = result; }
        else
          {
            lib = import (sourceInfo.outPath + "/lib");
            legacyPackages.${system} = import sourceInfo.outPath { inherit system; };
          };

      result =
        outputs
        // sourceInfo
        // {
          inherit (sourceInfo) outPath;
          inputs = { };
          inherit outputs sourceInfo;
          _type = "flake";
          multiverse = provenance;
        };
    in
    result;

  # Memoised like `instances`, and for the same reason: two flakeAt calls that
  # land on the same offset share one import.
  flakeInstances = builtins.listToAttrs (
    map (i: {
      name = toString i;
      value = mkFlakeInstance {
        inherit (revAt i) rev date;
        label = labelOf i;
      } (pathFor i);
    }) offsets
  );

  releaseFlakeInstances = builtins.mapAttrs (
    name: r: mkFlakeInstance (r // { release = name; }) (treeFor r)
  ) releaseTable;

  # Releases as a two-level tree, split at the dot: "25.05" becomes
  # "25"."05". A release name cannot be a single flake attrpath segment
  # without quoting — the CLI splits on dots — so the split is what makes
  # `nix run .#25.05.python3` parse. A name that is not NN.NN-shaped is
  # skipped rather than crashing the whole tree over one odd channel.
  releaseTree = builtins.foldl' (
    acc: name:
    let
      parts = builtins.match "([0-9]+)\\.([0-9]+)" name;
      major = builtins.elemAt parts 0;
      minor = builtins.elemAt parts 1;
    in
    if parts == null then
      acc
    else
      acc
      // {
        ${major} = (acc.${major} or { }) // {
          ${minor} = releaseInstances.${name};
        };
      }
  ) { } (builtins.attrNames releaseTable);

  # Every revision under three exact-match keys: the full commit (what a
  # GitHub URL or a lock file hands you), the 12-character prefix (what
  # labels and `revs` display), and the label itself. All three alias the
  # memoised instance, so the whole set costs thunks, not fetches. Exact
  # match is the deal here — arbitrary prefixes and date rounding stay with
  # `at`, which can search; an attrset can only look up.
  revisionKeys = builtins.listToAttrs (
    builtins.concatMap (
      i:
      let
        r = revAt i;
        value = instances.${toString i};
      in
      [
        {
          name = r.rev;
          inherit value;
        }
        {
          name = builtins.substring 0 12 r.rev;
          inherit value;
        }
        {
          name = labelOf i;
          inherit value;
        }
      ]
    ) offsets
  );

  # Every version of an attribute with the offset it resolves to, the open-ended
  # tip encoding closed. Against the index's own revisionCount rather than
  # nRevs: a revision appended since the last indexing run is one this file has
  # never looked at, and resolving to it would claim a version was current in a
  # tree nobody evaluated.
  #
  # `mapAttrs` is lazy in its values, so an attribute whose versions are only
  # counted or named costs nothing here.
  versionsFor =
    attr: builtins.mapAttrs (_: off: if off == null then indexTip else off) (attrIndex.${attr} or { });

  indexTip = checkedIndex.revisionCount - 1;

  # `builtins.attrNames` sorts lexicographically, which puts 3.12.10 before
  # 3.12.7. Sort with the version-aware comparator instead. Deliberately uses
  # only builtins: reaching for `lib.sort` would mean instantiating a revision
  # just to order a list of strings.
  sortVersions = builtins.sort (a: b: builtins.compareVersions a b < 0);

  # When each version was present, as run-length ranges of revision offsets —
  # the timeline `index` deliberately does not carry, since it keeps only the
  # newest revision per version.
  history = builtins.fromJSON (builtins.readFile ./index/history.json);

  # Same offsets-are-only-valid-against-the-list-they-were-built-from guard the
  # index gets. History is written by tools/build-history.sh from the same
  # extraction cache, so the two files should agree; disagreeing with
  # revisions.json is what proves one of them is stale.
  checkedHistory =
    if (history.revisionCount or null) == null || history.revisionCount > nRevs then
      throw ''
        multiverse: index/history.json was built against ${toString (history.revisionCount or 0)}
        revisions but revisions.json now has ${toString nRevs}. Re-run tools/build-history.sh.
      ''
    else
      history;

  # On disk a version with one unbroken run is stored as [first, last] and one
  # with gaps as a list of those pairs — 91.6% of pairs are single-run, so the
  # collapse is most of a megabyte. Everything below works on the expanded form.
  #
  # A run still open at the newest revision covered ends in `null` rather than
  # in that offset, for the same reason the index stores a null offset — see
  # docs/design.md. `closeRun` is where it stops being null, so every reader
  # below still sees two plain offsets.
  historyTip = checkedHistory.revisionCount - 1;

  closeRun =
    r:
    if builtins.elemAt r 1 == null then
      [
        (builtins.elemAt r 0)
        historyTip
      ]
    else
      r;

  runsOf =
    attr: ver:
    let
      raw = (checkedHistory.attrs.${attr} or { }).${ver} or null;
    in
    if raw == null then
      null
    else if builtins.isList (builtins.head raw) then
      map closeRun raw
    else
      [ (closeRun raw) ];

  # Revisions inside the covered prefix that were never extracted, so a gap in a
  # run can be told apart from a revision nobody ever looked at.
  skipped = checkedHistory.skipped;

  # ---------------------------------------------------------------------------
  # Minimising: the fewest revisions that serve a set of pins.
  #
  # Cost here is per revision touched, not per package, so twenty pins spread
  # over twenty revisions is twenty nixpkgs fetches and twenty evaluations.
  # Grouping them onto the revisions they can share is the difference between
  # that and one.
  #
  # The whole search is a greedy sweep, and is exactly minimal. See
  # docs/design.md for the argument; `mvs solve` implements the same one and
  # the two must agree, which tests/history.nix checks.
  # ---------------------------------------------------------------------------

  # The single block of revisions one pin is served by: the newest run of its
  # version.
  #
  # A version can leave nixpkgs and come back, so a pin can hold over several
  # disjoint stretches. Taking the newest is what `version` already resolves
  # to — index/versions.json records only the newest revision shipping each
  # version — and holding every pin to one stretch is what keeps the sweep
  # below polynomial: a pin free to pick among its stretches turns the search
  # into vertex cover.
  blockOf =
    attr: ver:
    let
      rs = runsOf attr ver;
    in
    if rs == null then
      throw "multiverse: no revision ever shipped ${attr} ${ver}, so nothing can serve it"
    else
      builtins.elemAt rs (builtins.length rs - 1);

  # The plan for a `{ attr = version; }` attrset: which revisions serve which
  # pins, and the proof that no smaller set of revisions exists.
  planFor =
    pins:
    let
      attrs = builtins.attrNames pins;
      blocks = map (attr: blockOf attr pins.${attr}) attrs;
      firstOf = i: builtins.elemAt (builtins.elemAt blocks i) 0;
      lastOf = i: builtins.elemAt (builtins.elemAt blocks i) 1;

      # Earliest-ending block first: the only order the exchange argument
      # holds in.
      order = builtins.sort (a: b: lastOf a < lastOf b) (builtins.genList (i: i) (builtins.length attrs));

      # Revisions are therefore placed oldest to newest, so the newest one
      # placed is the only one that can still reach the block being
      # considered. A block it cannot reach forces a revision of its own, at
      # that block's last revision.
      swept =
        builtins.foldl'
          (
            acc: i:
            let
              reached = acc.offs != [ ] && builtins.elemAt acc.offs (builtins.length acc.offs - 1) >= firstOf i;
            in
            if reached then
              acc
            else
              {
                offs = acc.offs ++ [ (lastOf i) ];
                forced = acc.forced ++ [ i ];
              }
          )
          {
            offs = [ ];
            forced = [ ];
          }
          order;

      # Each pin then joins the *newest* revision serving it rather than the
      # first one placed. The plan is the same size either way, but a pin held
      # at an older revision than it needs is an older build of the same
      # version, so the later revision is strictly the better home. Folding
      # left over offsets in order keeps the last match, which is that one.
      homeOf =
        i:
        builtins.foldl' (
          best: off: if firstOf i <= off && off <= lastOf i then off else best
        ) null swept.offs;

      pinsAt = off: builtins.filter (attr: homeOf (indexOfAttr attr) == off) attrs;

      indexOfAttr =
        attr:
        builtins.foldl' (acc: i: if builtins.elemAt attrs i == attr then i else acc) null (
          builtins.genList (i: i) (builtins.length attrs)
        );

      # How much older than its own newest revision a pin ended up. Zero for
      # the pin that forced its group.
      describePin =
        off: attr:
        let
          i = indexOfAttr attr;
        in
        {
          inherit attr;
          version = pins.${attr};
          movedRevisions = lastOf i - off;
          movedDays = dayOf (revAt (lastOf i)).date - dayOf (revAt off).date;
        };

      named = map (i: "${builtins.elemAt attrs i} ${pins.${builtins.elemAt attrs i}}") swept.forced;
      forcedCount = builtins.length named;

      # The same summarising `mvs solve` does, so the two surfaces produce the
      # same sentence for the same plan. Four names fit a line; past that the
      # list stops being readable and the count says more.
      certificateShown = 4;
      leading = builtins.concatStringsSep ", " (
        builtins.genList (i: builtins.elemAt named i) (
          if forcedCount < certificateShown then forcedCount else certificateShown
        )
      );
    in
    # Every pin's block is forced before any of the plan is readable, so a
    # version nothing ever shipped is an error rather than a plan quietly
    # missing a pin. Nothing else here would force it for a single-pin plan:
    # `sort` never calls its comparator on a one-element list, and `++` is lazy
    # in its elements. A block is one lookup in a file already parsed, so
    # forcing them all costs nothing worth keeping lazy.
    builtins.deepSeq blocks {
      revisions = builtins.length swept.offs;

      groups = map (off: {
        revision = revAt off // {
          off = off;
          label = labelOf off;
        };
        pins = map (describePin off) (pinsAt off);
      }) swept.offs;

      # The pins that forced each revision. Their blocks are pairwise disjoint
      # by construction, so any plan needs at least this many revisions — the
      # part a reader can check from the dates without trusting the sweep.
      certificate = named;

      why =
        if forcedCount <= 1 then
          "one revision serves every pin"
        else if forcedCount == 2 then
          "${builtins.elemAt named 0} and ${builtins.elemAt named 1} never overlapped"
        else if forcedCount <= certificateShown then
          "${leading} never overlap"
        else
          "${leading} and ${toString (forcedCount - certificateShown)} others never overlap";
    };

  # ---------------------------------------------------------------------------
  # The fast path: fake derivations over the store-path index, after
  # tomberek's fastpkgs (github.com/tomberek/fastpkgs) mkFakeDerivation trick.
  #
  # An attrset that walks and quacks like a derivation, whose outPath is the
  # digest the index recorded, given real store context via
  # builtins.appendContext. `nix build` / `nix shell` then treat the path as
  # an opaque store reference and substitute it — full closure included —
  # from cache.nixos.org. No nixpkgs fetch, no evaluation of one, no
  # experimental features. The census is what makes this honest: every
  # indexed address was verified to still substitute.
  #
  # Everything below is forced only when a fast.* value is, so the artifacts
  # pin costs nothing until the first fake is asked for — the same
  # nothing-is-eager doctrine as the revisions themselves.
  # ---------------------------------------------------------------------------

  # The real-derivation resolver, hoisted out of the exported set because the
  # fast path below hands it out as `.eval` on every fake. `version` in the
  # exported set is this exact function.
  versionDrv =
    attr: ver:
    let
      i = (versionsFor attr).${ver} or null;
      known = sortVersions (builtins.attrNames (versionsFor attr));
    in
    if i == null then
      throw ''
        multiverse: no revision provides ${attr} ${ver}.
        Known versions: ${
          if known == [ ] then "(attribute not in index)" else builtins.concatStringsSep " " known
        }
      ''
    else
      instances.${toString i}.${attr};

  dataPins = builtins.fromJSON (builtins.readFile ./data-pins.json);

  # One artifact file as a local path: whatever fetchArtifact hands back. A
  # vendored tree is not a special case, it is a fetcher that fetches nothing —
  # `{ name, ... }: ./artifacts + "/${name}"`.
  artifactPath =
    name:
    let
      pin =
        dataPins.files.${name}
          or (throw "multiverse: data-pins.json has no pin for ${name}; re-run tools/bump-data-pin.sh");
    in
    fetchArtifact {
      inherit name;
      inherit (pin) tag narHash;
      inherit (dataPins) baseUrl;
    };

  readArtifact = name: builtins.fromJSON (builtins.readFile (artifactPath name));

  # The same built-against-a-different-revision-list guard checkedIndex and
  # checkedHistory apply, for the two store-path artifacts that carry the
  # count. Neither file holds an offset — a digest is keyed by (attr, version)
  # and is timeless — so this cannot resolve to the wrong commit the way a
  # stale index can. What it catches is a pin describing a history this
  # checkout is not part of: hand-assembled artifacts, or a pin rolled back
  # onto an older tree.
  #
  # Covering fewer revisions is the ordinary state and stays allowed. The
  # dated data release is cut once a UTC day while revisions.json advances
  # with every bump, so the pin is behind for most of the day, every day.
  checkedArtifact =
    name: data:
    if (data.revisionCount or null) == null || data.revisionCount > nRevs then
      throw ''
        multiverse: ${name} was built against ${toString (data.revisionCount or 0)}
        revisions but revisions.json now has ${toString nRevs}. Update the checkout,
        or re-point the pin with tools/bump-data-pin.sh.
      ''
    else
      data;

  # The store-path artifacts are per system, because a store path is per
  # system: one file holds every digest evaluated for `system` and checked
  # against the channel listings, and a system nobody has evaluated has no file
  # at all rather than a wrong entry. See docs/store-paths.md.
  #
  # A file per system rather than a system key inside each entry, because the
  # fast path's cost model is "fetch exactly one small file": nesting would make
  # every x86_64 user download the aarch64 half too.
  outpathsFile = "outpaths-${system}.json";
  tipOutpathsFile = "tip-outpaths-${system}.json";
  outsFile = "outs-${system}.json";

  # Whether this system has those files, asked of data-pins.json: it is the only
  # party that can speak for what was published. A fetchArtifact serving fewer
  # systems than the pin answers for itself, failing on the file it has no copy
  # of.
  fastSupported = dataPins.files ? ${outpathsFile};

  # Closed pairs, plus the snapshot of what was current when the pin was cut.
  # Both files are keyed, timeless truth — (attr, version) -> digest — so a
  # lagging pin only loses the fast path for versions that closed since; the
  # eval fallback serves those meanwhile.
  fastClosed = checkedArtifact outpathsFile (readArtifact outpathsFile);
  fastTip = checkedArtifact tipOutpathsFile (readArtifact tipOutpathsFile);

  # { attr -> { version -> [digest, drv-name-if-differs, ...] } }
  #
  # The unsupported-system guard sits here rather than at each use: this is
  # where an artifact is first read, so forcing anything downstream of it on a
  # system with no data reports that, instead of a missing pin.
  fastIndex =
    if !fastSupported then
      throw ''
        multiverse: fast has no store-path index for ${system} — no
        ${outpathsFile} is published. Use the eval path, which evaluates
        nixpkgs for whatever system it is asked about.
      ''
    else
      fastClosed.attrs
      // builtins.mapAttrs (attr: vers: (fastClosed.attrs.${attr} or { }) // vers) fastTip.attrs;

  # { digest -> { output suffix -> digest } }: the sibling outputs of a
  # multi-output package, keyed by the digest of its `out` path.
  #
  # Keyed by digest and not by derivation name, because a name is claimed by
  # more than one package (and, before this was per system, by more than one
  # architecture), while a digest is unique by construction. "out" is dropped
  # defensively: it is the path the index already records, and a stray
  # <name>-out entry must not shadow it.
  siblingOutputs = builtins.mapAttrs (_: outs: builtins.removeAttrs outs [ "out" ]) (
    readArtifact outsFile
  );

  checkedFastFallback =
    if fastFallback == "throw" || fastFallback == "eval" then
      fastFallback
    else
      throw ''multiverse: fastFallback must be "throw" or "eval", not "${toString fastFallback}"'';

  # A bare store path only substitutes if the string carries context naming
  # it; appendContext is what turns a digest from the index into something
  # `nix build` will fetch.
  storePathWithContext =
    p:
    builtins.appendContext p {
      ${p} = {
        path = true;
      };
    };

  fastEntryFor = attr: ver: (fastIndex.${attr} or { }).${ver} or null;

  # The fake derivation for one matched pair. `evalDrv` is the real,
  # revision-exact derivation, carried on `.eval` for everything a fake
  # cannot do: override, nix develop, drvPath, full meta.
  #
  # A system with no artifacts never reaches here: an entry comes from
  # fastIndex, and forcing that throws first.
  mkFake =
    attr: ver: entry: evalDrv:
    let
      digest = builtins.elemAt entry 0;
      drvName = if builtins.length entry > 1 then builtins.elemAt entry 1 else "${attr}-${ver}";
      # Keyed by the `out` digest, so siblings belong to this exact path
      # rather than to everything that ever carried this derivation name.
      siblings = siblingOutputs.${digest} or { };

      # Each output is the bare context-carrying store path string, not a
      # nested attrset. That is what makes `nix build .#…hello."2.12.2".out`
      # work: the CLI sees a store path and substitutes it, no derivation
      # required. The attrset spelling (an output as another derivation
      # attrset) would send the CLI looking for the drvPath there is not.
      outputPaths = {
        out = storePathWithContext "/nix/store/${digest}-${drvName}";
      }
      // builtins.mapAttrs (
        suffix: d: storePathWithContext "/nix/store/${d}-${drvName}-${suffix}"
      ) siblings;
    in
    {
      type = "derivation";
      name = drvName;
      pname = (builtins.parseDrvName drvName).name;
      version = ver;
      inherit system;
      outputs = [ "out" ] ++ builtins.attrNames siblings;
      outputName = "out";
      outPath = outputPaths.out;
      # Deliberately minimal: nothing evaluated nixpkgs, so there is
      # nothing honest to put here. `.eval.meta` has the real thing.
      meta = { };
      # `nix build`/`nix run`/`nix shell` on the bare attrpath ask for the
      # drvPath a fake cannot have, so the message says what to append.
      drvPath = throw ''
        multiverse: ${drvName} is a fast fake derivation and has no drvPath — it
        substitutes by store path alone. Append the output: …${attr}."${ver}".out
        (outputs: ${builtins.concatStringsSep " " ([ "out" ] ++ builtins.attrNames siblings)}).
        For override / nix develop / a real derivation, use .eval instead.
      '';
      eval = evalDrv;
    }
    // outputPaths;

  # A miss under fast.*: throw naming the eval selector — never a surprise
  # 378 MB fetch inside something called fast — unless the importer opted
  # into transparent fallback.
  fastMissing =
    attr: ver: evalSelector: evalDrv:
    if checkedFastFallback == "eval" then
      evalDrv
    else
      throw ''
        multiverse: fast has no store path for ${attr} ${ver} — the pair is not in
        the store-path index (never built by Hydra, unfree, or newer than the data
        pin). Use the eval path: ${evalSelector}
        or import the multiverse with fastFallback = "eval" to fall back silently.
      '';

  fastVersion =
    attr: ver:
    let
      entry = fastEntryFor attr ver;
      evalDrv = versionDrv attr ver;
    in
    if entry == null then
      fastMissing attr ver ''versions.${attr}."${ver}"'' evalDrv
    else
      mkFake attr ver entry evalDrv;
in
rec {
  inherit revisions;

  # The two index files, as parsed — except that the open-ended tip encoding is
  # closed on the way out, so a consumer reading them directly gets the plain
  # offsets it has always got and never has to know a null can appear on disk.
  # Forcing one of these is what parses the file, so naming them here costs
  # nothing until something reads them, and `mapAttrs` is lazy in its values, so
  # reading one attribute resolves one attribute.
  index = checkedIndex // {
    attrs = builtins.mapAttrs (attr: _: versionsFor attr) attrIndex;
  };

  history = checkedHistory // {
    attrs = builtins.mapAttrs (
      attr: vers:
      builtins.mapAttrs (
        ver: _:
        let
          rs = runsOf attr ver;
        in
        # Re-collapsed the way the file stores it: a single run is the pair
        # itself, not a list holding it.
        if builtins.length rs == 1 then builtins.head rs else rs
      ) vers
    ) checkedHistory.attrs;
  };

  # Human handles for every revision, oldest first.
  revs = map labelOf offsets;

  # Every release channel being tracked, oldest first.
  releases = builtins.attrNames releaseTable;

  # The raw release table: what commit each channel is currently at, and when.
  releaseTips = releaseTable;

  # A whole nixpkgs.
  #   at "25.05"        the release channel as it stands TODAY, backports and
  #                     all — a moving target, like nixos-25.05 itself
  #   at "2024-06-12"   newest revision on or before that date — fixed forever
  #   at "dc460ec76cbf" commit hash prefix — fixed forever
  #   at "2021-07-18-967d40bec14b"
  #                     a revision label, as revOf and revs hand out — fixed
  #                     forever, so revOf's answer feeds straight back in
  at =
    sel:
    if sel == "tip" then
      tip
    else if releaseTable ? ${sel} then
      releaseInstances.${sel}
    else
      instances.${toString (resolve sel)};

  # The newest revision this index knows, as a real nixpkgs — `lib`,
  # `callPackage`, and a package set that is internally consistent, which is
  # what `latest` deliberately is not.
  #
  # Named for the tip of the *index*, not the tip of the channel. It is frozen
  # at whatever the last indexing run captured and drifts further behind
  # nixos-unstable every day until the index is rebuilt. If you want the live
  # channel, add a nixpkgs input; multiverse is for reaching backwards.
  #
  # The newest *materialisable* revision rather than the last one on file:
  # between an append and the indexing run that catches up to it, the last few
  # entries have no narHash and cannot be fetched. `tip` is a promise to hand
  # back a working nixpkgs, so it walks back to the newest one that is.
  tip = instances.${toString checkedTipOffset};

  # A whole nixpkgs as the flake attrset `inputs.nixpkgs` would have been —
  # same selectors as `at`, but the flake shape instead of a package set:
  #
  #   (flakeAt "26.05").lib.nixosSystem { ... }
  #   (flakeAt "26.05").legacyPackages.${system}.hello
  #
  # This is what flake-world entry points consume. `nixosSystem` in particular
  # only exists on the nixpkgs *flake* — a package set's `lib` does not have
  # it — and it stamps `nixpkgs.flake.source` from `self`, so registry and
  # NIX_PATH pinning point at the real fetched tree. Source metadata (rev,
  # narHash, lastModified) rides along for the same reason.
  flakeAt =
    sel:
    if sel == "tip" then
      flakeInstances.${toString checkedTipOffset}
    else if releaseTable ? ${sel} then
      releaseFlakeInstances.${sel}
    else
      flakeInstances.${toString (resolve sel)};

  # A soak period: the whole of nixos-unstable as it stood some number of days
  # before an anchor. The anchor is any selector `at` takes:
  #
  #   daysBehind "tip" 7            a week behind the newest indexed revision
  #   daysBehind "26.05" 7          a week before the 26.05 channel tip
  #   daysBehind "2026-05-30" 7     a week before that date
  #   daysBehind "dc460ec76cbf" 30  a month before that commit landed
  daysBehind = sel: days: instanceBehind (dateOfSelector sel) days;

  # Every known version of an attribute, oldest first.
  versionsOf = attr: sortVersions (builtins.attrNames (versionsFor attr));

  # ---------------------------------------------------------------------------
  # History. Everything below reads index/history.json rather than the index,
  # and nothing above touches it — see the `history` binding for why that split
  # is load-bearing rather than tidiness.
  # ---------------------------------------------------------------------------

  # When a version was present, as dates and labels rather than raw offsets:
  #
  #   lifetimeOf "python3" "3.8.9"
  #   => { earliest = "2021-03-02"; latest = "2021-11-14";
  #        earliestLabel = "2021-03-02-…"; latestLabel = "2021-11-14-…";
  #        runs = [ { first = …; last = …; … } ]; }
  #
  # null for a pair the history does not know.
  #
  # Two levels, named apart because they claim different things. `earliest` and
  # `latest` are the outer bounds of every sighting — the version was seen at
  # each of those dates, and nothing is asserted about the span between them.
  # `runs` are the unbroken stretches, so a run's `first`/`last` really are the
  # ends of a range the version held throughout.
  lifetimeOf =
    attr: ver:
    let
      rs = runsOf attr ver;
      spans = map (r: {
        first = (revAt (builtins.elemAt r 0)).date;
        last = (revAt (builtins.elemAt r 1)).date;
        firstLabel = labelOf (builtins.elemAt r 0);
        lastLabel = labelOf (builtins.elemAt r 1);
      }) (if rs == null then [ ] else rs);
      firstRun = builtins.head spans;
      lastRun = builtins.elemAt spans (builtins.length spans - 1);
    in
    if rs == null then
      null
    else
      {
        earliest = firstRun.first;
        earliestLabel = firstRun.firstLabel;
        latest = lastRun.last;
        latestLabel = lastRun.lastLabel;
        runs = spans;
      };

  # Every version an attribute ever had, with its lifetime, oldest version
  # first. The timeline for one package, answered without fetching anything.
  historyOf =
    attr:
    map (ver: { inherit ver; } // lifetimeOf attr ver) (
      sortVersions (builtins.attrNames (checkedHistory.attrs.${attr} or { }))
    );

  # What version an attribute had at a given revision — the question the
  # newest-only index cannot answer at all, and which otherwise costs a ~378 MB
  # fetch of the whole revision just to read one `.version`.
  #
  #   versionAt "python3" "2022-03-15"  => "3.9.10"
  #
  # Takes the same selectors `at` does, minus releases: a release tip is a
  # moving channel head rather than an indexed offset, so there is no honest
  # answer to give for one.
  versionAt =
    attr: sel:
    let
      off = if sel == "tip" then checkedTipOffset else resolve sel;
      vers = builtins.attrNames (checkedHistory.attrs.${attr} or { });
      covers =
        ver: builtins.any (r: builtins.elemAt r 0 <= off && off <= builtins.elemAt r 1) (runsOf attr ver);
      hits = builtins.filter covers vers;
    in
    if releaseTable ? ${sel} then
      throw ''
        multiverse: versionAt cannot take the release "${sel}". A release is a channel
        tip that moves, not a revision the index has an offset for. Select by date or
        commit, or read the version off the package set: (at "${sel}").${attr}.version
      ''
    else if hits == [ ] then
      null
    else
      builtins.head hits;

  # When an attribute was last seen, or null if it is still in the newest
  # revision the history covers. This is what makes "whatever happened to
  # `foo`" answerable, and the label it returns feeds straight back into `at`
  # to get a working derivation out of the last revision that had it:
  #
  #   goneSince "python2"  => { date = "2026-05-23"; label = "2026-05-23-…";
  #                             version = "2.7.18.12"; }
  #
  # An attribute the history has never seen throws rather than answering null.
  # Null has to mean "still here", and quietly returning it for a name that was
  # never in nixpkgs — or for a package set like `gnome3`, which has no
  # `.version` and so was never indexed — would report the two as the same.
  goneSince =
    attr:
    let
      vers = builtins.attrNames (checkedHistory.attrs.${attr} or { });
      lastOffOf =
        ver:
        let
          rs = runsOf attr ver;
        in
        builtins.elemAt (builtins.elemAt rs (builtins.length rs - 1)) 1;
      newest = builtins.foldl' (
        acc: v: if acc == null || lastOffOf v > lastOffOf acc then v else acc
      ) null vers;
    in
    if vers == [ ] then
      throw ''
        multiverse: ${attr} is not in the history index, so there is no last sighting
        to report. Attributes without a `.version` — package sets such as `gnome3` —
        are never indexed, and neither are nested sets like `python3Packages.*`.
      ''
    else if lastOffOf newest >= checkedHistory.revisionCount - 1 then
      null
    else
      {
        date = (revAt (lastOffOf newest)).date;
        label = labelOf (lastOffOf newest);
        version = newest;
      };

  # Revisions inside the covered prefix that were never extracted. A gap in a
  # run means "absent"; an offset in here means "never looked", and the two are
  # not the same claim.
  skippedRevisions = map labelOf skipped;

  # The revision a given version resolves to, as a human handle.
  revOf =
    attr: ver:
    let
      i = (versionsFor attr).${ver} or null;
    in
    if i == null then null else labelOf i;

  # The headline operation: a specific version of a package. Distinct graphs
  # coexist happily — Nix keeps them disjoint, so several versions of the same
  # package can sit in one buildEnv.
  version = versionDrv;

  # A set of pins resolved through the fewest revisions that can serve them:
  #
  #   solvePins { ripgrep = "13.0.0"; fd = "8.7.0"; jq = "1.6"; }
  #   => { ripgrep = <drv>; fd = <drv>; jq = <drv>; }   all from 2023-09-25
  #
  # The versions are exactly the ones asked for. What minimising decides is
  # which revision serves each, and pins that can share one do — a shared
  # revision is fetched and evaluated once, so three pins on one revision cost
  # what a single pin costs.
  #
  # The price is that a pin can land on an older revision inside its own
  # version's run: the same version, an older build of it. `pinPlan` reports
  # exactly how much older, per pin, before anything is built.
  #
  # `mapAttrs` is lazy in its values, so nothing is materialised until one of
  # these derivations is.
  solvePins =
    pins:
    let
      plan = planFor pins;
      homes = builtins.foldl' (
        acc: group:
        acc
        // builtins.listToAttrs (
          map (p: {
            name = p.attr;
            value = group.revision.off;
          }) group.pins
        )
      ) { } plan.groups;
    in
    builtins.mapAttrs (attr: _: instances.${toString homes.${attr}}.${attr}) pins;

  # The same plan `solvePins` builds, as data rather than as derivations:
  #
  #   pinPlan { python3 = "3.8.9"; ripgrep = "14.1.1"; }
  #   => { revisions = 2; groups = [ ... ]; certificate = [ ... ]; why = "..."; }
  #
  # The same fields `mvs solve --json` prints, so a configuration can assert on
  # a plan the CLI can also explain. `revisions == 1` is how a caller demands
  # one revision for a set of pins; `why` is the sentence to fail with, and
  # names the pins that make a smaller plan impossible.
  pinPlan = planFor;

  # A lock file written by `mvs lock`, resolved to derivations:
  #
  #   readLock ./multiverse.lock  =>  { helix = <derivation>; ripgrep = <derivation>; }
  #
  # Each pin names one revision by commit and is resolved on its own, which is
  # the property a flake input cannot have: `mvs lock update helix` moves exactly
  # that entry and leaves every other pin where it was.
  #
  # `mapAttrs` is lazy in its values, so a lock with twenty pins materialises
  # only the revisions behind the packages actually built.
  readLock =
    file:
    let
      lock = builtins.fromJSON (builtins.readFile file);

      # A pin is only ever a commit plus decoration. `label`, `version` and
      # `date` are there for the reader and for `mvs lock status`; `rev` is the
      # only field that decides which tree comes back, so a hand-edited version
      # string cannot quietly change what gets built.
      resolvePin =
        attr: pin:
        let
          pkgs = at pin.rev;
        in
        if !(pin ? rev) then
          throw "multiverse: the pin for ${attr} in ${toString file} has no `rev`"
        else if !(pkgs ? ${attr}) then
          throw ''
            multiverse: ${attr} is pinned to ${pin.rev} but that revision has no such
            attribute. Only top-level attributes can be pinned — nested sets like
            python3Packages.* are not in the index and cannot be named in a lock file.
          ''
        else
          pkgs.${attr};
    in
    if (lock.version or null) != lockVersion then
      throw ''
        multiverse: ${toString file} is lock format version ${toString (lock.version or 0)},
        and this multiverse reads version ${toString lockVersion}.
      ''
    else
      builtins.mapAttrs resolvePin (lock.pins or { });

  # The lock format `readLock` accepts and `mvs lock` writes. Bumped only for a
  # change an older reader would misinterpret; a new optional field is not one.
  lockVersion = 1;

  # Materialised {attr -> {version -> derivation}}, so plain flake installable
  # syntax works — `nix shell .#versions.python3."3.8.9"` — which the function
  # API above cannot express, because a flake attribute path takes no arguments.
  #
  # `mapAttrs` is lazy in its values, so forcing one version instantiates
  # exactly one revision and leaves every other pair an untouched thunk.
  versions = builtins.mapAttrs (
    attr: vers: builtins.mapAttrs (ver: _: version attr ver) vers
  ) attrIndex;

  # Newest known version of each attribute, as a plain attrset so it works as a
  # flake installable:
  #
  #   nix run 'github:fzakaria/nixpkgs-multiverse#latest.python3'
  #   mv.latest.python3
  #
  # A sibling attrset rather than a `latest` key inside `versions.<pkg>`: that
  # would mix an alias into keys that are otherwise version strings, and would
  # collide with any package whose upstream literally ships a version called
  # "latest" (`relibc` does). Here the two namespaces never touch.
  #
  # `mapAttrs` is lazy in its values, so this costs one thunk per attribute and
  # resolves nothing until asked.
  latest = builtins.mapAttrs (
    attr: vers:
    let
      sorted = sortVersions (builtins.attrNames vers);
    in
    version attr (builtins.elemAt sorted (builtins.length sorted - 1))
  ) attrIndex;

  # Exact-match keys for flake attrpaths. flake.nix merges these into
  # legacyPackages, which is what lets plain installable syntax name a
  # revision — every key below avoids dots, so none of it needs quoting:
  #
  #   nix run .#25.05.python3                                  release
  #   nix run .#2021-07-18-967d40bec14b.python3                label
  #   nix run .#967d40bec14b.python3                           12-char prefix
  #   nix run .#967d40bec14be87262b21ab901dbace23b7365db.hello full commit
  #
  # A sibling attrset rather than keys in the API itself, so `builtins.attrNames`
  # on a multiverse stays readable and repl completion stays usable.
  installables = releaseTree // revisionKeys;

  # ---------------------------------------------------------------------------
  # The fast path: the selector grammar above with only the terminal step
  # swapped — revision -> version -> digest -> fake derivation — so nothing
  # here fetches or evaluates a nixpkgs. See mkFake above for the mechanism
  # (after tomberek's fastpkgs) and docs/store-paths.md for the data.
  #
  # Three honesty classes, chosen per selector rather than approximated:
  #
  #   fast.versions / fast.latest are BIT-EXACT as of the data pin: the
  #   digest is precisely the build the eval path resolves to.
  #
  #   fast.at and fast.tip (commit, date, label selectors, and the newest
  #   indexed revision) are VERSION-EXACT and build-canonical: the right
  #   version for that revision, as the newest build of it the index
  #   records — the index keeps one digest per version, not one per
  #   revision. `tip` belongs here rather than above because it is
  #   `fast.at "tip"`; see its definition for why that is the honest
  #   spelling.
  #
  #   Release selectors are EVAL-ONLY and refuse. Not for want of data:
  #   release channels publish store-paths.xz under nixos/<major.minor>/
  #   exactly as unstable does, at the very channel name releases.json
  #   already records. What is missing is a key. This index is keyed
  #   (attr, version) -> digest, and that pair does not identify a build
  #   across branches: of the 80,611 derivation names present in both the
  #   26.05 and unstable listings, 80,571 have different store paths, since
  #   a path hashes the whole recipe and a release branch carries its own
  #   stdenv. The 40 that agree are fonts and other content-addressed
  #   blobs. So an unstable digest is wrong for a release almost everywhere,
  #   not merely where a backport moved the version. Serving releases needs
  #   a branch axis on the digests and a version index for release tips,
  #   neither of which exists; `at` serves them for real meanwhile.
  #
  # Every fake carries a lazy `.eval` holding the real, revision-exact
  # derivation for everything a fake cannot do (override, nix develop,
  # drvPath, meta). A pair the index has no digest for throws, naming the
  # eval selector to use — never a surprise 378 MB fetch inside something
  # called fast — unless the multiverse was imported with
  # fastFallback = "eval".
  # ---------------------------------------------------------------------------
  fast =
    let
      # The whole package set at a revision, as fakes: version-exact,
      # build-canonical. Returns fakes only — no `lib`, no `callPackage` —
      # because there is no nixpkgs behind it.
      fastAt =
        sel:
        if releaseTable ? ${sel} then
          throw ''
            multiverse: fast cannot serve the release "${sel}". The store-path index
            is keyed (attr, version) -> digest, and that pair names a different build
            on every branch — a release carries its own stdenv, so nearly every path
            differs from unstable's even at an identical version. Use the eval path,
            which builds the release tree for real: at "${sel}"
          ''
        else
          builtins.mapAttrs (
            attr: _:
            let
              ver = versionAt attr sel;
              entry = if ver == null then null else fastEntryFor attr ver;
              evalDrv = (at sel).${attr};
            in
            if ver == null then
              throw "multiverse: the history index has no version of ${attr} at ${sel}"
            else if entry == null then
              fastMissing attr ver ''(at "${sel}").${attr}'' evalDrv
            else
              mkFake attr ver entry evalDrv
          ) checkedHistory.attrs;

      newestOf =
        attr: vers:
        let
          sorted = sortVersions (builtins.attrNames vers);
        in
        fastVersion attr (builtins.elemAt sorted (builtins.length sorted - 1));

      # Exact-match revision keys, mirroring `installables`: full commit,
      # 12-character prefix, label — plus each revision's date, which the
      # attrpath grammar can afford here because fastAt re-resolves the
      # date through the same newest-on-or-before rule `at` uses.
      fastKeys = builtins.listToAttrs (
        builtins.concatMap (
          i:
          let
            r = revAt i;
            value = fastAt (labelOf i);
          in
          [
            {
              name = r.rev;
              inherit value;
            }
            {
              name = builtins.substring 0 12 r.rev;
              inherit value;
            }
            {
              name = labelOf i;
              inherit value;
            }
            {
              name = r.date;
              value = fastAt r.date;
            }
          ]
        ) offsets
      );
    in
    fastKeys
    // {
      # A specific version, zero-eval: fast.version "python3" "3.8.9".
      version = fastVersion;

      # Materialised {attr -> {version -> fake}}, the flake-installable
      # spelling: nix shell .#fast.versions.python3."3.8.9".
      #
      # Keyed by the eval index rather than by the store-path index, so the
      # tree has a key for every pair `versions` has. A pair the store-path
      # index did not match resolves through fastVersion like any other and
      # lands on fastMissing, which is the only way a miss can reach either
      # the message naming the eval selector or fastFallback: an attribute
      # absent from the attrset is Nix's own "attribute missing", thrown
      # before any code here runs. Unfree attributes are the whole class —
      # Hydra evaluates nixpkgs with allowUnfree = false, so no version of
      # one is ever built, and none of them would otherwise be addressable.
      #
      # The cost is one parse of index/versions.json (~0.2s) on the first
      # fast.versions lookup; mapAttrs stays lazy in its values, so a hit
      # still resolves out of the store-path data alone.
      versions = builtins.mapAttrs (
        attr: vers: builtins.mapAttrs (ver: _: fastVersion attr ver) vers
      ) attrIndex;

      # Newest indexed version of each attribute, as of the data pin.
      #
      # A union rather than the swap `versions` above does, because newestOf
      # reads "newest" off whichever key set it is handed. Where the
      # store-path index has the attribute its versions win, so `latest`
      # keeps meaning the newest version that can be served instantly rather
      # than the newest that exists — 757 attributes differ between those two
      # readings, and each would otherwise turn from a fake into a throw, or,
      # under fastFallback = "eval", into a quiet 378 MB fetch inside fast.
      # Where it does not, the eval index supplies the key, and the newest
      # known version resolves through fastMissing exactly as it does under
      # `versions`. That second half is pure addition: those attributes had
      # no key here at all.
      latest = builtins.mapAttrs newestOf (attrIndex // fastIndex);

      # The newest indexed revision, as fakes. Spelled as the selector it is,
      # so `fast.tip` and `fast.at "tip"` cannot drift apart: one definition,
      # one revision, one key set, one error path.
      #
      # Deliberately NOT keyed off tip-outpaths.json, which is the obvious
      # reading of "tip" and the wrong one. That snapshot is cut at most once
      # a UTC day, while revisions.json advances with every channel bump — see
      # the "Cut the dated data release" step in .github/workflows/update-index.yml,
      # which exits early once the day's tag exists. Keying off it would let
      # `fast.tip.foo` describe an older revision than `tip.foo` for the rest
      # of the day, silently, since nothing in a digest says which revision
      # produced it.
      #
      # Resolving through fastAt costs nothing in honesty, because digests are
      # keyed by (attr, version) rather than by revision: an attribute the
      # newer bumps did not touch still hits the snapshot's digest and stays
      # bit-exact, and one they did touch misses and lands on fastMissing,
      # loudly, naming the eval selector. A stale pin therefore costs the fast
      # path for the handful of versions that moved since the cut, which is
      # what a fast path is allowed to cost — never a wrong answer.
      tip = fastAt "tip";

      # The selector form: fast.at "2022-03-15", fast.at "dc460ec76cbf".
      at = fastAt;
    };
}

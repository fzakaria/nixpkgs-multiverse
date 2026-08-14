{
  description = "Every nixpkgs revision, reachable from a single evaluation";

  # Deliberately contains no nixpkgs revisions.
  #
  # It is tempting to declare each indexed revision as a flake input. Do not:
  # flake inputs are fetched EAGERLY. Measured on this repo, a flake with three
  # nixpkgs inputs whose output referenced only the first still materialised all
  # three (~378 MB of store each). At 13 revisions that is ~4.9 GB fetched
  # before any evaluation can begin, and it grows linearly with every revision
  # added — which would defeat the entire point of a multiverse.
  #
  # Revisions are instead fetched lazily from index/versions.json via
  # builtins.fetchTree, so only the revisions actually touched are ever
  # materialised, and the number of indexed revisions can grow without bound.
  #
  # flake-schemas is the sole input: it supplies the standard schemas alongside
  # the custom multiverse schema below, and contains no nixpkgs input of its own.
  inputs.flake-schemas.url = "github:DeterminateSystems/flake-schemas";

  outputs =
    { self, flake-schemas, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # nixpkgs' lib is not available here — the whole point is that this flake
      # has no inputs — so genAttrs is spelled out with builtins.
      forAllSystems =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) systems
        );

      # The dev shell and the tool wrappers are built out of a multiverse
      # revision. That keeps `inputs = { }` intact: nothing is fetched unless
      # somebody actually asks for a shell or runs a tool.
      #
      # The newest *release* rather than `tip`, for two reasons. Bash and python
      # from last Tuesday's channel bump are no better than bash and python from
      # the release, and pinning to something that moves twice a year means the
      # hourly update job reuses one closure instead of building a fresh one
      # every time nixos-unstable advances.
      pkgsFor =
        system:
        let
          mv = import ./multiverse.nix { inherit system; };
        in
        mv.at (builtins.elemAt mv.releases (builtins.length mv.releases - 1));

      # What tools/*.sh reach for. `bash` is in the list because the scripts use
      # `mapfile`, which is bash 4+ — the bash 3.2 macOS still ships fails on it.
      #
      # `nix` is deliberately absent: the scripts call `nix hash path` and
      # `nix-instantiate` against the caller's own store, so the host's nix is
      # the correct one to use.
      toolDeps = pkgs: [
        pkgs.bash
        pkgs.python3
        pkgs.gitMinimal
        pkgs.gnutar
        pkgs.gnugrep
        pkgs.coreutils
      ];

      # `nix run` executes a copy of tools/ out of the store, but every script
      # rewrites revisions.json and index/ in place, so they need a checkout to
      # act on. The wrapper hands the caller's directory over as
      # MULTIVERSE_ROOT and refuses to guess when it is not a checkout.
      wrapTool =
        pkgs: name:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = toolDeps pkgs;
          text = ''
            if [ ! -f "$PWD/revisions.json" ]; then
              echo "${name}: run this from a nixpkgs-multiverse checkout (no revisions.json in $PWD)" >&2
              exit 1
            fi
            export MULTIVERSE_ROOT="$PWD"
            exec bash ${./tools}/${name}.sh "$@"
          '';
        };

      # The database `mvs` reads: revisions.json, releases.json and
      # index/history.json projected into SQLite, one row per run.
      #
      # Derived at build time and never committed. It is binary, it would change
      # every time the hourly job lands a revision, and a committed copy could
      # sit beside JSON it no longer matches. Building it here means the data
      # version *is* the flake version: a newer index arrives through
      # `nix flake update multiverse` and rewraps the binary.
      #
      # $out is the file itself rather than a directory holding it, so
      # `nix build .#index-db` leaves a ./result you can hand straight to
      # sqlite3 — 13 years of nixpkgs, queryable with SQL.
      indexDbFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.runCommand "multiverse.db"
          {
            nativeBuildInputs = [ pkgs.python3 ];

            # Names the checkout the data came from, so a database found on its
            # own can be traced back. A dirty tree has nothing honest to say.
            MVS_BUILT_FROM = self.rev or "";
          }
          ''
            # build-db.py takes a checkout root; the store paths are individual
            # files, so assemble the layout it expects.
            root=$(mktemp -d)
            mkdir -p "$root/index"
            cp ${./revisions.json} "$root/revisions.json"
            cp ${./releases.json} "$root/releases.json"
            cp ${./index/history.json} "$root/index/history.json"

            python3 ${./mvs/build-db.py} "$root" $out
          '';

      # `mvs`, the consumer tool: read the index without materialising anything.
      #
      # The binary is wrapped with MVS_DB pointing at the database built above,
      # which is what makes the data version *be* the flake version. There is
      # no download path and no cache directory on purpose — a second source of
      # truth would drift from the pinned input, and two people running the same
      # `nix run` would get different answers.
      #
      # Built from `pkgsFor system` — itself a multiverse revision — so
      # `inputs = { }` stays intact.
      mvsFor =
        system:
        let
          pkgs = pkgsFor system;

          unwrapped = pkgs.rustPlatform.buildRustPackage {
            pname = "mvs";
            version = "0.1.0";
            src = ./mvs;
            cargoLock.lockFile = ./mvs/Cargo.lock;

            # The unit tests run here. The differential test against
            # builtins.compareVersions cannot: it needs a `nix` to ask, and
            # there is none inside the sandbox, so it skips and CI runs it.
            meta = {
              description = "Read the nixpkgs multiverse index";
              mainProgram = "mvs";
            };
          };
        in
        pkgs.runCommand "mvs"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            inherit (unwrapped) meta;
          }
          ''
            mkdir -p $out/bin
            makeWrapper ${unwrapped}/bin/mvs $out/bin/mvs --set MVS_DB ${indexDbFor system}
          '';

      # The deployable site: the static files from site/ plus the three data
      # files the page fetches at runtime. The data is copied in rather than
      # fetched from raw.githubusercontent.com so that versions.json and
      # revisions.json always deploy atomically — the offsets in one are only
      # valid against the other.
      #
      # app.js is renamed to app.<content-hash>.js and index.html rewritten to
      # match, so the served HTML and script can never be a mismatched pair
      # across deploys, and the script could be cached immutably.
      siteFor =
        system:
        let
          pkgs = pkgsFor system;

          # The commit stamped into the footer. From a clean checkout self.rev
          # names exactly the tree the data files came from; a dirty tree gets
          # dirtyRev; anything else keeps the placeholder and the footer stays
          # hidden.
          commit = self.rev or self.dirtyRev or "__COMMIT__";

          # Both index files leave whatever is current at the newest revision
          # they cover open-ended — a null offset in versions.json, a run ending
          # in null in history.json — so that appending a revision does not
          # rewrite every entry that did not change. See "the open tip" in
          # docs/design.md.
          #
          # The browser is never told about that. This runs first and everything
          # downstream — the shards, the sitemap, the whole-file copy — reads
          # what it writes, so the encoding is known in exactly one place on
          # this side and app.js only ever sees plain offsets.
          closeTip = pkgs.writeText "close-tip.py" ''
            import json, sys

            src, dest = sys.argv[1:3]
            data = json.load(open(src))

            # Against the file's own count, never len(revisions): between an
            # append and the indexing run that catches up to it, the newest
            # revision is one this file has never looked at.
            tip = data["revisionCount"] - 1

            def close(value):
                if value is None:                       # versions.json offset
                    return tip
                if isinstance(value, list):             # history.json run(s)
                    if value and isinstance(value[0], list):
                        return [close(run) for run in value]
                    first, last = value
                    return [first, tip if last is None else last]
                return value

            data["attrs"] = {
                attr: {v: close(value) for v, value in vers.items()}
                for attr, vers in data["attrs"].items()
            }
            json.dump(data, open(dest, "w"), separators=(",", ":"), sort_keys=True)
          '';

          # An {"attrs": {...}} file split by the first two characters of the
          # attribute name, so a package page fetches only the shard holding
          # the one attribute it is about. history.json and versions.json have
          # the same shape and both go through here.
          #
          # A timeline needs the history of exactly one attribute, and a
          # version table needs the versions of exactly one attribute; serving
          # either whole file to render one package would cost more than every
          # other request on the page combined. Two characters puts the median
          # history shard at 2 KB and the median versions shard at 1.4 KB.
          #
          # Build artifacts rather than committed data: the repo keeps the two
          # files multiverse.nix reads, and the deploy gets the pieces. That
          # also means the split can be retuned without a data commit.
          shardByAttr = pkgs.writeText "shard-by-attr.py" ''
            import json, os, sys

            src, dest = sys.argv[1:3]
            data = json.load(open(src))
            os.makedirs(dest, exist_ok=True)

            # Everything that is not the per-attribute map is small and gets
            # copied into every shard, so a shard stands on its own.
            common = {k: v for k, v in data.items() if k != "attrs"}

            buckets = {}
            for attr, vers in data["attrs"].items():
                # Anything not alphanumeric folds to _, so the shard name is
                # always a safe filename and the site can compute it with the
                # same one-liner.
                key = "".join(c if c.isalnum() else "_" for c in attr[:2].lower()) or "_"
                buckets.setdefault(key, {})[attr] = vers

            for key, attrs in buckets.items():
                json.dump(
                    {**common, "attrs": attrs},
                    open(os.path.join(dest, key + ".json"), "w"),
                    separators=(",", ":"),
                    sort_keys=True,
                )
            print(f"sharded {len(data['attrs'])} attrs into {len(buckets)} files")
          '';

          # Every attribute name and how many versions it has: 486 KB against
          # versions.json's 5.3 MB, and all the search box ever reads. The
          # search box is the landing page, so this one loads at boot — the
          # shards above cover everything after a package is chosen.
          attrNames = pkgs.writeText "attr-names.py" ''
            import json, sys

            src, dest = sys.argv[1:3]
            index = json.load(open(src))
            json.dump(
                {"attrs": {a: len(v) for a, v in index["attrs"].items()}},
                open(dest, "w"),
                separators=(",", ":"),
                sort_keys=True,
            )
          '';

          # Where the site is served from. site/index.html states the same
          # origin in its canonical link and site/app.js in SITE_ORIGIN;
          # a sitemap has to name absolute URLs, so this is the third.
          siteOrigin = "https://nixmultiverse.com";

          # How many package URLs the sitemap offers. Every attribute is a
          # real page and could be listed — 31,798 fits inside the 50,000-URL
          # limit — but nothing here is prerendered, so whether one gets
          # indexed depends on Google choosing to run its JavaScript. Offering
          # a slice first makes that measurable in Search Console: if most of
          # these land, raise the number; if almost none do, the answer is
          # prerendering, not more URLs.
          #
          # The slice is the attributes with the most versions, as the closest
          # thing to a popularity signal the index holds.
          sitemapPackages = 2000;

          # The URLs worth offering a crawler, as sitemaps.org XML.
          #
          # Revisions are deliberately absent. There are 1,538 of them, each
          # page a list of what a commit pinned, and they are the one corner
          # of the site that reads as bulk near-duplicate pages rather than as
          # something a person searched for.
          sitemap = pkgs.writeText "sitemap.py" ''
            import json, os, sys
            from urllib.parse import quote
            from xml.sax.saxutils import escape

            (
                origin, versions_src, revisions_src, releases_src, docs_dir, dest, limit
            ) = sys.argv[1:8]
            limit = int(limit)

            versions = json.load(open(versions_src))["attrs"]
            revisions = json.load(open(revisions_src))
            releases = json.load(open(releases_src))

            # The index is only as fresh as its newest revision, which is what
            # every page not about one package or one release last changed on.
            newest = revisions[-1]["date"]

            urls = [("/", newest)]
            for view in ("revisions", "releases", "stats"):
                urls.append((f"/?view={view}", newest))

            # The documentation. Worth listing ahead of any package page: it is
            # the only prerendered prose on the site — every other URL here is
            # an empty shell that JavaScript fills in from JSON — so it is the
            # one part a crawler can read without choosing to run anything.
            #
            # No lastmod, deliberately. Nothing in this build knows when a docs
            # page last changed; `newest` is the wrong answer, because the docs
            # do not move when the channel does, and a lastmod that lies every
            # hour is worse than none at all.
            # Offered without the `.html` the file on disk carries, matching
            # the links the pages use and the URL a reader would type. Listing
            # what is actually in the directory is what keeps this in step
            # with whatever render-docs.py produced.
            docs = sorted(f for f in os.listdir(docs_dir) if f.endswith(".html"))
            urls.append(("/docs/", None))
            for page in docs:
                if page != "index.html":
                    urls.append((f"/docs/{page[:-5]}", None))

            for name, r in releases.items():
                urls.append(
                    (f"/?view=releases&release={quote(name, safe=''')}", r["date"])
                )

            # A package's lastmod is the date of the newest revision shipping
            # any of its versions: the last time the page's content changed.
            # Truthful per-URL dates are what let a crawler skip the 20,000
            # packages that have not moved in years.
            ranked = sorted(versions.items(), key=lambda kv: (-len(kv[1]), kv[0]))
            for attr, vers in ranked[:limit]:
                # quote() with no safe characters, so the one attribute named
                # with a "+" survives: a bare + in a query string is a space.
                urls.append(
                    (
                        f"/?pkg={quote(attr, safe=''')}",
                        revisions[max(vers.values())]["date"],
                    )
                )

            with open(dest, "w") as out:
                out.write('<?xml version="1.0" encoding="UTF-8"?>\n')
                out.write(
                    "<!-- Generated by the site build. "
                    f"{len(ranked[:limit])} of {len(ranked)} packages, "
                    "the ones with the most versions. -->\n"
                )
                out.write(
                    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                )
                for path, lastmod in urls:
                    loc = escape(origin + path)
                    mod = f"<lastmod>{lastmod}</lastmod>" if lastmod else ""
                    out.write(f"<url><loc>{loc}</loc>{mod}</url>\n")
                out.write("</urlset>\n")

            print(
                f"sitemap: {len(urls)} urls "
                f"({len(docs)} docs, {len(ranked) - limit} packages left out)"
            )
          '';
        in
        pkgs.runCommand "nixpkgs-multiverse-site"
          {
            nativeBuildInputs = [
              # pygments highlights the docs' code blocks at build time, which
              # is what keeps a highlighter and its CDN out of the pages
              # themselves. The other scripts here need plain python3, and one
              # interpreter serves both.
              (pkgs.python3.withPackages (ps: [ ps.pygments ]))
              pkgs.cmark-gfm
            ];
          }
          ''
            mkdir -p $out
            cp ${./site}/* $out/
            cp ${./revisions.json} $out/revisions.json
            cp ${./releases.json} $out/releases.json
            cp ${./index/stats.json} $out/stats.json

            # The open tip closed once, before anything below reads either
            # file — see closeTip. Everything downstream takes these, not the
            # committed originals.
            python3 ${closeTip} ${./index/versions.json} versions.json
            python3 ${closeTip} ${./index/history.json} history.json

            python3 ${shardByAttr} history.json $out/history
            python3 ${shardByAttr} versions.json $out/versions
            python3 ${attrNames} versions.json $out/names.json

            # docs/*.md rendered to /docs/*.html. The same markdown is what
            # GitHub shows in the repository, so the two never disagree.
            python3 ${./tools/render-docs.py} \
              ${pkgs.cmark-gfm}/bin/cmark-gfm ${./docs} $out/docs \
              ${siteOrigin} "${commit}" "$out"

            # site/robots.txt, copied in above, points a crawler at this. Runs
            # after the docs are rendered: it lists what was actually written
            # to $out/docs rather than a second copy of the page list.
            python3 ${sitemap} ${siteOrigin} versions.json \
              ${./revisions.json} ${./releases.json} $out/docs $out/sitemap.xml \
              ${toString sitemapPackages}

            # The whole index, which only the revisions tab needs: "what is
            # pinned at this revision" is a question about every attribute at
            # once, and no shard can answer it. Fetched when a revision row is
            # opened, never at boot.
            cp versions.json $out/versions.json

            # The social-card image the og:/twitter: meta tags point at.
            cp ${./multiverse_lotr.jpg} $out/multiverse_lotr.jpg

            chmod -R u+w $out
            substituteInPlace $out/app.js --replace-quiet "__COMMIT__" "${commit}"

            # The output path is known before building, so the page can name
            # the very store path it is served out of (a benign self-reference).
            substituteInPlace $out/app.js --replace-fail "__STORE_PATH__" "$out"

            hash=$(sha256sum $out/app.js | cut -c1-12)
            mv $out/app.js "$out/app.$hash.js"
            substituteInPlace $out/index.html --replace-fail "app.js" "app.$hash.js"
          '';

      # The scripts behind `nix run .#<tool>`, each with the description its
      # app surfaces through `nix flake show` and `nix flake check`.
      tools = {
        build-index = "Build index/versions.json (and narHashes) from revisions.json";
        build-history = "Build index/history.json (version lifetimes) from the extraction cache";
        build-stats = "Build index/stats.json (the aggregates the site's charts draw) from index/history.json";
        fetch-unstable-revisions = "Append new nixos-unstable channel bumps to revisions.json";
        fetch-releases = "Refresh releases.json with the current tip of every release channel";
        add-narhashes = "Fill in narHash for revisions that lack one";
        update-readme-status = "Rewrite the status block at the top of README.md";
      };

      # Flake schema to display the custom multiverse output. The inventory
      # deliberately stops at the API's immediate children: walking into
      # `tip`, `versions`, or `installables` would materialise revisions merely
      # to run `nix flake show`, defeating the API's lazy-fetch design.
      multiverseSchema = {
        version = 1;
        doc = ''
          The `multiverse` output provides the nixpkgs revision and package
          version index for each supported system.
        '';
        inventory =
          output:
          let
            what = {
              at = "Nixpkgs package set selector";
              daysBehind = "Nixpkgs soak-period selector";
              flakeAt = "Nixpkgs flake selector";
              goneSince = "package disappearance lookup";
              history = "package version history index";
              historyOf = "package version history lookup";
              index = "package version index";
              installables = "Nixpkgs installables by revision";
              latest = "latest package versions";
              lifetimeOf = "package version lifetime lookup";
              lockVersion = "multiverse lock format version";
              readLock = "multiverse lock reader";
              releaseTips = "Nixpkgs release tips";
              releases = "Nixpkgs releases";
              revOf = "package version revision lookup";
              revs = "indexed Nixpkgs revision labels";
              revisions = "indexed Nixpkgs revisions";
              skippedRevisions = "skipped Nixpkgs revisions";
              tip = "latest indexed Nixpkgs package set";
              version = "package version selector";
              versionAt = "package version-at-revision lookup";
              versions = "packages by version";
              versionsOf = "package versions lookup";
            };
          in
          {
            children = builtins.mapAttrs (system: api: {
              forSystems = [ system ];
              children = builtins.mapAttrs (name: _: {
                what = what.${name} or "multiverse API value";
              }) api;
            }) output;
          };
      };
    in
    {
      # The multiverse API, per system.
      #   nix eval .#multiverse.x86_64-linux.versionsOf --apply 'f: f "python3"'
      multiverse = forAllSystems (system: import ./multiverse.nix { inherit system; });

      # Retain the standard schemas for the outputs this flake actually exposes
      # and add the project-specific one. home-manager's conventional output
      # name differs from the schema's, but its module shape is the same.
      schemas = {
        inherit (flake-schemas.exportedSchemas)
          apps
          checks
          darwinModules
          devShells
          exportedSchemas
          formatter
          legacyPackages
          nixosModules
          packages
          schemas
          ;
        homeManagerModules = flake-schemas.exportedSchemas.homeModules;
        multiverse = multiverseSchema;
      };
      exportedSchemas.multiverse = multiverseSchema;

      lib = {
        # `mkMultiverse` for callers who need to pass config/overlays through.
        mkMultiverse = args: import ./multiverse.nix args;

        # A `multiverse.lock` written by `mvs lock`, resolved to derivations:
        #
        #   multiverse.lib.readLock { system = "x86_64-linux"; file = ./multiverse.lock; }
        #   => { helix = <derivation>; ripgrep = <derivation>; }
        #
        # The same function `multiverse.<system>.readLock` exposes, taking the
        # system as an argument for callers who are outside a per-system scope
        # — a home-manager module reading a lock beside its flake, typically.
        readLock =
          {
            system,
            file,
            config ? { },
            overlays ? [ ],
          }:
          (import ./multiverse.nix { inherit system config overlays; }).readLock file;

        # An overlay that rewrites `pkgs.<attr>` to a pinned version, for the
        # cases the modules deliberately do not cover: making every *other*
        # module see the pin, so that `programs.<name>.package` and friends pick
        # it up without being named individually.
        #
        # Handed out rather than set from inside the modules, because
        # `nixpkgs.overlays` is discarded wherever home-manager runs with
        # `useGlobalPkgs = true` — applying it is the caller's job, at the layer
        # that honours it. See the comment at the top of modules/multiverse.nix.
        #
        # The system comes off `final` rather than being an argument: reading it
        # from the package set being extended is what keeps this usable inside
        # `nixpkgs.overlays` without a second source of truth for the platform.
        pinOverlay =
          {
            pins,
            config ? { },
            overlays ? [ ],
          }:
          final: _prev:
          let
            mv = import ./multiverse.nix {
              system = final.stdenv.hostPlatform.system;
              inherit config overlays;
            };
          in
          builtins.mapAttrs (attr: version: mv.version attr version) pins;
      };

      # One shared core, two entry points. The wrappers differ only in which
      # package list they append to; see modules/multiverse.nix for why neither
      # of them goes anywhere near `nixpkgs.overlays`.
      nixosModules = rec {
        multiverse = ./modules/nixos.nix;
        default = multiverse;
      };

      homeManagerModules = rec {
        multiverse = ./modules/home-manager.nix;
        default = multiverse;
      };

      # `nix build .#site` assembles the exact tree the pages workflow
      # deploys; `nix run .#serve` (below, in apps) serves it for testing.
      packages = forAllSystems (system: rec {
        site = siteFor system;
        mvs = mvsFor system;
        index-db = indexDbFor system;
        default = site;
      });

      # legacyPackages is the conventional escape hatch for a non-flat package
      # set, which is exactly what a multiverse is. The demo rides here rather
      # than in `packages` because `nix flake check` evaluates every package,
      # and evaluating every-python means fetching the ~60 revisions it draws
      # from — legacyPackages is the one output flake check never enumerates.
      # `nix build .#every-python` resolves identically from either output.
      #
      # `installables` merges in the exact-match revision keys, which is what
      # makes `nix run .#25.05.python3` and `nix run .#<commit>.python3` work
      # as plain attrpaths. Collision-free: every key starts with a digit and
      # nothing in the API does.
      legacyPackages = forAllSystems (
        system:
        let
          mv = import ./multiverse.nix { inherit system; };
        in
        mv
        // mv.installables
        // {
          every-python = import ./demos/every-python.nix { inherit system; };
        }
      );

      # `nix flake check` runs the test suite. The eval tests return a small
      # summary attrset only after their assertions hold, so serialising the
      # summary into a derivation makes *evaluation* the test — the build step
      # just writes it out. compose is a real build: three Pythons from three
      # revisions in one buildEnv.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          evalTest =
            name: file:
            pkgs.runCommand name {
              summary = builtins.toJSON (import file { inherit system; });
            } ''echo "$summary" > $out'';
        in
        {
          index = evalTest "test-index" ./tests/index.nix;
          flake-at = evalTest "test-flake-at" ./tests/flake-at.nix;
          installables = evalTest "test-installables" ./tests/installables.nix;
          module = evalTest "test-module" ./tests/module.nix;
          history = evalTest "test-history" ./tests/history.nix;
          lock = evalTest "test-lock" ./tests/lock.nix;
          compose = (import ./tests/compose.nix { inherit system; }).env;

          # Every in-repository markdown link, against the headings that
          # actually exist. Both renderers — GitHub and tools/render-docs.py —
          # derive anchors from heading text, so renaming a heading breaks
          # links in both and neither says so: the browser just scrolls to the
          # top. The tree is reassembled here because the checker resolves
          # `../` links relative to the file holding them.
          docs-links = pkgs.runCommand "check-docs-links" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            mkdir -p repo/docs repo/.github/workflows
            cp ${./README.md} repo/README.md
            cp ${./LICENSE} repo/LICENSE
            cp ${./multiverse_lotr.jpg} repo/multiverse_lotr.jpg
            cp ${./docs}/*.md repo/docs/
            cp ${./.github/workflows}/*.yml repo/.github/workflows/
            cd repo
            python3 ${./tools/check-links.py} README.md docs/*.md | tee $out
          '';
        }
      );

      # `nix fmt`. The tree wrapper rather than bare `nixfmt`, which now
      # deprecates being handed a directory and formats stdin when `nix fmt` is
      # called with no paths at all. Extended with prettier so the site's
      # html/css/js is held to a formatter too, not just the Nix code.
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.nixfmt-tree.override {
          runtimeInputs = [
            pkgs.prettier
            pkgs.rustfmt
          ];
          settings = {
            # mvs/ is Rust, and holding it to `nix fmt` too means CI's one
            # formatting step covers every language in the tree.
            formatter.rustfmt = {
              command = "rustfmt";
              options = [
                "--edition"
                "2021"
              ];
              includes = [ "*.rs" ];
            };
            formatter.prettier = {
              command = "prettier";
              options = [ "--write" ];
              includes = [
                "*.css"
                "*.js"
              ];
            };
            # HTML separately: the default whitespace-sensitive mode emits
            # `></a\n>` gymnastics to keep inline spacing byte-identical.
            # This page keeps its inline spacing in text nodes, so the
            # insensitive mode is safe and far more readable.
            formatter.prettier-html = {
              command = "prettier";
              options = [
                "--write"
                "--html-whitespace-sensitivity"
                "ignore"
                "--print-width"
                "100"
              ];
              includes = [ "*.html" ];
            };
          };
        }
      );

      # Everything tools/*.sh needs, so `tools/build-index.sh` runs the same way
      # on any host — including the bash 4+ the scripts assume.
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShellNoCC { packages = toolDeps pkgs; };

          # `nix develop .#mvs -c cargo test` — the crate's own toolchain, with
          # MVS_DB already pointing at a built database so the tests have an
          # index to read without one being wired up by hand.
          #
          # The differential test against builtins.compareVersions runs from
          # here rather than from `nix flake check`: it needs a `nix` to ask,
          # and the build sandbox has none, so it skips there and CI runs it.
          mvs = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
            ];
            MVS_DB = indexDbFor system;
          };
        }
      );

      # The same tools without entering a shell first:
      #   nix run .#build-index -- -n 30
      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        builtins.mapAttrs (name: description: {
          type = "app";
          program = "${wrapTool pkgs name}/bin/${name}";
          meta = { inherit description; };
        }) tools
        // {
          # `nix run .#mvs -- query versions python3`
          mvs = {
            type = "app";
            program = "${mvsFor system}/bin/mvs";
            meta.description = "Read the nixpkgs multiverse index";
          };

          # `nix run .#serve [port]` — the built site on a local port.
          #
          # Not a bare `python -m http.server`: every file in a store output
          # carries the epoch as its mtime, so If-Modified-Since would 304 a
          # file from a *previous* build — the browser then shows a stale site
          # across rebuilds no matter what changed. Ignore conditional
          # requests and forbid caching outright; this server exists only for
          # testing. (GitHub Pages serves real validators, so the deployed
          # site is unaffected.)
          serve =
            let
              script = pkgs.writeText "serve-site.py" ''
                import functools
                import http.server
                import os
                import sys

                class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
                    def send_head(self):
                        del self.headers["If-Modified-Since"]
                        del self.headers["If-None-Match"]

                        # GitHub Pages resolves an extensionless request onto
                        # <path>.html, which is how /docs/cli serves cli.html.
                        # Doing the same here is what keeps the docs' own links
                        # working in a local preview: without it they 404 here
                        # and succeed once deployed, which is the worst way
                        # round to find out.
                        path, sep, query = self.path.partition("?")
                        local = self.translate_path(path)
                        if not os.path.exists(local) and os.path.isfile(local + ".html"):
                            self.path = path + ".html" + sep + query

                        return super().send_head()

                    def end_headers(self):
                        self.send_header("Cache-Control", "no-store")
                        super().end_headers()

                port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
                handler = functools.partial(
                    NoCacheHandler, directory=os.environ["SITE_ROOT"]
                )
                # Name the store path being served, so a glance at the
                # terminal settles which build the browser should be showing.
                print(f"serving {os.environ['SITE_ROOT']}", flush=True)
                print(f"     on http://127.0.0.1:{port}", flush=True)
                try:
                    http.server.ThreadingHTTPServer(
                        ("127.0.0.1", port), handler
                    ).serve_forever()
                except KeyboardInterrupt:
                    sys.exit(0)
              '';
            in
            {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "serve-site";
                  runtimeInputs = [ pkgs.python3 ];
                  text = ''
                    SITE_ROOT=${siteFor system} exec python3 ${script} "$@"
                  '';
                }
              }/bin/serve-site";
              meta.description = "Serve the built site locally for testing";
            };
        }
      );
    };
}

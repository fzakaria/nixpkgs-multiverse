# The shared core of the NixOS, nix-darwin, and home-manager modules: every
# option, and the single multiverse the whole module resolves against. The three
# wrappers around this file add exactly one line each — the package list their
# own module system understands.
#
# Nothing here touches `nixpkgs.overlays`, and that is deliberate. Rewriting
# `pkgs.<attr>` through an overlay is the obvious way to expose a pin, and it is
# a trap: home-manager swaps its nixpkgs module for
# `modules/misc/nixpkgs-disabled.nix` when `home-manager.useGlobalPkgs = true`,
# and that variant ignores every `nixpkgs.*` definition while warning about the
# file that set it. A module built on overlays would silently do nothing in the
# most common home-manager deployment there is. Everything below resolves to
# plain derivations, which works for NixOS, nix-darwin, standalone home-manager,
# and home-manager as a submodule with `useGlobalPkgs` either way.
#
# The overlay is still available for callers who genuinely want `pkgs.<attr>`
# rewritten — as `multiverse.lib.pinOverlay`, applied by hand at the layer where
# it is honoured, rather than set from here where it might not be.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.multiverse;

  # One multiverse for the whole module. Revisions are memoised per instance, so
  # sharing it means two pins that resolve to the same revision fetch it once;
  # building a fresh multiverse per pin would fetch it twice.
  mv = import ../multiverse.nix (
    {
      system = pkgs.stdenv.hostPlatform.system;
      inherit (cfg) config overlays;
    }
    # Omitted rather than passed as null, so multiverse.nix keeps its defaults.
    // lib.optionalAttrs (cfg.fetchRevision != null) { inherit (cfg) fetchRevision; }
    // lib.optionalAttrs (cfg.fetchArtifact != null) { inherit (cfg) fetchArtifact; }
  );

  # The type nixpkgs and home-manager both use for `nixpkgs.overlays`, so a list
  # accepted there is accepted here.
  overlayType = lib.mkOptionType {
    name = "nixpkgs-overlay";
    description = "nixpkgs overlay";
    check = builtins.isFunction;
    merge = lib.mergeOneOption;
  };

  # Attributes claimed by more than one of `pins`, `lock` and
  # `cooldown.packages`. Each side resolves to a different derivation exporting
  # the same binaries, so leaving this to build time turns a plain configuration
  # mistake into a file-collision error out of buildEnv.
  pinNames = builtins.attrNames cfg.pins;
  lockNames = builtins.attrNames cfg.locked;
  contested = lib.unique (
    lib.intersectLists pinNames cfg.cooldown.packages
    ++ lib.intersectLists pinNames lockNames
    ++ lib.intersectLists lockNames cfg.cooldown.packages
  );
in
{
  options.multiverse = {
    enable = lib.mkEnableOption "package pinning through nixpkgs-multiverse";

    config = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        allowUnfree = true;
      };
      description = ''
        nixpkgs `config` threaded into every revision this module imports.

        A revision is an ordinary nixpkgs import and does not inherit the
        surrounding system's `nixpkgs.config`, so an unfree pin needs
        `allowUnfree` set here as well as wherever the host set it.
      '';
    };

    overlays = lib.mkOption {
      type = lib.types.listOf overlayType;
      default = [ ];
      description = ''
        Overlays applied to every revision this module imports.

        nixpkgs only grew an `overlays` argument in 17.03. If this is non-empty
        and a pin resolves to a revision older than that, resolving it throws
        rather than silently dropping the overlays.
      '';
    };

    fetchRevision = lib.mkOption {
      type = lib.types.nullOr (lib.types.functionTo lib.types.attrs);
      default = null;
      example = lib.literalExpression ''
        r: builtins.fetchTree {
          type = "tarball";
          url = "https://artifactory.example.org/artifactory/nixpkgs/''${r.rev}.tar.gz";
          inherit (r) narHash;
        }
      '';
      description = ''
        How one nixpkgs revision becomes a tree, for deployments that reach
        GitHub through a mirror. Receives the index record naming the revision
        and returns a `builtins.fetchTree` result.

        Multiverse checks the returned `narHash` against the one recorded for
        that revision, so a mirror must serve byte-identical trees or fail on
        the hash. Release tips carry a recorded hash too, so every selector is
        checked the same way.
      '';
    };

    fetchArtifact = lib.mkOption {
      type = lib.types.nullOr (lib.types.functionTo lib.types.path);
      default = null;
      example = lib.literalExpression ''
        { name, tag, ... }:
        (builtins.fetchTree {
          type = "git";
          url = "https://git.example.org/nixpkgs-multiverse.git";
          ref = tag;
        }).outPath + "/''${name}"
      '';
      description = ''
        How one pinned fast-path artifact becomes a readable path. Receives the
        file `name`, the `tag` and `narHash` data-pins.json holds for it, and
        the canonical `baseUrl`.

        Returning a path rather than fetch arguments is what lets a fetcher pull
        a whole tree and index into it, or hand back a local file and fetch
        nothing. Verification is the fetcher's from here.
      '';
    };

    pins = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          vscode = "1.107.0";
          ripgrep = "13.0.0";
        }
      '';
      description = ''
        Top-level nixpkgs attributes pinned to an exact version, each resolved
        against whichever revision last shipped that version.

        A pin is a derivation from a *different* nixpkgs revision, so it brings
        that revision's closure rather than the running system's — including its
        own libc. That is correct for leaf applications and command-line tools,
        and wrong for anything other packages are meant to link against. It also
        means a pin does not deduplicate against the rest of the system.

        Only top-level attributes work. Nested sets — `python3Packages.*`,
        `nodePackages.*` — are not in the index and cannot be named here.
      '';
    };

    minimize = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Resolve `pins` through the fewest revisions that can serve them, rather
        than each pin through the newest revision shipping its version.

        Cost here is per revision touched, not per package: ten pins on ten
        revisions is ten nixpkgs fetches and ten evaluations, and the same ten
        pins grouped onto two is two. The versions installed are identical
        either way — grouping decides which revision serves a version, never
        which version is served.

        What it does change is which *build* of that version you get. A pin can
        land on an older revision inside its own version's run, so it carries
        that revision's closure: the same package, an older openssl behind it.
        `plan` reports exactly how much older, per pin, before anything is
        built. Set this to false to put every pin back on the newest revision
        shipping it, one fetch each.

        This only ever moves a pin within the run of the version it names, so a
        pin can never come back as a version you did not ask for.
      '';
    };

    lock = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./multiverse.lock";
      description = ''
        A `multiverse.lock` written by `mvs lock`, installed alongside `pins`.

        The difference from `pins` is who maintains it. A pin here is a version
        string somebody typed and has to keep typing; a lock file is a set of
        commits `mvs lock update <attr>` moves one at a time, so updating one
        package cannot drag the others along — which is what a single flake
        input does and why people stop updating at all.

        A lock can never name a revision newer than the multiverse input knows,
        because materialising one needs its narHash. Moving a pin forward is
        therefore two steps, and honestly so: `nix flake update multiverse`,
        then `mvs lock update <attr>`.
      '';
    };

    cooldown = {
      enable = lib.mkEnableOption ''
        a soak period: packages taken from nixos-unstable as it stood some
        number of days ago rather than as it stands now
      '';

      days = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 7;
        description = ''
          How far behind the anchor to reach. The revision used is the newest
          materialisable one at least this many days older than the anchor's
          date.
        '';
      };

      anchor = lib.mkOption {
        type = lib.types.str;
        default = "tip";
        example = "26.05";
        description = ''
          What to measure the soak period back from — any selector `at` accepts:
          `"tip"`, a release such as `"26.05"`, a date, or a commit.

          The walk back always happens along nixos-unstable. An anchor only
          supplies a date, so `anchor = "26.05"` means unstable as it stood N
          days before the 26.05 channel tip, not a walk along release-26.05.
        '';
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "ripgrep"
          "fd"
        ];
        description = ''
          Top-level attributes to install from the soaked revision instead of
          from the running system's nixpkgs.

          This soaks the packages named here, not the system. Soaking a whole
          NixOS configuration is a different operation — it has to happen at the
          flake level, where `nixosSystem` is called; see `flakeAt` in the
          README.
        '';
      };

      pkgs = lib.mkOption {
        type = lib.types.raw;
        readOnly = true;
        default = mv.daysBehind cfg.cooldown.anchor cfg.cooldown.days;
        defaultText = lib.literalExpression "multiverse.daysBehind cooldown.anchor cooldown.days";
        description = ''
          The soaked revision as a whole package set, for reaching things
          `cooldown.packages` cannot name — a `programs.<name>.package`, say.
          Available whether or not `cooldown.enable` is set; forcing anything
          out of it is what materialises the revision.
        '';
      };

      resolved = lib.mkOption {
        type = lib.types.raw;
        readOnly = true;
        default = lib.optionalAttrs cfg.cooldown.enable (
          lib.genAttrs cfg.cooldown.packages (attr: cfg.cooldown.pkgs.${attr})
        );
        defaultText = lib.literalExpression "{ <name> = <derivation>; }";
        description = ''
          `cooldown.packages` resolved against the soaked revision, keyed by
          attribute. Empty unless `cooldown.enable` is set, which is what keeps
          a half-configured cooldown from installing anything.
        '';
      };
    };

    instance = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = mv;
      defaultText = lib.literalExpression "multiverse.lib.mkMultiverse { inherit system; inherit (config.multiverse) config overlays; }";
      description = ''
        The multiverse itself, carrying this module's `config` and `overlays`,
        for everything the options above do not cover — `at`, `versionsOf`,
        `revOf`, `flakeAt`.
      '';
    };

    pinned = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default =
        if cfg.minimize then
          mv.solvePins cfg.pins
        else
          builtins.mapAttrs (attr: version: mv.version attr version) cfg.pins;
      defaultText = lib.literalExpression "{ <name> = <derivation>; }";
      description = ''
        `pins` resolved to derivations, keyed by attribute, so a pin can also be
        handed to an option that takes a package rather than only installed.
      '';
    };

    plan = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = mv.pinPlan cfg.pins;
      defaultText = lib.literalExpression "{ revisions = 2; groups = [ ... ]; certificate = [ ... ]; why = \"...\"; }";
      description = ''
        How `pins` divide across revisions, and the proof that no smaller
        division exists. The same structure `mvs solve --json` prints:
        `revisions` counts them, `groups` says which pin lands where and how
        much older that leaves it, and `certificate` names the pins that make a
        smaller plan impossible, with `why` as the sentence.

        Computed from the index alone, so it is available before anything is
        fetched — which is what makes it usable in an assertion. Demanding that
        every pin share one revision, the strongest form of consistency this
        module can offer, is:

        ```nix
        assertions = [
          {
            assertion = config.multiverse.plan.revisions == 1;
            message = config.multiverse.plan.why;
          }
        ];
        ```

        Reported whether or not `minimize` is set: a plan is a fact about the
        pins, and reading it is how you decide whether to set it.
      '';
    };

    locked = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = if cfg.lock == null then { } else mv.readLock cfg.lock;
      defaultText = lib.literalExpression "{ <name> = <derivation>; }";
      description = ''
        `lock` resolved to derivations, keyed by attribute — the lock file's
        counterpart to `pinned`. Empty when no lock file is set.
      '';
    };

    packages = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default =
        builtins.attrValues cfg.pinned
        ++ builtins.attrValues cfg.locked
        ++ builtins.attrValues cfg.cooldown.resolved;
      defaultText = lib.literalExpression "[ <derivation> ... ]";
      description = ''
        Everything this module installs: every pin, every locked package, plus
        every soaked package when `cooldown.enable` is set. The NixOS,
        nix-darwin, and home-manager wrappers each append this to their own
        package list.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = contested == [ ];
        message = ''
          multiverse: ${lib.concatStringsSep ", " contested} is claimed by more than
          one of `multiverse.pins`, `multiverse.lock` and
          `multiverse.cooldown.packages`. Each would resolve to a different
          derivation of the same package, and they would collide in the same
          package list. Pick one.
        '';
      }
    ];

    warnings = lib.optional (cfg.cooldown.packages != [ ] && !cfg.cooldown.enable) ''
      multiverse: `multiverse.cooldown.packages` is set but
      `multiverse.cooldown.enable` is not, so none of it is installed.
    '';
  };
}

# Tests the NixOS, nix-darwin, and home-manager modules by evaluating them
# through `lib.evalModules` directly:
#
#   nix eval --json -f tests/module.nix --apply 'f: f { }'
#
# All wrappers are exercised against the same core, which is the property that
# matters: an entry point is supposed to add nothing but the package list its
# own module system understands. The nix-darwin wrapper writes the same option
# as the NixOS one, so asserting on both is what catches those two files —
# identical today, see modules/darwin.nix — drifting apart later.
#
# A full nixosSystem is not needed to check that, and would drag in the whole
# NixOS module set. Instead each wrapper is evaluated alongside a stub that
# declares just the option it writes to, plus nixpkgs' own assertions module —
# the same one home-manager pulls in at modules/modules.nix.
{
  system ? builtins.currentSystem,
}:
let
  mv = import ../multiverse.nix { inherit system; };

  # The newest release, for `lib` and for the `pkgs` the core reads its system
  # off. Matching what flake.nix builds its checks from, so this test reuses a
  # revision already on hand rather than materialising another.
  pkgs = mv.at (builtins.elemAt mv.releases (builtins.length mv.releases - 1));
  inherit (pkgs) lib;

  # A pin whose version is old enough to be settled, so the expected value below
  # never has to move: whichever revision last shipped ripgrep 13.0.0 is fixed
  # forever, unlike anything resolved off a channel tip.
  pinnedVersion = "13.0.0";

  # Declares the two options the wrappers write to, so each can be evaluated
  # without the module set that would normally provide them.
  stub =
    { lib, ... }:
    {
      options = {
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.raw;
          default = [ ];
        };
        home.packages = lib.mkOption {
          type = lib.types.listOf lib.types.raw;
          default = [ ];
        };
      };
    };

  eval =
    module: settings:
    (lib.evalModules {
      modules = [
        module
        stub
        (pkgs.path + "/nixos/modules/misc/assertions.nix")
        { multiverse = settings; }
      ];
      specialArgs = { inherit pkgs; };
    }).config;

  # The same settings through both wrappers, since the core is what produces the
  # list and the wrappers only place it.
  settings = {
    enable = true;
    pins.ripgrep = pinnedVersion;
    cooldown = {
      enable = true;
      days = 30;
      packages = [ "fd" ];
    };
  };

  nixos = eval ../modules/nixos.nix settings;
  darwin = eval ../modules/darwin.nix settings;
  home = eval ../modules/home-manager.nix settings;

  # Cooldown left off, to check that `packages` then carries the pin alone.
  pinOnly = eval ../modules/nixos.nix {
    enable = true;
    pins.ripgrep = pinnedVersion;
    cooldown.packages = [ "fd" ];
  };

  # Both sides claiming `fd`, which the core is supposed to reject at eval time
  # rather than leave to a file collision inside buildEnv.
  contested = eval ../modules/nixos.nix {
    enable = true;
    pins.fd = "8.7.0";
    cooldown = {
      enable = true;
      packages = [ "fd" ];
    };
  };

  # A lock file as `mvs lock` writes one, pinning the same ripgrep by commit
  # rather than by version. Built here rather than committed so it never has to
  # be rewritten as the index grows; tests/lock.nix covers readLock itself.
  lockFile = builtins.toFile "multiverse.lock" (
    builtins.toJSON {
      version = 1;
      pins.ripgrep = {
        rev = builtins.substring 11 12 (mv.revOf "ripgrep" pinnedVersion);
        version = pinnedVersion;
      };
    }
  );

  locked = eval ../modules/nixos.nix {
    enable = true;
    lock = lockFile;
  };

  # The same attribute claimed by a version pin and by the lock file, which
  # collides exactly the way `pins` and `cooldown.packages` do.
  contestedLock = eval ../modules/nixos.nix {
    enable = true;
    pins.ripgrep = pinnedVersion;
    lock = lockFile;
  };

  # Two pins that were current together, so minimising puts them on one
  # revision. jq 1.7 outlived ripgrep 13.0.0, so ripgrep forces the revision
  # and the group lands on the one the pin assertions above already
  # materialise — this case costs no extra fetch.
  grouped = eval ../modules/nixos.nix {
    enable = true;
    pins = {
      ripgrep = pinnedVersion;
      jq = "1.7";
    };
  };

  ungrouped = eval ../modules/nixos.nix {
    enable = true;
    minimize = false;
    pins = {
      ripgrep = pinnedVersion;
      jq = "1.7";
    };
  };

  # A fetcher that throws instead of returning a tree: what is under test
  # is whether the option reaches the multiverse the module builds, and throwing
  # when called says so without a byte of network.
  probed = eval ../modules/nixos.nix {
    enable = true;
    pins.ripgrep = pinnedVersion;
    fetchRevision = _r: throw "multiverse-test: fetchRevision reached the module";
  };

  failing = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
in

# Each wrapper writes the core's list to its own option, and to nothing else.
assert builtins.length nixos.multiverse.packages == 2;
assert nixos.environment.systemPackages == nixos.multiverse.packages;
assert nixos.home.packages == [ ];
assert darwin.environment.systemPackages == darwin.multiverse.packages;
assert darwin.home.packages == [ ];
assert home.home.packages == home.multiverse.packages;
assert home.environment.systemPackages == [ ];

# Pins resolve to real derivations, keyed by attribute. This is the one
# assertion that materialises a revision.
assert builtins.attrNames nixos.multiverse.pinned == [ "ripgrep" ];
assert nixos.multiverse.pinned.ripgrep.version == pinnedVersion;

# The same pin, through a module carrying a mirror hook, resolves through the
# hook rather than around it: the module names the arguments it forwards, so a
# hook it was not taught to pass would silently go back to GitHub.
assert !(builtins.tryEval probed.multiverse.pinned.ripgrep.version).success;

# Minimising is on by default, and `plan` says how the pins divide before
# anything is fetched. This pair shares one revision, so the whole set costs
# one nixpkgs rather than two.
assert grouped.multiverse.minimize;
assert grouped.multiverse.plan.revisions == 1;
assert grouped.multiverse.plan.why == "one revision serves every pin";

# The plan is reported whether or not minimising is on: it is a fact about the
# pins, and reading it is how a configuration decides whether to set the flag,
# or asserts that one revision serves everything.
assert ungrouped.multiverse.plan == grouped.multiverse.plan;
assert !ungrouped.multiverse.minimize;

# Grouping moves a pin onto an older revision inside its own version's run,
# and says by how much. Versions are untouched either way, which is the whole
# safety property: minimising changes which build serves a version, never
# which version is served.
assert (builtins.head grouped.multiverse.plan.groups).revision.label == "2023-11-23-5a09cb4b393d";
assert builtins.all (
  p: if p.attr == "ripgrep" then p.movedDays == 0 else p.movedDays > 0
) (builtins.head grouped.multiverse.plan.groups).pins;
assert grouped.multiverse.pinned.jq.version == "1.7";
assert grouped.multiverse.pinned.ripgrep.version == pinnedVersion;

# Cooldown resolves the attributes it was given, and gates on its own `enable`
# rather than on the module's — a half-configured cooldown installs nothing and
# says so.
assert builtins.attrNames nixos.multiverse.cooldown.resolved == [ "fd" ];
assert pinOnly.multiverse.cooldown.resolved == { };
assert builtins.length pinOnly.multiverse.packages == 1;
assert builtins.length pinOnly.warnings == 1;

# An attribute claimed by both `pins` and `cooldown.packages` fails the
# configuration instead of the build.
assert builtins.length (failing contested) == 1;
assert failing nixos == [ ];

# A lock file installs its pins the same way `pins` does, and lands in the same
# package list.
assert builtins.attrNames locked.multiverse.locked == [ "ripgrep" ];
assert locked.multiverse.locked.ripgrep.version == pinnedVersion;
assert locked.environment.systemPackages == builtins.attrValues locked.multiverse.locked;

# A lock file is not set by default, and setting none resolves to no packages
# rather than to an error.
assert nixos.multiverse.locked == { };

# An attribute claimed by both a version pin and the lock file collides in the
# same way, and is caught in the same place.
assert builtins.length (failing contestedLock) == 1;

# The multiverse itself rides along for everything the options do not cover.
assert nixos.multiverse.instance ? at;
assert nixos.multiverse.instance ? versionsOf;

{
  packages = builtins.length nixos.multiverse.packages;
  pinned = builtins.attrNames nixos.multiverse.pinned;
  cooled = builtins.attrNames nixos.multiverse.cooldown.resolved;
  ripgrep = nixos.multiverse.pinned.ripgrep.version;
}

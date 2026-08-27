{
  description = "Every nixpkgs revision, reachable from a single evaluation";

  # Deliberately empty.
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
  inputs = { };

  # Wiring only. Everything this repository builds lives under nix/, reached
  # through the overlay nix/pkgs.nix applies — so a derivation is `pkgs.mvs` or
  # `pkgs.multiverse-site` here, and its definition is one file over there.
  outputs =
    { self, ... }:
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

      # A multiverse release revision carrying this repository's own packages.
      # See nix/pkgs.nix for why it is a release and not the channel tip.
      pkgsFor = system: import ./nix/pkgs.nix { inherit self system; };
    in
    {
      # The multiverse API, per system.
      #   nix eval .#multiverse.x86_64-linux.versionsOf --apply 'f: f "python3"'
      multiverse = forAllSystems (system: import ./multiverse.nix { inherit system; });

      # mkMultiverse, readLock and pinOverlay: the parts of the API that take
      # their system as an argument rather than being indexed by one.
      lib = import ./nix/lib.nix;

      # One shared core, three entry points over two placements. A wrapper adds
      # exactly one line: the package list its own module system understands.
      # NixOS and nix-darwin both spell that list `environment.systemPackages`,
      # so those two wrappers are identical, and stay separate files only so
      # each flake output names the module system it belongs to. See
      # modules/multiverse.nix for why no wrapper goes anywhere near
      # `nixpkgs.overlays`.
      nixosModules = rec {
        multiverse = ./modules/nixos.nix;
        default = multiverse;
      };

      darwinModules = rec {
        multiverse = ./modules/darwin.nix;
        default = multiverse;
      };

      homeManagerModules = rec {
        multiverse = ./modules/home-manager.nix;
        default = multiverse;
      };

      overlays = rec {
        multiverse-packages = import ./nix/overlay.nix { inherit self; };
        default = multiverse-packages;
      };

      # `nix build .#site` assembles the exact tree the pages workflow
      # deploys; `nix run .#serve` serves it for testing.
      #
      # Defined in packages.nix rather than here, because the same three
      # derivations have to be reachable without a flake — `nix-build
      # packages.nix -A mvs` — and one definition serving both roads is what
      # keeps them from drifting. See docs/non-flake.md.
      packages = forAllSystems (system: import ./packages.nix { inherit self system; });

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

      checks = forAllSystems (
        system:
        import ./nix/checks.nix {
          pkgs = pkgsFor system;
          inherit system;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).multiverse-formatter);

      devShells = forAllSystems (system: import ./nix/dev-shells.nix { pkgs = pkgsFor system; });

      apps = forAllSystems (system: import ./nix/apps.nix { pkgs = pkgsFor system; });
    };
}

# Documentation

Every nixpkgs revision, reachable from a single evaluation. These pages cover
the two ways to use the index: as Nix expressions, and as the `mvs` command
line tool.


1. [Design](./design.md) explains why this exists, and why Nix makes it
   possible in the first place.
2. [Selectors](./selectors.md) covers the one vocabulary for naming a
   revision, shared by the Nix API and `mvs`.
3. [The Nix API](./nix-api.md) such as `at`, `daysBehind`, `versionsOf`, version
   history, provenance, and how releases differ from revisions.
4. [The `mvs` CLI](./cli.md) allows querying the index offline, solving one revision for
   several packages, write per-package pins, run a version.
5. [The NixOS and home-manager module](./modules.md) allows pinning individual packages
   from your system configuration.
6. [Replacing several nixpkgs inputs](./flake-inputs.md) allows using the multiverse
   as the `nixpkgs` other flakes see.
7. [Building the index](./building-the-index.md) explains how the data is extracted
   and refreshed.
8. [The store-path index](./store-paths.md) explains how versions are matched
   to cache.nixos.org store paths — the data behind `fast.*`, the census, and
   the site's dependency and liveness views.

The index itself is browsable at <https://nixmultiverse.com/>.

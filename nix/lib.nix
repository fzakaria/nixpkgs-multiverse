# The system-independent half of the flake's API: `multiverse.lib`.
#
# Nothing here touches a package set of its own — each entry imports
# multiverse.nix with whatever system, config and overlays the caller passes —
# so this file is usable from outside any per-system scope.
let
  # The mirror hooks as an import argument set, omitting the ones left null so
  # multiverse.nix falls back to its own defaults. Every entry point here takes
  # both: only mkMultiverse forwards an argument set wholesale, so the rest
  # would otherwise drop a mirror and quietly go back to GitHub.
  mirrorArgs =
    { fetchRevision, fetchArtifact }:
    (if fetchRevision == null then { } else { inherit fetchRevision; })
    // (if fetchArtifact == null then { } else { inherit fetchArtifact; });
in
{
  # `mkMultiverse` for callers who need to pass config/overlays through.
  mkMultiverse = args: import ../multiverse.nix args;

  # A `multiverse.lock` written by `mvs lock`, resolved to derivations:
  #
  #   multiverse.lib.readLock { system = "x86_64-linux"; file = ./multiverse.lock; }
  #   => { helix = <derivation>; ripgrep = <derivation>; }
  #
  # The same function `multiverse.<system>.readLock` exposes, taking the system
  # as an argument for callers who are outside a per-system scope — a
  # home-manager module reading a lock beside its flake, typically.
  readLock =
    {
      system,
      file,
      config ? { },
      overlays ? [ ],
      fetchRevision ? null,
      fetchArtifact ? null,
    }:
    let
      mv = import ../multiverse.nix (
        { inherit system config overlays; } // mirrorArgs { inherit fetchRevision fetchArtifact; }
      );
    in
    mv.readLock file;

  # An overlay that rewrites `pkgs.<attr>` to a pinned version, for the cases the
  # modules deliberately do not cover: making every *other* module see the pin,
  # so that `programs.<name>.package` and friends pick it up without being named
  # individually.
  #
  # Handed out rather than set from inside the modules, because
  # `nixpkgs.overlays` is discarded wherever home-manager runs with
  # `useGlobalPkgs = true` — applying it is the caller's job, at the layer that
  # honours it. See the comment at the top of modules/multiverse.nix.
  #
  # The system comes off `final` rather than being an argument: reading it from
  # the package set being extended is what keeps this usable inside
  # `nixpkgs.overlays` without a second source of truth for the platform.
  #
  # `minimize` matches `multiverse.minimize`, and defaults the same way: the
  # pins are resolved through the fewest revisions that can serve them, since
  # cost is per revision touched and the versions are identical either way.
  # Set it false to put every pin on the newest revision shipping it.
  pinOverlay =
    {
      pins,
      config ? { },
      overlays ? [ ],
      minimize ? true,
      fetchRevision ? null,
      fetchArtifact ? null,
    }:
    final: _prev:
    let
      mv = import ../multiverse.nix (
        {
          system = final.stdenv.hostPlatform.system;
          inherit config overlays;
        }
        // mirrorArgs { inherit fetchRevision fetchArtifact; }
      );
    in
    if minimize then
      mv.solvePins pins
    else
      builtins.mapAttrs (attr: version: mv.version attr version) pins;
}

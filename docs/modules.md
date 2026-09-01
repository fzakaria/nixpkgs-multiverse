# The NixOS, nix-darwin, and home-manager module

`nixosModules.default`, `darwinModules.default`, and `homeManagerModules.default`
share every option below:

```nix
{
  # Use darwinModules.default on nix-darwin or homeManagerModules.default in
  # home-manager.
  imports = [ inputs.multiverse.nixosModules.default ];

  multiverse = {
    enable = true;
    config.allowUnfree = true;

    # Attributes pinned to an exact version, each resolved against whichever
    # revision last shipped it.
    pins = {
      vscode = "1.107.0";
      ripgrep = "13.0.0";
    };

    # The same idea, maintained by `mvs lock` instead of by hand: a set of
    # commits, each moved on its own by `mvs lock update <attr>`.
    lock = ./multiverse.lock;
  };
}
```

Pins are also available as derivations, for options that take a package rather
than installing one:

```nix
programs.vscode.package = config.multiverse.pinned.vscode;
# and, for a lock file, config.multiverse.locked.vscode
```

An attribute claimed by more than one of `pins`, `lock` and
`cooldown.packages` is a configuration error rather than a file collision out
of `buildEnv`: each side would resolve to a different derivation of the same
package.

**Note**: Only indexed attributes work — every top-level one, plus the children
of the few package sets [`nix/nested-sets.nix`](../nix/nested-sets.nix) lists,
named by their path: `jetbrains.idea`. The large sets are deliberately not in
the index, so `python3Packages.*` and `nodePackages.*` cannot be used. See
[building the index](./building-the-index.md#indexing-a-nested-package-set).

### How many nixpkgs your pins cost

Cost is per revision touched, not per package: ten pins landing on ten
revisions is ten nixpkgs fetches and ten evaluations. `multiverse.minimize` is
on by default and resolves the whole set through the fewest revisions that can
serve it, which is often one or two.

The versions installed are identical either way — minimising decides which
revision serves a version, never which version is served, and a pin can never
leave the run of the version it names. What it does change is which _build_ of
that version you get: a pin can land on an older revision inside its run, and
so carries that revision's closure. Set `minimize = false` to put every pin
back on the newest revision shipping it, one fetch each.

`multiverse.plan` reports the division, and is computed from the index without
fetching anything — so it is available to an assertion:

```nix
{
  multiverse.pins = {
    python3 = "3.8.9";
    nodejs = "14.17.3";
  };

  # These two must come out of the same nixpkgs, or fail the build.
  assertions = [
    {
      assertion = config.multiverse.plan.revisions == 1;
      message = config.multiverse.plan.why;
    }
  ];
}
```

`plan.groups` says which pin lands where and how much older that leaves it, in
days and in revisions. `plan.certificate` names the pins that make a smaller
plan impossible. It is the same structure `mvs solve --json` prints — see
[Minimising](./design.md#minimising).

## Cooldown

A soak period, as a module option. `days` behind `anchor`, along nixos-unstable,
using the same machinery as [`daysBehind`](./nix-api.md#a-soak-period):

```nix
multiverse = {
  enable = true;
  cooldown = {
    enable = true;
    days = 7;
    # any selector `at` takes
    anchor = "tip";
    packages = [ "ripgrep" "fd" ];
  };
};
```

This soaks the packages you name, not the system. The whole soaked revision is
available as a package set for anything the list cannot express:

```nix
programs.neovim.package = config.multiverse.cooldown.pkgs.neovim;
```

Soaking an entire NixOS configuration is a different operation and has to happen
at the flake level, where `nixosSystem` is called, see
[`flakeAt`](./flake-inputs.md#what-about-inputsnixpkgsfollows).

An attribute claimed by both `pins` and `cooldown.packages` fails the
configuration rather than colliding at build time.

## Reaching the rest of the API

`config.multiverse.instance` is a full multiverse carrying the module's `config`
and `overlays`, for everything the options do not cover:

```nix
environment.systemPackages = [
  (config.multiverse.instance.at "24.11").ghc
];
```

## Rewriting `pkgs.<attr>` instead

The module installs derivations; it never touches `nixpkgs.overlays`. That is
deliberate since home-manager discards every `nixpkgs.*` definition when
`home-manager.useGlobalPkgs = true`, so a module that set overlays would
silently do nothing in the most common home-manager deployment.

If you want a pin to be visible to _every_ other module, apply the overlay
yourself, at the layer that honours it:

```nix
nixpkgs.overlays = [
  (inputs.multiverse.lib.pinOverlay {
    pins.vscode = "1.107.0";
    config.allowUnfree = true;
  })
];
```

Now `pkgs.vscode` is 1.107.0 everywhere, and anything reading it — including
other modules' `package` defaults — picks it up.

`pinOverlay` minimises its pins the same way and by the same default as
`multiverse.minimize`, and takes `minimize = false` to turn it off, so moving a
set of pins from the module to the overlay does not quietly change what it
costs.

## Without the module

`mkMultiverse` in an overlay works too, if you would rather have the whole API
hanging off `pkgs`:

```nix
nixpkgs.overlays = [
  (final: prev: {
    mv = inputs.multiverse.lib.mkMultiverse {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
      overlays = [
        # whatever overlays you want to apply to every revision
      ];
    };
  })
];

# ...then, in any module
environment.systemPackages = [ pkgs.mv.versions.vscode."1.107.0" ];
```

Same caveat as above: this sets `nixpkgs.overlays`, so it is a NixOS-level or
standalone-home-manager pattern, not one to reach for under `useGlobalPkgs`.

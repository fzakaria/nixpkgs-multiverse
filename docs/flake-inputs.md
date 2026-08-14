# Replacing several nixpkgs inputs

A flake that pins two channels to get two package sets:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
};
```

becomes one nixpkgs plus multiverse:

```nix
{
  inputs = {
    # Keep exactly one nixpkgs. It is what `follows` resolves to and where the
    # module system gets its `lib`; see the next section.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    multiverse.url = "github:fzakaria/nixpkgs-multiverse";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, multiverse, home-manager, ... }:
    let
      system = "x86_64-linux";
      mv = multiverse.multiverse.${system};
    in
    {
      # ...
    };
}
```

Every use of the second input has a replacement that costs nothing until it is
forced:

| before | after |
|---|---|
| `nixpkgs-unstable.legacyPackages.${system}.ripgrep` | `mv.tip.ripgrep` |
| a second input pinned to another release | `mv.at "24.11"` |
| a third input pinned to a commit for one package | `mv.version "ripgrep" "13.0.0"` |
| a pin nobody remembers the reason for | `mv.at "2022-03-15"` |

## What about `inputs.nixpkgs.follows`?

You must still keep **one** real `nixpkgs` input and follow that.

`follows` rewires one flake input to another *flake input*, and the target has to be shaped like nixpkgs. home-manager's own `flake.nix` evaluates `nixpkgs.lib` and `nixpkgs.legacyPackages.${system}` while producing its outputs.

`nixpkgs-multiverse.legacyPackages.${system}` is the multiverse API, not a package set.

```nix
# does not work
home-manager.inputs.nixpkgs.follows = "multiverse";
```

To build the home-manager configuration itself out of a multiverse revision you can wire it through `pkgs`:

```nix
home-manager.lib.homeManagerConfiguration {
  pkgs = mv.at "26.05"; # or mv.tip, or mv.at "2026-03-01"
  modules = [ ./home.nix ];
}
```

For a nix-darwin configuration, you can also wire it through `pkgs`:

```nix
nix-darwin.lib.darwinSystem {
  pkgs = mv.at "26.05"; # or mv.tip, or mv.at "2026-03-01"
  modules = [ ./configuration.nix ];
}
```

NixOS needs one more step: `nixosSystem` lives on the nixpkgs *flake*, a
package set's `lib` does not have it, so build the system from `flakeAt`:

```nix
(mv.flakeAt "26.05").lib.nixosSystem {
  system = "x86_64-linux";
  modules = [ ./configuration.nix ];
}
```

## Pinning another flake's nixpkgs

A transitive input can be pinned without adding a top-level nixpkgs input:

```nix
inputs.home-manager.inputs.nixpkgs.url = "github:NixOS/nixpkgs/73ad5f9e147c0d2a2061f1d4bd91e05078dc0b58";
```

The lock machinery only takes concrete refs, but the commit behind any
multiverse selector is one `nix eval` away, off the provenance tag:

```console
$ nix eval --raw 'github:fzakaria/nixpkgs-multiverse#multiverse.x86_64-linux' \
    --apply 'mv: (mv.at "2022-03-15").multiverse.rev'
73ad5f9e147c0d2a2061f1d4bd91e05078dc0b58
```

Any selector `at` takes works. Answering fetches that one tree (nothing is
built); a release tip comes straight off the table and fetches nothing:

```console
$ nix eval --raw 'github:fzakaria/nixpkgs-multiverse#multiverse.x86_64-linux.releaseTips."26.05".rev'
fcb8fcd6bf2d0adecae5bd491afaaaf8311b758d
```

To pin whatever revision ships a specific package version, `revOf` names it,
and the label it returns is itself a selector, so it feeds straight back into
`at`:

```console
$ nix eval --raw 'github:fzakaria/nixpkgs-multiverse#multiverse.x86_64-linux' \
    --apply 'mv: mv.revOf "python3" "3.8.9"'
2021-07-18-967d40bec14b

$ nix eval --raw 'github:fzakaria/nixpkgs-multiverse#multiverse.x86_64-linux' \
    --apply 'mv: (mv.at (mv.revOf "python3" "3.8.9")).multiverse.rev'
967d40bec14be87262b21ab901dbace23b7365db
```

# nixpkgs-multiverse

> Please read this [blog post](https://fzakaria.com/2026/08/09/nixpkgs-multiverse-every-version-that-ever-existed) for context.

Every nixpkgs revision, reachable from a **single evaluation**. One flake input, no juggling `nixpkgs` pinned at N commits.

The whole index is browsable at **<https://nixmultiverse.com/>**

Search any attribute for every version it ever shipped, with copy-paste run
and pin commands, plus the full revision and release tables.

![lotr meme "One flake to rule them all"](./multiverse_lotr.jpg)

**Documentation:** [Design](./docs/design.md) ·
[Comparisons](./docs/comparisons.md) ·
[Selectors](./docs/selectors.md) ·
[The Nix API](./docs/nix-api.md) ·
[The `mvs` CLI](./docs/cli.md) ·
[NixOS / nix-darwin / home-manager module](./docs/modules.md) ·
[Replacing nixpkgs inputs](./docs/flake-inputs.md) ·
[Without flakes](./docs/non-flake.md) ·
[Building the index](./docs/building-the-index.md) ·
[The store-path index](./docs/store-paths.md)

Also published at <https://nixmultiverse.com/docs/>.

Questions, ideas, and "does it handle X?" are welcome in the
[Discord thread](https://discord.com/channels/568306982717751326/1538990827404267590).

## Status

![github master branch workflow](https://github.com/fzakaria/nixpkgs-multiverse/actions/workflows/update-index.yml/badge.svg?branch=main)
![ci workflow](https://github.com/fzakaria/nixpkgs-multiverse/actions/workflows/ci.yml/badge.svg?branch=main)

<!-- BEGIN index-status -->

- **309,902 package versions** across **32,117 attributes**, from **1,544 revisions**
- 2012-07-05 → 2026-09-04, newest [`801bef6abd86`](https://github.com/NixOS/nixpkgs/commit/801bef6abd86b91e51083066b83fb354a11fc640) · [`nixos-26.11pre1067334`](https://releases.nixos.org/?prefix=nixos/unstable/nixos-26.11pre1067334.801bef6abd86/)
<!-- END index-status -->

## Quickstart

Every version of every package ever packaged in nixpkgs, from 2012 to 2026, as
an installable:

```console
$ nix run 'github:fzakaria/nixpkgs-multiverse#versions.python3."3.6.2"' -- --version
Python 3.6.2

# the latest version of a package
$ nix run 'github:fzakaria/nixpkgs-multiverse#latest.python3' -- --version
Python 3.14.6

# a whole revision: the newest indexed, a release channel, or a commit
$ nix run github:fzakaria/nixpkgs-multiverse#tip.hello
$ nix run github:fzakaria/nixpkgs-multiverse#26.05.hello
$ nix shell github:fzakaria/nixpkgs-multiverse#967d40bec14b.python3
```

The commands above fetch and evaluate a ~378 MB nixpkgs tree the first time.
The **fast path** skips both: the [store-path index](./docs/store-paths.md)
already knows the path Hydra built, so Nix substitutes it straight from
cache.nixos.org — seconds instead of minutes, after
[tomberek](https://github.com/tomberek)'s
[fastpkgs](https://github.com/tomberek/fastpkgs) trick. Append the output
(`.out`) — a fake derivation has nothing to build, only a path to fetch:

```console
$ nix shell 'github:fzakaria/nixpkgs-multiverse#fast.versions.python3."3.8.9".out'
$ nix build 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello.out'
```

The same questions answered offline, out of a database baked into the flake,
by the `mvs` tool:

```console
$ nix run github:fzakaria/nixpkgs-multiverse#mvs -- query versions python3
python3 · 64 versions · 2012-07-05 .. 2026-08-16
VERSION   FIRST       LAST        REVS
3.2.3     2012-07-05  2013-03-01  8
…
3.14.7    2026-08-12  current     3
```

Pin a package from a NixOS, nix-darwin, or home-manager configuration:

```nix
{
  # Use darwinModules.default on nix-darwin or homeManagerModules.default in
  # home-manager.
  imports = [ inputs.multiverse.nixosModules.default ];

  multiverse.enable = true;
  multiverse.pins.python3 = "3.8.9";
}
```

Enumerating versions fetches nothing — it reads an index file. A revision is
materialised the first time you force a derivation.

From here, [the Nix API](./docs/nix-api.md) covers selecting revisions by date,
release, or commit; [the `mvs` CLI](./docs/cli.md) covers the command line; and
[the module](./docs/modules.md) covers system configuration.

## License

MIT, please see [LICENSE](LICENSE).

The Nix expressions and tooling are original work. `revisions.json`,
`index/versions.json` and `index/history.json` are generated metadata about
nixpkgs: revisions, dates, hashes and version strings, not nixpkgs source. Nixpkgs itself is MIT and is
fetched at evaluation time.

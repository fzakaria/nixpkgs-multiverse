# The Nix API

Access every version of every package ever packaged in nixpkgs, from 2012 to 2026 as an installable.

```console
$ nix run 'github:fzakaria/nixpkgs-multiverse#versions.python3."3.6.2"' -- --version
Python 3.6.2

$ nix run 'github:fzakaria/nixpkgs-multiverse#versions.python3."3.8.9"' -- --version
Python 3.8.9

# We can also get the latest version of a package.
$ nix run 'github:fzakaria/nixpkgs-multiverse#latest.python3' -- --version
Python 3.14.6
```

You can access also a package by its revision, which is a commit hash, a 12-character prefix, a `date-commit` label, the release version or tip.

```console
# the newest indexed revision
$ nix run github:fzakaria/nixpkgs-multiverse#tip.hello

# a release channel, by major.minor
$ nix run github:fzakaria/nixpkgs-multiverse#26.05.hello

# a revision by label, exactly as revOf returns it
$ nix eval github:fzakaria/nixpkgs-multiverse#2021-07-18-967d40bec14b.python3.version
"3.8.9"

# the same revision by commit, a 12-character prefix or the full hash
$ nix shell github:fzakaria/nixpkgs-multiverse#967d40bec14b.python3
$ nix shell github:fzakaria/nixpkgs-multiverse#967d40bec14be87262b21ab901dbace23b7365db.python3
```

## Nested attributes are one key

Most index names are top-level attributes. The children of the few package sets
[`nix/nested-sets.nix`](../nix/nested-sets.nix) lists are indexed as well, under
the path they are reached at — `jetbrains.idea`.

That name is **one key of a flat attrset**, not two levels of one. `nix` splits
an attribute path on unquoted dots, so the name has to be quoted, exactly the
way a version string already is:

```console
$ nix run 'github:fzakaria/nixpkgs-multiverse#versions."jetbrains.idea"."2024.1"'
$ nix build 'github:fzakaria/nixpkgs-multiverse#versions."jetbrains.idea"."2024.1".out'
$ nix shell 'github:fzakaria/nixpkgs-multiverse#latest."jetbrains.idea"'
$ nix shell 'github:fzakaria/nixpkgs-multiverse#fast.latest."jetbrains.idea"'
```

Written unquoted, `versions.jetbrains.idea."2024.1"` asks for a `jetbrains`
attribute of `versions`, which is not there, and nix reports that the flake does
not provide the attribute. Outputs and `.eval` come after the quoted segments
and are never quoted themselves: they are ordinary attributes of the derivation
the path resolved to.

The revision selectors are the exception, because they are not keyed by the
index at all. `tip`, a release, a commit and a label each resolve to a real
nixpkgs, where `jetbrains.idea` genuinely is two attributes:

```console
$ nix run github:fzakaria/nixpkgs-multiverse#tip.jetbrains.idea
```

`fast.tip` and `fast.at` are index-keyed despite the shared name, so they take
the quoted spelling that `tip` does not.

Query the flake for all the versions of a package that **ever existed in Nixpkgs**.

```console
$ nix eval --json --apply 'f: f "python3"' \
   github:fzakaria/nixpkgs-multiverse#multiverse.x86_64-linux.versionsOf
[
  "3.2.3",
  "3.3.1",
  # 60 other versions omitted for brevity
  # ...
  "3.14.6",
  "3.14.7"
]
```

The same question, and every other one below, is a subcommand of
[`mvs`](./cli.md), `mvs query versions python3`, which provides slightly
better ergonomics.

Create a specific complete revision of Nixpkgs using the `at` function.

```nix
let
  mv = multiverse.multiverse.x86_64-linux;
  # newest revision the index knows, as a real Nixpkgs
  pkgs_tip = mv.tip;
  # by release — the channel as it stands today, backports included
  pkgs_24_11 = mv.at "24.11";
  # newest revision on or before that date
  pkgs_2022_03_15 = mv.at "2022-03-15";
  # by commit
  pkgs_dc460ec76cbf = mv.at "dc460ec76cbf";
in {
  packages = [
      pkgs_tip.python3
      pkgs_24_11.python3
      pkgs_2022_03_15.python3
      pkgs_dc460ec76cbf.python3
    ];
}
```

Explore more with `nix repl`

```console
$ nix repl
nix-repl> :lf github:fzakaria/nixpkgs-multiverse
nix-repl> multiverse.x86_64-linux.versionsOf "python3"
[ "3.2.3" "3.3.1" … "3.14.7" ]           # 64 versions

nix-repl> multiverse.x86_64-linux.revOf "python3" "3.8.9"
"2021-07-18-967d40bec14b"

nix-repl> multiverse.x86_64-linux.releases
[ "13.10" "14.04" … "26.05" ]
```

**Note**: Enumerating versions fetches nothing as it reads an index file only. A revision is materialised the first time you force a derivation.

## Several pins, as few revisions as possible

Asking for five packages one at a time means five revisions, and cost here is
per revision touched — five fetches, five evaluations. `solvePins` takes the
whole set at once and resolves it through the fewest revisions that can serve
it:

```nix
mv.solvePins { ripgrep = "13.0.0"; fd = "8.7.0"; jq = "1.6"; }
# => { ripgrep = <drv>; fd = <drv>; jq = <drv>; }
# all three from 2023-09-25-6500b4580c2a — one fetch, one evaluation
```

The versions are exactly the ones asked for. What minimising decides is which
revision serves each, so a pin can land on an older revision inside its own
version's run: the same version, an older build of it. `pinPlan` is the same
answer as data, computed from the index without fetching anything:

```nix
mv.pinPlan { python3 = "3.6.1"; ripgrep = "14.1.1"; }
# => {
#      revisions = 2;
#      groups = [ { revision = { … off = 88; }; pins = [ { attr = "python3"; version = "3.6.1";
#                                                          movedRevisions = 0; movedDays = 0; } ]; }
#                 { revision = { … off = 1424; }; pins = [ … ]; } ];
#      certificate = [ "python3 3.6.1" "ripgrep 14.1.1" ];
#      why = "python3 3.6.1 and ripgrep 14.1.1 never overlapped";
#    }
```

These are the same fields `mvs solve --json` prints, so a configuration can
assert on a plan the CLI can also explain. Nothing offers "one revision or
fail" as a mode, because the plan already says: `revisions == 1` is the
assertion, and `why` is the message to fail with.

`certificate` names one pin per revision, and those pins never overlap each
other — which is the proof that no smaller plan exists, checkable from the
dates alone. See [Minimising](./design.md#minimising) for the argument and for
what the grouping costs.

## The fast path

Everything above hands back _real_ derivations, which means fetching a
~378 MB nixpkgs tree and evaluating it the first time one is forced. The
`fast` attrset skips both: the [store-path index](./store-paths.md) already
knows the `/nix/store` path Hydra built for every matched version, so `fast`
builds a _fake_ derivation around that path, many thanks to
[tomberek](https://github.com/tomberek)'s
[fastpkgs](https://github.com/tomberek/fastpkgs) trick, and Nix substitutes
it, full closure included, straight from [cache.nixos.org](https://cache.nixos.org).
**No nixpkgs fetch, no evaluation, no experimental features.**

The selector grammar is the same, with only the terminal step swapped.

```nix
# a specific version, zero-eval
mv.fast.version "python3" "3.8.9"
# newest version with a store path
mv.fast.latest.python3
# a whole revision, as fakes
mv.fast.at "2022-03-15"
# the newest indexed revision — fast.at "tip"
mv.fast.tip.hello
# exact revision keys work too
mv.fast."967d40bec14b".python3
```

There are some differences to be aware of and they depends on the selector:

| selector                         | class                                                                    | what it promises                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `fast.version` / `fast.versions` | **bit-exact**                                                            | the digest is precisely the build the eval path resolves to, for the system you asked as                  |
| `fast.latest`                    | **bit-exact**, but see [below](#fastlatest-prefers-servable-over-newest) | the newest version that _has_ a store path, which is not always the newest version                        |
| `fast.at` / `fast.tip`           | **version-exact**, build-canonical                                       | the right version for that revision, as its build at the newest revision that shipped it                  |
| release (`fast.at "26.05"`)      | **eval-only**                                                            | refuses — the digests are keyed per version, not per branch, see [below](#why-releases-have-no-fast-path) |

Bit-exact is per **system**. A store path is a function of the system it was
evaluated for, so the artifacts are published one file per system and `fast.*`
serves the file matching the `system` the multiverse was imported with. A
system with no published file throws, naming the eval selector — it is never
served another system's digests, which is what
[#12](https://github.com/fzakaria/nixpkgs-multiverse/issues/12) was.

**Note**: a "fake derivation" has no `drvPath`,
so the CLI needs the _output_: append `.out`, `.lib`, `.bin`, etc… for multi-output
packages:

```console
$ nix shell 'github:fzakaria/nixpkgs-multiverse#fast.versions.python3."3.8.9".out'
$ nix build 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello.out'
$ nix build 'github:fzakaria/nixpkgs-multiverse#fast.latest.ffmpeg.lib'
```

Every fake carries a lazy `.eval` holding the real, revision-exact
derivation for everything a fake cannot do: `override`, `nix develop`,
`drvPath`, full `meta`:

```nix
(mv.fast.version "python3" "3.8.9").eval.override { ... }
```

By default, a version the store-path index has no digest for **throws**,
so there is no surprise fetch, however this can be tuned per `mkMultiverse`:

```nix
mkMultiverse {
  system = "x86_64-linux";
  # unmatched pairs fall back to the real
  # derivation silently (default: "throw")
  fastFallback = "eval";
  # read the data files from a directory instead
  # of fetching them (see Mirrors below)
  fetchArtifact = { name, ... }: ./artifacts + "/${name}";
}
```

The index covers **x86_64-linux, aarch64-linux and aarch64-darwin**; other
systems throw rather than substitute foreign binaries, and darwin's coverage
starts in 2021 ([why](./store-paths.md#a-path-belongs-to-one-system)). Data
arrives through `data-pins.json` lazily: nothing is fetched until the first
`fast.*` value is forced, and only your own system's file is fetched.

### `nix run` cannot take a fake

`nix build` and `nix shell` accept a store path as an installable, which is
all `.out` is. `nix run` does not, so there is no spelling of a fast selector
that it accepts:

```console
$ nix run 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello'
error: … lacks attribute 'drvPath'

$ nix run 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello.out'
error: attribute 'legacyPackages.x86_64-linux.fast.latest.hello.out.type' does not exist
```

To _run_ a fast package, use a shell, or [`mvs run`](./cli.md#running-a-version),
which takes the store-path road by default:

```console
$ nix shell 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello.out' -c hello
Hello, world!

$ mvs run hello@2.12.2
Hello, world!
```

### Shebang support

Nix's shebang support works perflectly well with the multiverse
except for some tricky back-ticks.

```bash
#!/usr/bin/env nix
#! nix shell nixpkgs#bash
#! nix ``github:fzakaria/nixpkgs-multiverse#fast.versions.python3."3.8.9".out``
#! nix ``github:fzakaria/nixpkgs-multiverse#fast.versions.jq."1.6".bin``
#! nix --command bash

# Python 3.8.9
python3 --version
# jq-1.6
jq --version
```

You must observe through three rules, each of which is a silent failure when broken:

- **Double backticks around the whole installable.** A version string needs
  quotes in an attrpath, and Nix's shebang lexer refuses a bare `"` — see [the note in its manual](https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-shell.html).
  Backticking only the version splits it into two installables instead. `fast.latest.hello.out` carries no version and needs none of this.
- **Name the right output.** `jq."1.6".out` is an empty stub; the binary is in `.bin`. Get it wrong and the ambient `jq` answers instead, with no error.
- **`--command` is not optional**, and it is what makes the reader's login shell irrelevant. Omit it and Nix reads the script path as one more installable.

Unfortunately, `nix-shell` cannot express any of this on the `#!` line since the parser splits on whitespace and strips quotes, so `hello."2.12.2"` is read as `hello.2.12.2`.

Point it at a file instead:

```nix
# deps.nix
let
  mv = import (builtins.fetchTarball
    "https://github.com/fzakaria/nixpkgs-multiverse/archive/main.tar.gz") { };
  pkgs = import <nixpkgs> { };
in
pkgs.mkShell {
  packages = [
    mv.fast.versions.python3."3.8.9"
    mv.fast.versions.jq."1.6"
  ];
}
```

```bash
#!/usr/bin/env nix-shell
#! nix-shell deps.nix -i bash
```

### Attributes with no fast path

Not every attribute has a store path to substitute, so it is ineligible for the fast path

1. **Hydra never built it.** nixpkgs is evaluated with
   `allowUnfree = false`, so an unfree package never reaches
   [cache.nixos.org](https://cache.nixos.org).
   `vscode`, `steam` and `discord` have no store path at
   _any_ version. Broken and unsupported-platform attributes land here too.
2. **nixpkgs asked Hydra not to build it.** `meta.hydraPlatforms = [ ]`
   excludes an attribute from the jobset, and wrapper packages use it
   routinely to avoid rebuilding a symlink farm.
3. **Nothing vouched for the path.** A pair's digest comes from evaluating its
   revision, and is kept only if the channel listing or the cache
   [holds that exact path](./store-paths.md#resolving-a-pair). An attribute
   this evaluation builds differently from Hydra — anything that branches on
   `allowUnfree`, say — has a path nobody built.
4. **It is newer than the pin.** A version that first appeared in a bump
   after the last data cut has no digest yet.
5. **Your system has no artifacts.** The files are per system; one that has
   never been evaluated is served nothing rather than another system's paths.

A helpful error message points to the [eval path](#unfree-packages-and-nixpkgs-config) when a fast selector cannot find a store path:

```console
$ nix eval 'github:fzakaria/nixpkgs-multiverse#fast.versions.vscode."1.107.0"'
error: multiverse: fast has no store path for vscode 1.107.0 — the pair is not
in the store-path index (never built by Hydra, unfree, or newer than the data
pin). Use the eval path: versions.vscode."1.107.0"

$ nix eval 'github:fzakaria/nixpkgs-multiverse#fast.tip.vscode'
error: multiverse: fast has no store path for vscode 1.132.0 — the pair is not
in the store-path index (never built by Hydra, unfree, or newer than the data
pin). Use the eval path: (at "tip").vscode
```

### `fast.latest` prefers servable over newest

`latest` means _the newest version that has a store path_, not the newest
version that exists. Where the two differ, the servable one wins, so that
`latest` keeps its promise of resolving instantly.

The cost is that `fast.latest` can be far behind. Several hundred attributes
currently resolve to an older version than the index's newest, many of them
by a whole major version or more.

For instance, `neovim`:

```console
$ nix eval 'github:fzakaria/nixpkgs-multiverse#fast.latest.neovim.version'
"0.2.1"

$ nix eval 'github:fzakaria/nixpkgs-multiverse#versionAt' --apply 'f: f "neovim" "tip"'
"0.12.4"
```

0.2.1 is from 2017 and is not an accident of matching. Until December 2017
`neovim` was an ordinary package and Hydra built it; the wrapper that
replaced it carries `hydraPlatforms = [ ]`. Only
`neovim-unwrapped` is built, and that is the attribute to reach for:

```console
$ nix eval 'github:fzakaria/nixpkgs-multiverse#fast.tip.neovim-unwrapped.version'
"0.12.4"
```

Reach for `fast.tip` when you want what the newest indexed revision,
and `latest` only when you want the newest thing that substitutes
without an evaluation.

### Why releases have no fast path

Not for want of store paths. Release channels publish `store-paths.xz` under
`nixos/<major.minor>/` exactly as unstable does, at the very channel name
`releases.json` already records, for instance 209,161 paths for `26.05`, against
unstable's 219,101. They are in the cache and they are reachable.

What is missing is a **key**. The index is keyed `(attr, version) → digest`,
and that pair does not identify a uniquebuild across branches:

```
hello-2.12.3
  26.05:    /nix/store/13vq6bhkphh2m8bhqj4zw8ri0ardmz8a-hello-2.12.3
  unstable: /nix/store/846h582z2d4mifn4km7axlqllcyn6zdg-hello-2.12.3
```

Same package, same version, different path because a store path hashes the
whole recipe, and a release branch carries _some_ differences that cause
many packages to rehash to different store paths.

## A soak period

`daysBehind` gives you the whole of nixos-unstable as it stood some number of
days before an anchor, a cooldown window similar to [Determinate Systems Cooldown](https://determinate.systems/blog/nixpkgs-cooldown/#reducing-the-risk-with-cooldowns).

The anchor is any selector `at` takes:

```nix
# a week behind the newest indexed revision
mv.daysBehind "tip" 7
# a week before the 26.05 channel tip
mv.daysBehind "26.05" 7
# a week before that date
mv.daysBehind "2026-05-30" 7
# a month before that commit landed
mv.daysBehind "dc460ec76cbf" 30
```

```console
nix-repl> (mv.daysBehind "tip" 7).hello.version
"2.12.3"
nix-repl> (mv.daysBehind "tip" 365).hello.version
"2.12.2"
```

A selector resolves to a date out of `revisions.json` or `releases.json`. Only the revision you asked for is ever fetched (i.e. `"26.05"` does not materialise 26.05).

**Note**: Days behind a release revision walk back on unstable, not the release branch.

## Provenance

Every set from the multiverse is tagged with its origin:

```console
nix-repl> (mv.at "2022-03-15").multiverse
{ date = "2022-03-14"; label = "2022-03-14-73ad5f9e147c";
  rev = "73ad5f9e147c0d2a2061f1d4bd91e05078dc0b58"; }

nix-repl> (mv.at "26.05").multiverse
{ build = 7376; date = "2026-08-09"; name = "nixos-26.05.7376.fcb8fcd6bf2d";
  release = "26.05"; rev = "fcb8fcd6bf2d0adecae5bd491afaaaf8311b758d"; }
```

## Releases move, revisions do not

`at "26.05"` is a _channel_, not a snapshot. Backports land on `release-26.05` for the whole life of the release, and `at` follows them, exactly as `github:NixOS/nixpkgs/nixos-26.05` does:

```console
# the channel tip, refreshed hourly
nix-repl> (mv.at "26.05").frankenphp.version
"1.12.6"

# the newest bump on or before that date, fixed forever
nix-repl> (mv.at "2026-05-30").frankenphp.version
"1.12.3"
```

If you need a result that cannot drift, select by **date or commit**.

Releases live in their own file, `releases.json`, keyed by name
and indexed by nothing. This is where `at "26.05"` above read its revision
from, and like everything else about a release it is a snapshot of the
channel on the day it was written:

```console
nix-repl> multiverse.x86_64-linux.releaseTips."26.05"
{ build = 7376; date = "2026-08-09";
  name = "nixos-26.05.7376.fcb8fcd6bf2d";
  rev = "fcb8fcd6bf2d0adecae5bd491afaaaf8311b758d"; }
```

Each one is the highest-numbered published bump of that channel in the [nix-releases archive](https://releases.nixos.org/?prefix=nixos/), so it exists in the [cache.nixos.org](https://cache.nixos.org) as well. Betas are skipped, so a release appears only once it has shipped.

All 25 releases the archive holds are tracked, back to `13.10`:

```console
nix-repl> (mv.at "13.10").hello.name
"hello-2.8"
```

## The revision data at a glance

```nix
# every known version, version-aware sort
mv.versionsOf "python3"
# every known revision that shipped a version
mv.revOf "python3" "3.8.9"
# unstable as it stood N days before any anchor
mv.daysBehind "tip" 7
# a revision as the flake attrset `inputs.nixpkgs` would have been
mv.flakeAt "26.05"
# a `mvs lock` file, as {attr -> derivation}
mv.readLock ./multiverse.lock
# where a package set came from
(mv.at "26.05").multiverse
# every release channel tracked, oldest first
mv.releases
# the release table: what commit each channel is at, and when
mv.releaseTips
# every revision label, oldest first
mv.revs
# the raw {rev, date, narHash, name} array
mv.revisions
```

## Version history

`index/versions.json` records only the newest revision that shipped each
version, which is all `version` and `versionsOf` need. `index/history.json`
records **when each version was present**, as ranges of revisions: a
lifetime, a removal, or "what did nixpkgs have on this date" is answerable
without fetching anything.

```console
nix-repl> mv.lifetimeOf "python3" "3.8.9"
{ earliest = "2021-04-26"; latest = "2021-07-18";
  earliestLabel = "2021-04-26-8e4fe32876ca"; latestLabel = "2021-07-18-967d40bec14b";
  runs = [ { first = "2021-04-26"; last = "2021-07-18"; … } ]; }

# what an attribute had at a revision — no fetch, where reading
# (mv.at "2022-03-15").python3.version materialises the whole revision
nix-repl> mv.versionAt "python3" "2022-03-15"
"3.9.10"

# when something left nixpkgs; null while it is still here
nix-repl> mv.goneSince "python2"
{ date = "2026-05-23"; label = "2026-05-23-64c08a7ca051"; version = "2.7.18.12"; }

# every version of a package with its lifetime, oldest first
nix-repl> mv.historyOf "ripgrep"
```

The label `goneSince` hands back is a selector, so it feeds straight into `at`
to get a working derivation out of the last revision that had the package:

```nix
(mv.at (mv.goneSince "python2").label).python2
```

**A version is not always present the whole time.**
A version may have been upgraded and then downgraded, or removed and later re-added several times.

- `earliest` / `latest` are the **outer bounds of every sighting**.
- `runs` are the **unbroken stretches**.

## As an input to your own flake

```nix
{
  inputs.multiverse.url = "github:fzakaria/nixpkgs-multiverse";
  outputs =
    { self, nixpkgs, multiverse }:
    let
      mv = multiverse.multiverse.x86_64-linux;
    in
    {
      devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
        packages = [
          (mv.version "python3" "3.8.9")
          (mv.version "nodejs" "14.17.0")
        ];
      };
    };
}
```

## Unfree packages and nixpkgs `config`

A multiverse revision is an ordinary nixpkgs import, so unfree packages need
`allowUnfree`. The `multiverse.<system>` flake output is built with an empty
`config`, so it cannot serve one.

`lib.mkMultiverse` is the same API with `config` and `overlays` threaded
through to every revision it hands out:

```nix
{
  inputs.nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
  inputs.multiverse.url = "github:fzakaria/nixpkgs-multiverse";
  outputs =
    { nix-vscode-extensions, multiverse, ... }:
    let
      system = "x86_64-linux";
      mv = multiverse.lib.mkMultiverse {
        inherit system;
        config.allowUnfree = true;
        overlays = [ nix-vscode-extensions.overlays.default ];
      };
    in
    {
      packages.${system}.code = mv.version "vscode" "1.107.0";
    };
}
```

`mv.tip`, `mv.at`, `mv.version`, `mv.versions` and `mv.latest` all carry that
config, and so does anything `fastFallback = "eval"` hands back, since the
fallback is those same derivations. What no `config` can give `mv.fast.*` is a
store path to substitute: Hydra never built one, so an unfree package has the
eval path or nothing. See
[attributes with no fast path](#attributes-with-no-fast-path).

## Mirrors

Two fetchers decide where a multiverse gets its bytes: `fetchRevision` for
nixpkgs trees, `fetchArtifact` for the pinned fast-path files. Each is handed
the record naming what is wanted and returns the fetched thing — a
`builtins.fetchTree` result for a tree, a path for a file.

```nix
mv = multiverse.lib.mkMultiverse {
  system = "x86_64-linux";

  fetchRevision = r: builtins.fetchTree {
    type = "tarball";
    url = "https://artifactory.example.org/artifactory/nixpkgs/${r.rev}.tar.gz";
    inherit (r) narHash;
  };

  fetchArtifact = { name, tag, narHash, baseUrl }: (builtins.fetchTree {
    type = "file";
    url = "https://artifactory.example.org/artifactory/multiverse/${tag}-${name}";
    inherit narHash;
  }).outPath;
};
```

Returning the fetched thing, rather than arguments for fetching it, is what
makes a fetcher unrestricted: `fetchurl`, a store path handed in from elsewhere,
or a directory already on disk are all just values to return.

Both are accepted by `lib.mkMultiverse`, `lib.readLock`, `lib.pinOverlay` and
the NixOS, nix-darwin and home-manager modules — which is where a mirror is
usually needed, since that is how a configuration consumes this flake:

```nix
multiverse = {
  enable = true;
  fetchRevision = r: builtins.fetchTree {
    type = "tarball";
    url = "https://mirror.example/${r.rev}.tar.gz";
    inherit (r) narHash;
  };
  pins.ripgrep = "13.0.0";
};
```

Only the predefined `multiverse.<system>` output cannot take them: it is an
attrset, not a function.

### Vendoring is a fetcher that fetches nothing

There is no separate option for local artifacts. A directory of
`outpaths-*.json` and friends is one line:

```nix
mkMultiverse {
  system = "x86_64-linux";
  fetchArtifact = { name, ... }: ./artifacts + "/${name}";
}
```

Nothing is fetched and no hash is checked, because the fetcher did neither.

Which systems are served still comes from `data-pins.json`, the only party that
can speak for what was published. A directory covering fewer systems than the
pin therefore fails naming the file it has no copy of, rather than with the
"no store-path index for this system" message an unpublished system gets.

### The two fetchers differ on narHash

`fetchRevision`'s answer is checked: multiverse compares the returned `narHash`
against the one recorded for that revision — by `build-index.sh` for an indexed
revision, by `fetch-releases.sh` for a release tip — and throws if they differ. The index records
digests for the trees those hashes name, so a mirror serving anything else
resolves to derivations no digest describes. The check sits outside the fetch
deliberately — it holds however the fetcher got the tree, including mechanisms
`builtins.fetchTree` never sees.

`fetchArtifact`'s answer is not checked. These files are JSON this evaluation
parses, not trees that have to match what Hydra built, and a deployment that
regenerates them with `tools/` holds different bytes legitimately. The pinned
`narHash` is handed to the fetcher, which decides what to do with it.

### One small file at a time

The default `fetchArtifact` pulls exactly one file per artifact, and only when
forced: a fast lookup takes `outpaths-<system>.json`,
`tip-outpaths-<system>.json` and `outs-<system>.json`, and the eval path takes
none of them.

A fetcher may instead pull a whole tree and index into it — one git ref holding
every artifact, say. That trades three targeted fetches for one large one and
hands every x86_64 consumer the aarch64 half, which is exactly what publishing
[one file per system](./store-paths.md#a-path-belongs-to-one-system) exists to
avoid. Prefer a per-file mirror.

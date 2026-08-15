# The Nix API

Access every version of every package ever packaged in nixpkgs, from 2013 to 2026 as an installable.

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

Query the flake for all the versions of a package that **ever existed in Nixpkgs**.

```console
$ nix eval --json --apply 'f: f "python3"' \
   github:fzakaria/nixpkgs-multiverse#multiverse.x86_64-linux.versionsOf
[
  "3.3.2",
  "3.4.3",
  # 58 other versions omitted for brevity
  # ...
  "3.13.13",
  "3.14.6"
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
  pkgs_aae12a743f75 = mv.at "aae12a743f75";
in {
  packages = [
      pkgs_tip.python3
      pkgs_24_11.python3
      pkgs_2022_03_15.python3
      pkgs_aae12a743f75.python3
    ];
}
```

Explore more with `nix repl`

```console
$ nix repl
nix-repl> :lf github:fzakaria/nixpkgs-multiverse
nix-repl> multiverse.x86_64-linux.versionsOf "python3"
[ "3.3.2" "3.4.3" … "3.14.6" ]           # 62 versions

nix-repl> multiverse.x86_64-linux.revOf "python3" "3.8.9"
"2021-07-18-967d40bec14b"

nix-repl> multiverse.x86_64-linux.releases
[ "13.10" "14.04" … "26.05" ]
```


**Note**: Enumerating versions fetches nothing as it reads an index file only. A revision is materialised the first time you force a derivation.

## The fast path

Everything above hands back *real* derivations, which means fetching a
~378 MB nixpkgs tree and evaluating it the first time one is forced. The
`fast` attrset skips both: the [store-path index](./store-paths.md) already
knows the `/nix/store` path Hydra built for every matched version, so `fast`
builds a *fake* derivation around that path, many thanks to
[tomberek](https://github.com/tomberek)'s
[fastpkgs](https://github.com/tomberek/fastpkgs) trick, and Nix substitutes
it, full closure included, straight from [cache.nixos.org](https://cache.nixos.org).
**No nixpkgs fetch, no evaluation, no experimental features.**

The selector grammar is the same, with only the terminal
step swapped. One thing to remember: a "fake derivation" has no `drvPath`,
so the CLI needs the *output*: append `.out` (or `.lib`, `.bin`, … for multi-output
packages):

```console
$ nix shell 'github:fzakaria/nixpkgs-multiverse#fast.versions.python3."3.8.9".out'
$ nix build 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello.out'
$ nix build 'github:fzakaria/nixpkgs-multiverse#fast.latest.ffmpeg.lib'
```

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

Both errors are the same fact seen from two sides. `nix run` resolves an
installable by forcing it as a derivation — which needs the `drvPath` a fake
does not have — or as an *app*, which means reading `.type`, and `.out` is a
string rather than an attrset. A bare `nix run /nix/store/…` is refused too:
"installable does not correspond to a Nix language value".

An `app` attrset alongside the fake does not help either: Nix only honours
apps under `apps.<system>`, and mirroring the whole `fast` tree there is not
an option, because `nix flake check` requires every attribute under
`apps.<system>` to be an app itself and fails on a nested tree.

So to *run* a fast package, use a shell, or [`mvs run`](./cli.md#running-a-version),
which takes the store-path road by default:

```console
$ nix shell 'github:fzakaria/nixpkgs-multiverse#fast.latest.hello.out' -c hello
Hello, world!

$ mvs run hello@2.12.2
Hello, world!
```

```nix
# a specific version, zero-eval
mv.fast.version "python3" "3.8.9"
# newest indexed version, as of the pin
mv.fast.latest.python3
# what was current when the pin was cut
mv.fast.tip.hello
# a whole revision, as fakes
mv.fast.at "2022-03-15"
# exact revision keys work too
mv.fast."967d40bec14b".python3
```

`fast.versions` / `fast.latest` / `fast.tip` are **bit-exact** as what you
would get if you did the evaluation. We just go straight to the substitution
path. Release selectors are **eval-only** and refuse: a release branch is not
an indexed revision.

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
  # vendor the data files, skip the pin
  dataOverride = ./artifacts;
}
```

The index covers x86_64-linux; other systems throw
rather than substitute foreign binaries. Data arrives through
`data-pins.json` lazily: nothing is fetched until the first `fast.*` value
is forced.

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
mv.daysBehind "aae12a743f75" 30
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

`at "26.05"` is a *channel*, not a snapshot. Backports land on `release-26.05` for the whole life of the release, and `at` follows them, exactly as `github:NixOS/nixpkgs/nixos-26.05` does:

```console
# the channel tip, refreshed hourly
nix-repl> (mv.at "26.05").frankenphp.version
"1.12.6"

# the release commit, fixed forever
nix-repl> (mv.at "2026-05-30").frankenphp.version
"1.12.3"
```

If you need a result that cannot drift, select by **date or commit**. 

Releases live in their own file, `releases.json`, keyed by name
and indexed by nothing:

```console
nix-repl> multiverse.x86_64-linux.releaseTips."26.05"
{ build = 7273; date = "2026-08-08";
  name = "nixos-26.05.7273.8b8c811c7c25";
  rev = "8b8c811c7c2541c30382c5de7ed26be055569c60"; }
```

Each one is the highest-numbered published bump of that channel in the [nix-releases archive](https://nix-releases.s3.amazonaws.com/), so it exists in the [cache.nixos.org](https://cache.nixos.org) as well. Betas are skipped, so a release appears only once it has shipped.

All 25 releases the archive holds are tracked, back to `13.10`:

```console
nix-repl> (mv.at "13.10").hello.name
"hello-2.8"
```


Query the underlying revision data.

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
# the raw {rev, date, channel, narHash, name} array
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
{ date = "2026-05-30"; label = "2026-05-30-76b7bc982574"; version = "2.7.18.12"; }

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

As an input to your own flake

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
`allowUnfree`. The `multiverse.<system>` flake output is built with an
empty `config`:

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
        overlays = [ inputs.nix-vscode-extensions.overlays.default ];
      };
    in
    {
      packages.${system}.code = mv.version "vscode" "1.107.0";
    };
}
```

`mv.tip`, `mv.at`, `mv.version`, `mv.versions` and `mv.latest` all carry that
config.

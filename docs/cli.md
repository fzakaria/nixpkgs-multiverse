# The mvs CLI

`mvs` answers the same questions as the Nix API, but as a command line,
designed for ergonomics.

```console
$ nix run github:fzakaria/nixpkgs-multiverse#mvs -- query versions python3
python3 · 64 versions · 2012-07-05 .. 2026-08-16
VERSION   FIRST       LAST        REVS
3.2.3     2012-07-05  2013-03-01  8
3.3.1     2013-06-30  2013-06-30  1
…
3.13.13   2026-05-21  2026-07-05  11
3.14.6    2026-07-08  2026-08-10  17
3.14.7    2026-08-12  current     3
```

The `mvs` contains the index. There is no download path, no cache directory, and nothing
that can drift from the pinned input. Two people running the same `nix run` get
the same answers.

`--json` works on every subcommand.

## Reading the index

| command                       | answers                                                             |
| ----------------------------- | ------------------------------------------------------------------- |
| `mvs query versions <attr>`   | every version, in the order nixpkgs shipped them, with its lifetime |
| `mvs query when <attr> <ver>` | first and last sighting, every run, the gaps                        |
| `mvs query at <sel> <attr>`   | the version that revision shipped                                   |
| `mvs query gone <attr>`       | last sighting, or still current                                     |
| `mvs query rev <sel>`         | resolve any selector to commit, date and label                      |
| `mvs query search <pattern>`  | attribute search                                                    |
| `mvs query diff <a> <b>`      | added / removed / upgraded / downgraded                             |
| `mvs query stats`             | headline numbers                                                    |

A _selector_ is the same vocabulary `at` takes: `tip`, a release (`26.05`), a
date (`2022-03-15`), a commit prefix, or a revision label.

`query at` is the one that cannot be done any other way. It says what nixpkgs
had on a date without materialising anything, where reading
`(mv.at "2022-03-15").python3.version` fetches the whole ~378 MB revision to
look at one string:

```console
$ mvs query at 2022-03-15 python3
3.9.10
  2022-03-14-73ad5f9e147c (2022-03-14)
```

A version is not always present the whole time, and `when` says so rather than
flattening it into a range:

```console
$ mvs query when emacs 25.1
emacs 25.1 · 59 revisions · 2016-09-24 .. 2017-04-27
RUN  FIRST                    LAST                     REVS
1    2016-09-24-adfcc2d9531e  2017-04-24-c90998d5cf8b  58
2    2017-04-27-e89343dc08ca  2017-04-27-e89343dc08ca  1
  gap: 1 revision between 2017-04-27 and 2017-04-27
```

## The fewest revisions for several packages

Composing versions from _different_ revisions gives complete closure down to
the `libc`. That is fine for a leaf command-line tool and wrong for anything
that links — and every extra revision is another nixpkgs to fetch and evaluate.
`solve` answers both at once: the smallest set of revisions that ships every
version asked for.

```console
$ mvs solve python3@3.8 nodejs@14
1 revision · minimal
2 of 2 pins served by the store-path index

ATTR     VERSION  REVISION      DATE        MOVED
python3  3.8.9    967d40bec14b  2021-07-18
nodejs   14.17.3  967d40bec14b  2021-07-18  160 days (86 revs)
```

`MOVED` is the price of sharing: nodejs 14.17.3 was current for another 160
days after python3 3.8 ended, so grouping it with python3 puts it on an older
build of the same version. Nothing here changes which _version_ you get.

Constraints that never overlapped are not an error — they are two revisions,
and the pair that could not be reconciled is what proves two is the minimum:

```console
$ mvs solve python3@3.6 ripgrep@14
2 revisions · minimal
2 of 2 pins served by the store-path index

ATTR     VERSION  REVISION      DATE        MOVED
python3  3.6.6    80738ed9dc0c  2018-11-17
ripgrep  14.1.1   544961dfcce8  2025-10-15

  minimal: python3 3.6.x and ripgrep 14.x never overlapped
```

The `minimal:` line is a certificate, not a remark. Each revision in a plan is
forced by one pin, and those pins never overlap each other, so _k_ of them need
_k_ revisions — you can check the claim from the dates without trusting the
search. To demand a single revision, assert on the answer:

```console
$ mvs solve --json python3@3.8 nodejs@14 | jq -e '.revisions == 1'
```

The only thing that still exits non-zero is a constraint no revision ever
satisfied, since there is no plan to make. See
[Minimising](./design.md#minimising) for why the answer is always minimal and
why finding it is not the search problem it looks like.

A version is a prefix, matched component by component: `python3@3.8` accepts
3.8.9 and refuses 3.81, and `python3@3.1` means 3.1.x rather than 3.10 through
3.13.

## Per-package pins

```
mvs lock add <attr>[@ver]        mvs lock update [<attr> | --all]
mvs lock rm <attr>               mvs lock status
mvs lock list                    mvs lock minimize [--check]
```

`mvs lock update helix` finds the newest indexed revision providing helix and
rewrites **only** that entry. Every other pin stays exactly where it was, which
is the difference from a single flake input that moves everything at once.

```json
{
  "version": 1,
  "pins": {
    "helix": {
      "rev": "2fcb964de67fcf60b43471c55d5d99e61a9ccb5a",
      "label": "2026-08-10-2fcb964de67f",
      "version": "25.07.1",
      "date": "2026-08-10"
    }
  }
}
```

`mvs lock status` is where the history index earns its place — how far behind a
pin has fallen, with nothing fetched and no clock consulted. Both numbers are
measured against the newest revision the index knows, so the answer is
reproducible and moves only when the index does:

```console
$ mvs lock status
ATTR   PINNED   LATEST   BEHIND
helix  25.01.1  25.07.1  2 versions, 72 days
```

### Fewer revisions for the same pins

Each pin added lands on the newest revision shipping its version, and those
rarely coincide, so a lock with four pins is four nixpkgs fetches. `mvs lock
minimize` moves them onto the fewest revisions that can serve the versions
already pinned:

```console
$ mvs lock minimize
4 pins · 4 revisions → 1 · minimal

ATTR     VERSION  REVISION      DATE        OLDER BY
fd       8.7.0    6500b4580c2a  2023-09-25  24 days
hello    2.12.1   6500b4580c2a  2023-09-25  603 days
ripgrep  13.0.0   6500b4580c2a  2023-09-25  59 days

  minimal: one revision serves every pin
```

Only `rev`, `label` and `date` change; the format is untouched, and `readLock`
needs no help, since two pins carrying the same commit already resolve through
one memoised revision. **Versions never move** — minimising decides which
revision serves a version, never which version is served — but the build does,
which is what `OLDER BY` reports.

`--check` prints the same table, writes nothing and exits non-zero, so CI can
fail on a lock that has drifted apart.

This is a one-shot rather than a mode the lock remembers, on purpose. `update`
promises to move exactly the pin you name; a lock that re-minimised itself on
every update would quietly move revisions under pins you did not mention.

A pin can never point past what the index knows, because materialising a
revision needs its narHash. Moving one forward is therefore two steps, and
honestly so:

```console
$ nix flake update multiverse    # learn about newer revisions
$ mvs lock update helix           # move this one package
```

The Nix side reads the same file. `readLock` resolves it lazily, so twenty pins
materialise only the revisions behind the packages actually built:

```nix
multiverse.lib.readLock {
  system = "x86_64-linux";
  file = ./multiverse.lock;
}
# => { helix = <derivation>; ripgrep = <derivation>; }
```

or, in the module, `multiverse.lock = ./multiverse.lock;`.

### Using the lock file without the module

`readLock` is a function from a lock file to an attrset of ordinary
derivations, so nothing about it needs NixOS or home-manager. Read it once and
every pin is a package you can put wherever a package goes:

```nix
let
  pinned = multiverse.lib.readLock {
    system = "x86_64-linux";
    file = ./multiverse.lock;
  };
in
{
  environment.systemPackages = [
    pinned.helix
    pinned.typst
    pinned.tinymist
  ];
}
```

Because the result is a plain attrset, the usual attrset tricks apply. To
install everything the lock names, without listing them a second time:

```nix
home.packages = builtins.attrValues pinned;
```

A single pin works as an option value, for the options that take a package
rather than installing one:

```nix
programs.helix.package = pinned.helix;
```

`readLock` takes the same `config` and `overlays` as everything else, which is
what an unfree pin needs:

```nix
multiverse.lib.readLock {
  inherit system;
  file = ./multiverse.lock;
  config.allowUnfree = true;
}
```

One thing to know before hand-editing: only `rev` decides what gets built.
`label`, `version` and `date` are decoration for you and for
`mvs lock status`, so changing a version string there changes what the table
reports and not what you get. Use `mvs lock update <attr>` to move a pin.

Please see [the module documentation](./modules.md) for how to
use it in your system configuration.

## Running a version

`mvs run` and `mvs shell` take `attr@version` and resolve it through the
index. By default they take the **fast road**: the
[store-path index](./store-paths.md) knows which `/nix/store` path the version
built to, so the path is substituted straight from cache.nixos.org and run. No
nixpkgs is fetched and nothing is evaluated.

```console
$ time mvs run hello@2.12.2
hello 2.12.2 from the store-path index
Hello, world!
real  0m0.075s

$ mvs run ripgrep -- --version
ripgrep 15.2.0 (current) from the store-path index
ripgrep 15.2.0
```

The program to execute is recovered from the realised path: the attribute
name, then the derivation's pname, then a sole entry in `bin/` — which is why
`ripgrep` runs `rg` without the index carrying a `mainProgram`. A package with
several binaries and no obvious match names them rather than guessing.

A version the store-path index never matched falls back to the **eval road**,
which `--eval` also forces: resolve the commit that shipped the version and
hand it to `nix run`, fetching ~378 MB of that revision.

```console
$ mvs run ripgrep@13.0.0 --eval -- --version
ripgrep 13.0.0 from 2023-11-23-5a09cb4b393d
ripgrep 13.0.0
```

`--dry-run` prints what would happen instead of doing it, which is how to see
which road a spec takes and what it resolved to:

```console
$ mvs run hello@2.12.2 --dry-run
nix-store --realise /nix/store/8qi947kixhz1nw83dkwxm6d0wndprqkj-hello-2.12.2

$ mvs run hello@2.12.2 --eval --dry-run
nix run github:NixOS/nixpkgs/b40629efe5d6…#hello
```

`mvs shell` mixes the two per package — an indexed one contributes a store
path, an unindexed one a revision — and composes across revisions, which is
right for standalone binaries and wrong for a development environment. For
that, `solve` gives one coherent revision.

## Store paths

With a database built from the store-path artifacts, five subcommands answer
questions about what a version actually built to. All of them are offline and
evaluate nothing.

```console
$ mvs path hello@2.12.2
hello 2.12.2
/nix/store/8qi947kixhz1nw83dkwxm6d0wndprqkj-hello-2.12.2

$ mvs size python3@3.8.9
python3 3.8.9 · /nix/store/6cfajs6lsy9b4wxp3jvyyl1g5x2pjmpr-python3-3.8.9
  nar (unpacked)  50.1 MiB
  download        10.6 MiB
  closure         93.8 MiB · 16 paths
  cache           live

$ mvs deps ripgrep
ripgrep 15.2.0 · 3 direct references
REFERENCE                                        PACKAGE                            VIA
0d8g8n0a11v6f5m2h416ajyxmnkwc3md-glibc-2.42-67   glibc@2.42, iconv@2.42, libc@2.42  digest
dsn500c5j62qz9f49mi3nhx74jbkf6xq-pcre2-10.47     pcre2@10.47                        digest
r48746qznwqxxl9qzd8f08ny8mg1dg2y-gcc-15.3.0-lib  (not indexed)

$ mvs rdeps pcre2
pcre2 10.47 · referenced by 255 indexed packages
…

$ mvs identify /nix/store/8qi947kixhz1nw83dkwxm6d0wndprqkj-hello-2.12.2
/nix/store/8qi947kixhz1nw83dkwxm6d0wndprqkj-hello-2.12.2
  package  hello 2.12.2
```

`identify` also takes a bare basename or a 32-character digest. `path` prints
the path on stdout and its resolution note on stderr, so it composes:

```console
$ nix-store --realise $(mvs path hello@2.12.2)
```

A database built without the store-path artifacts still answers everything in
the sections above; these five decline with a message naming the flag that
would have included the data.

## The database

The underlying database is SQLite, and it ships as an artifact of its own,
for anyone who wants to run SQL over 13 years of nixpkgs.

```console
$ nix build github:fzakaria/nixpkgs-multiverse#index-db
$ sqlite3 result 'SELECT count(*) FROM runs'
331307
```

It also carries the store-path data behind the subcommands above: store paths
interned in `store_paths`, their names in `store_names`, and every direct
reference as an integer edge in `path_refs` — 873,256 paths and 2,936,375
edges, which is the dependency graph of thirteen years of nixpkgs in a file
you can join against.

```console
$ sqlite3 result 'SELECT count(*) FROM path_refs'
2936375
```

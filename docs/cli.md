# The mvs CLI

`mvs` answers the same questions as the Nix API, but as a command line,
designed for ergonomics.

```console
$ nix run github:fzakaria/nixpkgs-multiverse#mvs -- query versions python3
python3 · 62 versions · 2013-10-31 .. 2026-08-10
VERSION  FIRST       LAST        REVS
3.3.2    2013-10-31  2013-10-31  1
3.4.3    2015-09-30  2015-09-30  1
…
3.13.13  2026-05-21  2026-07-05  12
3.14.6   2026-07-08  current     17
```

The `mvs` contains the index. There is no download path, no cache directory, and nothing
that can drift from the pinned input. Two people running the same `nix run` get
the same answers.

`--json` works on every subcommand.

## Reading the index

| command | answers |
|---|---|
| `mvs query versions <attr>` | every version, oldest first, with its lifetime |
| `mvs query when <attr> <ver>` | first and last sighting, every run, the gaps |
| `mvs query at <sel> <attr>` | the version that revision shipped |
| `mvs query gone <attr>` | last sighting, or still current |
| `mvs query rev <sel>` | resolve any selector to commit, date and label |
| `mvs query search <pattern>` | attribute search |
| `mvs query diff <a> <b>` | added / removed / upgraded / downgraded |
| `mvs query stats` | headline numbers |

A *selector* is the same vocabulary `at` takes: `tip`, a release (`26.05`), a
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
emacs 25.1 · 60 revisions · 2016-09-24 .. 2017-04-27
RUN  FIRST                    LAST                     REVS
1    2016-09-24-adfcc2d9531e  2016-09-24-adfcc2d9531e  1
2    2016-10-13-09e4b78b48fa  2017-04-24-c90998d5cf8b  58
3    2017-04-27-e89343dc08ca  2017-04-27-e89343dc08ca  1
  gap: 1 revision between 2016-10-01 and 2016-10-01
  gap: 1 revision between 2017-04-27 and 2017-04-27
```

## One revision for several packages

Composing versions from *different* revisions gives complete closure down to
the `libc`. That is fine for a leaf command-line tool and wrong for
anything that links. `solve` inverts the question: one revision, one stdenv,
internally consistent.

```console
$ mvs solve python3@3.8 nodejs@14
110 revisions · 2020-11-21 .. 2021-07-18
newest: 967d40bec14b (2021-07-18)

ATTR     VERSION
python3  3.8.9
nodejs   14.17.3

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/967d40bec14be87262b21ab901dbace23b7365db";
```

When nothing satisfies the constraints it says which two never overlapped, and
exits non-zero:

```console
$ mvs solve python3@3.6 ripgrep@14
no revision ever had both
WANTED         FROM        TO          REVS
python3 3.6.x  2017-05-29  2018-11-17  162
ripgrep 14.x   2023-11-26  2025-10-15  288
  python3 3.6.x and ripgrep 14.x never overlapped
```

A version is a prefix, matched component by component: `python3@3.8` accepts
3.8.9 and refuses 3.81, and `python3@3.1` means 3.1.x rather than 3.10 through
3.13.

## Per-package pins

```
mvs lock add <attr>[@ver]        mvs lock update [<attr> | --all]
mvs lock rm <attr>               mvs lock status
mvs lock list
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
ripgrep 13.0.0 from 2023-11-29-7c6e3666e204
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

The underlying database is SQLite and it can be queried directly.
as the artifact for anyone who wants to run SQL over 13 years of nixpkgs.

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

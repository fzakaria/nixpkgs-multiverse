# Building the index

```sh
# refresh revisions.json from the channel archive
nix run .#fetch-unstable-revisions
# point releases.json at the current tip of every release channel
nix run .#fetch-releases
# extract versions + narHashes for every revision
nix run .#build-index
# only revisions the index has never covered
nix run .#build-index -- --incremental
# smoke test on the first 30
nix run .#build-index -- -n 30
# rebuild the index from cache, no evaluation
nix run .#build-index -- --merge-only
# extract this many revisions at once
nix run .#build-index -- -j 40
# fold version lifetimes out of the same extractions
nix run .#build-history
# only what the history has never covered
nix run .#build-history -- --incremental
# rewrite the status block at the top of the README
nix run .#update-readme-status
```

None of this needs a nixpkgs clone: revisions are resolved through the GitHub API and materialised with `nix flake prefetch`, which is what lets [the update workflow](../.github/workflows/update-index.yml) run hourly and commit whatever moved.

Set `NIXPKGS=/path/to/nixpkgs` to use a clone instead, which trades the download for a `git archive` and keeps the tree out of the store.

## Indexing a nested package set

The index is flat: one entry per attribute, keyed by the name you reach it at.
Most of those are top-level attributes, but `nix/nested-sets.nix` lists package
sets whose direct children are indexed too, one level deep, under the path they
are reached at:

```console
$ nix run 'github:fzakaria/nixpkgs-multiverse#versions."jetbrains.idea"."2024.1.4"'
```

The list is an allow-list, and it is short on purpose. Nixpkgs marks 285
package sets `recurseForDerivations`, holding 74,000 children between them —
three times the whole rest of the index — and six sets are almost all of it:
`haskellPackages` at 19,400, two `python3xxPackages` at 11,000 each, then
`typstPackages`, `texlivePackages` and `sbclPackages`. Indexing all of them
would take `index/versions.json` from 5.5 MB to roughly 32 MB and take the
repository's growth from ~770 KB per index commit to ~2.9 MB.

### Adding a set

1. Check that the set earns it. The two questions are whether its children are
   things a person runs, and whether they are already in the index under another
   name. `nodePackages` fails the second: 178 of its 259 children are the
   identical derivation to a top-level attribute, so it would cost 259 entries
   to add about 40 tools. `llvmPackages` fails the first: its children that are
   not already top-level are stdenv plumbing like `clangNoLibcNoRt`, and because
   `llvmPackages` is the alias for whatever the default LLVM is at a given
   revision, its version history would record nixpkgs' default-LLVM bumps rather
   than any package's releases.

2. Count the children before you commit to it. A set that looks small can be
   anything but — `emacsPackages` is 6,685, `gnomeExtensions` has gone from 534
   in 2022 to over 1,100 today:

   ```console
   $ nix eval --raw --impure --expr \
       'toString (builtins.length (builtins.attrNames (import <nixpkgs> {}).gnomeExtensions))'
   ```

3. Add the name to `nix/nested-sets.nix`, with a comment saying what it holds
   and why it is worth the space.

4. Re-extract every revision. The list is folded into `EXTRACTOR_HASH`, so the
   whole cache is addressed under a new name and `build-index.sh` rebuilds it
   from scratch — which is what you want, since the point is to have the new set
   at every revision that ever shipped it, not only at the ones indexed after
   the edit:

   ```sh
   NIXPKGS=/path/to/nixpkgs nix run .#build-index -- -j 64
   nix run .#build-history
   ```

   Budget by memory rather than cores: each worker peaks around 2.5 GB, so
   `-j 64` wants ~160 GB. On a machine that size the rebuild is 5-10 minutes.
   The nested walk itself is nearly free — Nix only forces what is asked for, so
   reading one package set costs ~0.4s against the ~8.6s the top-level pass
   already spends.

5. Top up the store paths. The version index and the store-path index are
   built by different evaluators, so the new attributes have versions and no
   digests until the second one has seen them — every `fast.*` on one falls
   back to an evaluation until it does. This does **not** need the store-path
   pipeline re-run: a list edit can only add rows, so the existing evaluations
   are folded rather than redone, which is seconds a file instead of a minute.
   See [adding a package set costs seconds, not
   hours](./store-paths.md#adding-a-package-set-costs-seconds-not-hours).

   ```sh
   NIXPKGS=/path/to/nixpkgs nix run .#eval-outpaths -- --topup -j 40
   ```

Entries are effectively permanent. Once an attribute has a version history,
removing its set makes it read downstream as a package that left nixpkgs, which
is what `mvs query last-seen` and the site's timeline will tell people.

Only sets named in the list are walked, whatever they mark themselves as, and
only their direct children — a set inside a listed set is neither indexed nor
recursed into.

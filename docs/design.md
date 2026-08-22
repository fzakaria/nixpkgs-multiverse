# Design

Nixpkgs history _already is_ the multiverse. Every version that ever existed is
already built, already cached, already reachable, it was just addressed by
commit hash instead of by version number, which is exactly backwards from how
anyone thinks about it.

This project does not build old packages. It builds an address book.

## Why

The problem starts the first time a version bump breaks something. The usual
fix is a second `nixpkgs` input pinned to the commit before the bump, and it
works. The trouble is what it costs, because every pin is a whole extra
nixpkgs in the file:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-for-vscode.url = "github:NixOS/nixpkgs/8b8c811c7c25";
    nixpkgs-for-ripgrep.url = "github:NixOS/nixpkgs/967d40bec14b";
    # ...and one more every time something else breaks
  };
}
```

Each of those is a separate input to update, a separate line to explain, and a
separate thing to forget the reason for. The file grows a pin per incident and
never loses one.

It is also slow, for a reason that is not obvious: **flake inputs are fetched
eagerly, whether or not anything references them** as of Nix 2.34.

## How is this possible?

Nothing here is a trick.

Every package in the store describes its dependencies exactly, by hash. The
hash uniquely identifies the set of inputs a build actually used, so two
builds of the same package from different revisions, different sources,
different dependency trees, different compilers, etc., are simply two different
paths. They coexist. There is no global version to conflict over, no
"installed" version to displace, and nothing to resolve.

The second half is that the work is already done. We purposefully only leverage
bumps to Nix's unstable channel. Hydra built these revisions
when they were current and pushed them to [cache.nixos.org](https://cache.nixos.org), where they remain. Every version this index names is a cache hit.

So the missing piece was never building or storing. It was _addressing_: a way
to say "python3 3.6.2" instead of "nixpkgs at 967d40bec14b", and to say it
without paying for the other revisions you did not ask about — 1,531 of
them, as of 2026-08-16.

## Lazy trees

`flake.nix` has `inputs = { }` on purpose, and that is the whole design in one
line. Nothing this flake can reach is an input, so nothing is eager.

Revisions are fetched with `builtins.fetchTree`, pinned by `narHash`, at the
moment a derivation is forced and not before:

```nix
fetchRevision r      # defaults to builtins.fetchTree { type = "github"; ... }
```

`fetchRevision` receives the record naming the revision and returns a
`builtins.fetchTree` result; a deployment behind a mirror returns a fetcher of
its own. Multiverse checks the returned `narHash` against the one recorded for that
revision — the index records digests for the trees those hashes name. See
[mirrors](./nix-api.md#mirrors).

Everything upstream of that call: enumerating versions, resolving a date to a
revision, reading a lifetime is a Nix evaluation over JSON that ships with the
flake. It fetches nothing. A revision becomes a real tree only when you force
a derivation out of it.

Cost is therefore per _revision touched_, not per package. Revisions are
memoised, so three packages from one revision cost what one package costs;
three packages from three revisions cost three fetches. Each revision actually
used is a one-time ~378 MB which is the size of the Nixpkgs tree.

There is a second reason inputs could not work even if they were lazy: nixpkgs
had no `flake.nix` before 20.03. Revisions older than that cannot be flake
inputs at all, and roughly the first third of this index predates it.

## The index

Four files, none of which grows with the number of revisions in the way the
obvious encoding would. Every count below is a measurement taken on
2026-08-10 and left there; the index grows hourly, and the [status block in
the README](../README.md#status) is what carries the current figures.

`revisions.json` is the spine: 1,532 nixos-unstable channel bumps from
2012-07-05 to 2026-08-16, each with its commit, date, channel name and
`narHash`. Everything else refers to a revision by its **offset** into this
array, which is why the other files stay small.

The channel name spells its nixpkgs commit two ways, and the archive holds
both. From the 17.03 era on it is the last dot-separated field, as in
`nixos-26.11pre1049422.f13ff45afd1b`. Before that, nixos and nixpkgs were
separate repositories and a name carried one commit from each —
`nixos-13.07pre4909_b32ef4d-2238a23` is the nixos commit and then the nixpkgs
one. Only the trailing hash names a tree worth indexing; the leading one is
from a repository whose history was later grafted into nixpkgs, so it resolves
against `NixOS/nixpkgs` just as happily and would quietly index the wrong tree.

Every entry is a bump the nix-releases archive published, which is what makes
the whole file uniform: each one has a channel name, a `store-paths` listing,
and a Hydra build on cache.nixos.org. The file used to also carry the 22
commits each release branch was cut from. Those were on no channel, so they had
none of the three, and every consumer of a revision name carried a branch for
them; they were dropped rather than special-cased. The versions that lived only
at those commits went with them — all of them eval-only records, since a
revision with no listing can have no store path.

`index/versions.json` maps each (attribute, version) to the single newest
revision that shipped it:

```json
{
  "revisionCount": 1540,
  "attrs": {
    "hello": { "2.8": 0, "2.12.2": 1494, "2.12.3": null }
  }
}
```

`null` is not "unknown" — it is the newest revision the file covers,
`revisionCount - 1`, and it is how the file says a version is _still current_.
See [the open tip](#the-open-tip) for why it is not written out.

Storing one integer rather than every revision a version appeared in is what
keeps the file flat as revisions accumulate; otherwise a package that never
changes version gains an entry per revision forever. Measured across encodings
at 109 revisions:

| encoding                  | size       | grows with revision count? |
| ------------------------- | ---------- | -------------------------- |
| full revision list, names | 63.9 MB    | yes                        |
| `[first, last]`, offsets  | 4.1 MB     | no                         |
| newest only, offset       | **3.3 MB** | no                         |

Newest is also the build-correct choice: it is the most patched build of that
version, and the one Hydra produced most recently, so the most likely to still
substitute from the cache.

As of 2026-08-10 that file is 5.45 MB and covers **304,758 (attribute, version) pairs
across 31,798 attributes**.

`index/history.json` answers the question `versions.json` deliberately cannot:
not "where can I get this version" but "when did this version exist". It stores
each version's lifetime as runs of revision offsets, nesting only when a version
left and came back:

```json
{
  "hello": {
    "2.12.3": [1495, null],
    "2.10": [
      [1, 723],
      [728, 728]
    ]
  }
}
```

A run that is still open ends in `null`, the same claim `versions.json` makes
with a null offset: this version is current as of `revisionCount - 1`.

### The open tip

Both files are appended to hourly, and both are in git, so what matters is not
only how large they are but how much of them a single revision _changes_.

Closing those runs literally — writing `[1495, 1539]` and bumping it to
`[1495, 1540]` next hour — makes an append rewrite the entry of every version
that did not change. On a typical revision that is 24,854 of 31,819 attributes:
about 3 KB of real news, scattered as thousands of four-byte edits across a
5.4 MB file. Git stores that as a ~140 KB delta per file per revision, roughly
50× the size of the change, and it accumulates in the history forever.

Leaving the tip open costs a subtraction at read time and takes the two files
from ~284 KB of pack per indexed revision to ~6 KB:

|                                  | pack growth per revision |
| -------------------------------- | ------------------------ |
| `versions.json`, tip written out | 141 KiB                  |
| `versions.json`, tip left open   | **3 KiB**                |
| `history.json`, tip written out  | 143 KiB                  |
| `history.json`, tip left open    | **3 KiB**                |

Readers resolve a null against the `revisionCount` of the file that carries it,
never against `length revisions`. The two disagree in the ordinary window
between `fetch-unstable-revisions.sh` appending a revision and `build-index.sh`
indexing it, and in that window the newly appended revision is one the index has
never evaluated — resolving to it would claim a version was current in a tree
nobody looked at.

`releases.json` is separate and indexed by nothing: 25 release channels, each
holding the current tip of its branch. Releases move as backports are applied, so a release is a channel, not a snapshot, and it lives outside the revision array for that reason. See [releases move, revisions do not](./nix-api.md#releases-move-revisions-do-not).

## Minimising

Cost is per revision touched, not per package. Ten pins resolved independently
are ten nixpkgs fetches and ten evaluations; the same ten grouped onto the
revisions they can share might be two. `mvs solve`, `mv.solvePins` and
`multiverse.pins` all ask the same question to get there: **what is the
smallest set of revisions that ships every version asked for?**

Every pin is one contiguous block on the revision axis — the stretch of
revisions where nixpkgs shipped exactly that version. A revision _serves_ a pin
if it lies inside that pin's block. So the question is: fewest points touching
every block.

![How minimising picks revisions](./minimize.svg)

The whole algorithm is one sweep. Sort the pins by where their block **ends**.
Take the pin that ends earliest, put a revision at the last revision in its
block, delete every pin that revision serves, repeat.

### Why the sweep is optimal

Let `A` be the pin whose block ends earliest, at `l(A)`. Every valid plan holds
some revision `q` inside `A`'s block. Swap `q` for `l(A)`: any pin `B` that `q`
served has `first(B) ≤ q ≤ last(B)`, and since `l(A)` is the smallest endpoint
of anything left, `last(B) ≥ l(A)`; combined with `first(B) ≤ q ≤ l(A)`, the
point `l(A)` is inside `B` too. Nothing is lost by the swap, so _some_ optimal
plan contains `l(A)`. Fix it, delete what it serves, and the argument repeats
on what is left. Sort plus one pass: **O(n log n)**.

You do not have to take that on trust. For each revision it places, the sweep
names the pin that forced it, and those pins are pairwise disjoint — pin _j_'s
block must start after pin _i_'s ended, or _i_'s endpoint would already have
served it. _k_ disjoint blocks need _k_ distinct revisions, so the plan carries
its own proof that nothing smaller exists. That is what `certificate` and `why`
report, and it is checkable from the dates alone:

```console
$ mvs solve python3@3.8 nodejs@14 ripgrep@14
2 revisions · minimal
...
  minimal: python3 3.8.x and ripgrep 14.x never overlapped
```

### Where this would have been NP-hard

The swap above needed `first(B) ≤ l(A) ≤ last(B)` to imply that `l(A)` serves
`B`, which holds only because `B` is one unbroken block.

Versions do not always come in one block. A version can leave nixpkgs and come
back. Let a pin be served by _any_ of its blocks and the problem stops being interval
stabbing and becomes hitting set over unions of intervals, which is NP-hard:
lay a graph's vertices on the line, turn each edge `{u, v}` into a pin served
by exactly revisions `u` and `v`, and hitting every pin is a minimum vertex
cover.

So a pin takes the **newest** of its blocks and only that one. This is not a
new rule: `index/versions.json` records only the newest revision shipping each
version, and `mv.version`, `mvs lock add` and `multiverse.pins` already resolve
through it. It costs something in rare cases: of random pin sets containing a
holed pin, roughly 8% come out one revision larger than the true optimum over
all blocks, never more than one. What it buys is that the answer is always
exactly minimal for the blocks it considered, in `n log n`, with no solver.

### What minimising costs

A pin that shares a revision with another can end up on an older revision
inside its own version's run: the same version, an older build of it, carrying
that revision's closure.

Two details keep that cost as low as it can be. Each revision the sweep places
is the _newest_ one that can serve its whole group, and each pin then joins the
newest placed revision that serves it rather than the first. `pinPlan` and
`mvs solve` report the displacement per pin, in days and in revisions, before
anything is fetched.

Minimising is not useful the [fast path](./store-paths.md).
A pin the store-path index knows costs no fetch at all, so there is
nothing to group. Under `fastFallback = "eval"` the two compose without any
special handling.

---

For the longer version of this story, see the blog post:
[nixpkgs-multiverse: every version that ever
existed](https://fzakaria.com/2026/08/09/nixpkgs-multiverse-every-version-that-ever-existed).

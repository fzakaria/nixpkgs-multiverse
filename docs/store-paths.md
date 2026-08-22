# The store-path index

This is every indexed `(attribute, version)` pair, matched to the store path Hydra
built for it, which is what makes [`fast.*`](./nix-api.md#the-fast-path)
possible, and what the site's cache-liveness, dependency and closure views
draw from.

Two sources answer two different questions. **Evaluating** nixpkgs at a
revision and an explicit `system` says what the store path _is_; every
nixos-unstable channel bump's published listing (`store-paths.xz`, or a
`MANIFEST` for the 2012-2013 bumps) says whether Hydra _built_ it. Join the
two and every historical version gets a concrete
`/nix/store/<digest>-<name>` that [cache.nixos.org](https://cache.nixos.org)
can still serve.

## A path belongs to one system

A listing is a flat list of paths with no `System` column, and it holds every
system that channel bump was built for. At the 2026-08-17 tip that is 219,623
paths over 106,909 distinct derivation names: **98.4% of names appear more than
once**.

```
/nix/store/bf2z97cfq7x47y1dy50k04grkikmjcgg-hugo-0.164.0   <- aarch64-linux
/nix/store/zlyg48yqjd4jwz5yz3zhrnac81qgy7mh-hugo-0.164.0   <- x86_64-linux
```

So a listing cannot be asked _"which digest goes with this name"_ — there is no
answer to that question, and the index used to take whichever path sorted first
and hand x86*64 users aarch64 binaries about half the time
([#12](https://github.com/fzakaria/nixpkgs-multiverse/issues/12)). It can only
be asked *"is this exact digest one you hold"\_, which is a question with an
answer.

The artifacts are therefore **per system**: `outpaths-x86_64-linux.json`,
`outpaths-aarch64-linux.json`, `outpaths-aarch64-darwin.json`, and the same for
the tip and sibling-output files. A system with no artifacts is not served a
neighbour's — `fast.*` throws and names the eval selector instead.

The listings come from **nixos**-unstable, so they hold Linux paths and nothing
else: at the 2026-08-17 tip they named 23 of aarch64-darwin's 16,545 evaluated
paths, against 93.6% of x86_64-linux's. Darwin is carried entirely by the cache
probe below, and its coverage starts in 2021 — a 2019 nixpkgs cannot be
evaluated for `aarch64-darwin` at all.

The site follows the same rule. Its aggregate views — reverse dependencies, the
census, the universe map — are built from one system, and a package page shows
that system's store paths with a picker to switch between all of them, carried
in the URL as `?sys=` so a link names the system it was read on. The alternate system's
metadata lives in its own `meta-<system>/` shards and is fetched only when a
reader picks it, so a page nobody switches costs exactly what it did before.

## Resolving a pair

For each `(attribute, version)` pair, at the newest revision that shipped it:

1. evaluate that revision at this system and take the attribute's `outPath`
   (`nix/eval-outpaths.nix` under `nix-eval-jobs`, one file per revision and
   system);
2. keep the digest if the revision's listing holds it;
3. otherwise ask cache.nixos.org directly, since a listing describes one
   evaluation while the cache is the union of every jobset Hydra ever ran —
   `firefox` at the tip is in the cache and not in the listing, and every
   darwin path is in this class;
4. otherwise record a miss. Nothing is guessed: a pair with no proof carries no
   entry, and `fast.*` throws rather than substituting something plausible.

Across 2016 to the tip, 91.5-95.0% of the Linux systems' evaluated attributes
are in their revision's listing verbatim. The remainder is (a) attributes Hydra never built,
and (b) attributes this evaluation builds differently from Hydra, which sets
`allowUnfree = false` where the index sets it true — `hplipWithPlugin`,
`caffeWithCuda`, `_7zz-rar`. Under 0.3% of attributes per revision.

Class (a) is wider than "unfree or broken". `meta.hydraPlatforms = [ ]`
takes an attribute out of the jobset, and wrapper packages use it routinely
so Hydra does not rebuild a symlink farm.

## The digest is per version, not per revision

The index records **one digest per version**, taken at the newest revision that
shipped it. That is the build-correct choice: the most patched,
most recently built, most likely to still substitute, and it is why the
`fast.*` honesty classes read the way they do: exact-version selectors are
bit-exact, while revision selectors are version-exact but build-canonical
(the right version, as its newest build, which may come from a slightly
newer revision than the one named).

It is not per _branch_ either, which is why releases does not work.
Everything here is joined against nixos-unstable listings,
and a `(attribute, version)` pair names a different build on every branch.

A branch may have a different stdenv, different patches, or different build flags,
for a single package which bubbles up and changes the store path of nearly
every package, see [releases have no fast path](./nix-api.md#why-releases-have-no-fast-path).

## The census

A matched digest is a claim that the path substitutes. The census re-earns
that claim: for every indexed digest, GET the narinfo **and** HEAD the NAR
payload it points at — the cache remembering a path and the cache still
serving its bytes are different claims. The initial census verified 100.00%
of matched paths alive, down to every NAR payload file; a weekly workflow
([census.yml](../.github/workflows/census.yml)) repeats the sweep, publishes
the snapshot to the rolling release, and feeds any deaths back into the
artifacts so the site and `fast.*` stop advertising them.

## Multi-output packages

The listings record each derivation's _default_ output. But consumers
reference the other outputs (`ffmpeg-7.1-lib`, `ffmpeg-7.1-bin`), so the
dependency crawl already fetched their narinfos; joining them back gives
every multi-output package its sibling outputs with sizes and references.
Fakes expose them (`fast.latest.ffmpeg.lib`), and the site lists them.

`fast.*` reads these from `outs-<system>.json`, where they are **keyed by the
`out` path's digest**. Keying them by derivation name — as this file did before
the per-system split — let a name claimed by two packages, or by two
architectures, hand back somebody else's `lib`.

The evaluation reports every output of a derivation directly, so nothing here
depends on some consumer having referenced an output. The site's own
`outs-indexed` view still recovers siblings from closures, because it wants the
sizes and references the crawl collected; an output nothing referenced can be
missing there.

## Where the data lives

Three tiers, decided by one question: does anything pin it?

- **The repository tree** keeps only what evaluation reads offline:
  `revisions.json`, `releases.json`, the index files — and `data-pins.json`,
  which is the only thing evaluation-facing code ever sees of the store-path
  artifacts.
- **Dated releases** (`data-YYYYMMDD` tags on this repository) carry the
  pinned artifacts as assets: `outpaths-<system>.json` and
  `outs-<system>.json` whole (the fast path does point lookups and fetches
  exactly one small file — which is why the system is in the filename rather
  than a key inside each entry, so an x86_64 user never downloads the aarch64
  half), the
  graph artifacts (`info-indexed`, `refs-indexed`, `closures`) sharded by
  each digest's closing period — year files for finished years, month files
  for the current one — so a cut re-uploads only the shards that moved.
  Assets on a dated tag are immutable by convention; the narHash in each pin
  fails closed if the convention is ever violated. Consumers fetch with
  `builtins.fetchTree { type = "file"; ... }`, lazily, keeping this flake's
  `inputs = { }` founding line intact. `data-pins.json.baseUrl` is the canonical
  location; `fetchArtifact` points the fetch at a mirror, or at a
  local directory. The fetcher covers artifacts read by the multiverse API, not
  the publishing and restoration tools.
- **The rolling release** (`data-rolling`) carries the working state between
  cuts: the current `outpaths-<system>.json` and `tip-outpaths-<system>.json`,
  the census snapshots, the per-system miss lists, and the crawl graph the
  incremental jobs resume from. Every bump rewrites it; a dated cut freezes whatever it
  holds at the time.

A lagging pin is harmless by design: the delta between cuts is "versions
that closed since" — things that were current yesterday. A stale pin loses
the zero-eval fast path for exactly those versions, and the eval fallback
serves them meanwhile.

That property is why `tip-outpaths-<system>.json` is safe to pin at all, and why it
is read only as **keyed data** — `(attr, version) → digest` — never as a
statement about which revision is current. The dated cut happens on the
first data run of each UTC day and is skipped for the rest of it, so the
snapshot's own `revisionCount` falls behind `revisions.json` within hours.
Selectors resolve against `revisions.json`; this file only answers "do you
have a digest for this exact pair". An artifact claiming _more_ revisions
than `revisions.json` holds is refused outright, since it cannot be
describing the same history.

## The pipeline

The hourly [update-index workflow](../.github/workflows/update-index.yml)
appends a data pass after the index update, all of it incremental (the
scripts live in `tools/`, the evaluators they drive in `nix/`, and
`update-outpaths.sh` orchestrates them):

1. fetch the new bump's listing (`fetch-store-paths.py`);
2. evaluate the new revisions, once per published system
   (`eval-outpaths.sh`, two `nix-eval-jobs` workers on a standard runner);
3. join the two into digests (`join-eval-listing.py`: pairs that closed before
   the previous cut are carried over, only the delta is resolved);
4. crawl cache.nixos.org for the newly resolved digests and their transitive
   references (`crawl-narinfos.py`, resuming from the rolling crawl graph);
5. consolidate into the artifact files (`consolidate-outpaths.py`), with the
   previously published copies as fallback for digests this runner never
   crawled;
6. recover the site's sibling-output view (`extract-outputs.py`).

Once a day, the first run after a channel bump shards the artifacts by
closing period (`shard-data.py`), uploads whatever differs from its pin to a
dated tag, and repoints `data-pins.json` (`cut-data-release.sh`) — the one
pin-churn commit a day. No bump, no cut.

The one-time backfill — every listing, the full 1.4M-path crawl, and every
revision evaluated for every published system — runs on a big machine and seeds
the dated release; CI never re-runs it. The evaluation half is the expensive
one: 1,536 revisions × 3 systems, at roughly 20 (revision, system) pairs a
minute on a 256-core machine running 20 revisions at once. Adding a system is
that run for the new system alone.

## Credits

The fake-derivation technique that turns these digests into installables —
build an attrset that walks like a derivation and let `appendContext` give
its outPath real store context — is
[tomberek](https://github.com/tomberek)'s, from
[fastpkgs](https://github.com/tomberek/fastpkgs). The store-path index is
what lets it cover every version back to 2013.

# The store-path index

This is every indexed `(attribute, version)` pair, matched to the store path Hydra
built for it, which is what makes [`fast.*`](./nix-api.md#the-fast-path)
possible, and what the site's cache-liveness, dependency and closure views
draw from.

The idea is simple: every nixos-unstable channel bump published a listing of
every path Hydra built for it (`store-paths.xz`, or a `MANIFEST` in the
pre-2017 era). Those listings still exist. Join thirteen years of them
against the version index, and every historical version gets a concrete
`/nix/store/<digest>-<name>` that [cache.nixos.org](https://cache.nixos.org)
can still serve.

## Matching

A pair is looked up in the listing of the newest revision that shipped it,
by derivation name. Candidate names, in order:

1. the pname from the tip evaluation plus the version, which is what makes
   `python3` find `python3-3.12.4`;
2. `attr-version` verbatim;
3. `attr` with leading underscores stripped, lowercased, and with
   underscores replaced by dashes (`linux_hardened` → `linux-hardened`);
4. the bare pname, for the handful of unversioned derivation names.

A pair missing at its own offset walks backwards through its lifetime (the
history index's runs) and takes the newest revision whose listing has it,
since Hydra occasionally skips a package for weeks of bumps.

Any unmatched remainder is mostly (a) never-built unfree or broken attributes,
and (b) derivations absent from their era's listing (i.e. wrapper packages).
An unmatched pair under `fast.*` throws, naming the eval selector that still
 serves it.

## The digest is per version, not per revision

The index records **one digest per version**: the newest build of it that
any listing carried. That is the build-correct choice: the most patched,
most recently built, most likely to still substitute, and it is why the
`fast.*` honesty classes read the way they do: exact-version selectors are
bit-exact, while revision selectors are version-exact but build-canonical
(the right version, as its newest build, which may come from a slightly
newer revision than the one named).

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

The listings record each derivation's *default* output. But consumers
reference the other outputs (`ffmpeg-7.1-lib`, `ffmpeg-7.1-bin`), so the
dependency crawl already fetched their narinfos; joining them back gives
every multi-output package its sibling outputs with sizes and references.
Fakes expose them (`fast.latest.ffmpeg.lib`), and the site lists them.

The caveat: siblings are *recovered from consumers' closures*, not
enumerated from the derivation, so an output nothing ever referenced can be
missing. First-class `(attr, version, output)` rows are deliberately
deferred until the pipeline's next schema change.

## Where the data lives

Three tiers, decided by one question: does anything pin it?

- **The repository tree** keeps only what evaluation reads offline:
  `revisions.json`, `releases.json`, the index files — and `data-pins.json`,
  which is the only thing evaluation-facing code ever sees of the store-path
  artifacts.
- **Dated releases** (`data-YYYYMMDD` tags on this repository) carry the
  pinned artifacts as assets: `outpaths.json` and `outs.json` whole (the
  fast path does point lookups and fetches exactly one small file), the
  graph artifacts (`info-indexed`, `refs-indexed`, `closures`) sharded by
  each digest's closing period — year files for finished years, month files
  for the current one — so a cut re-uploads only the shards that moved.
  Assets on a dated tag are immutable by convention; the narHash in each pin
  fails closed if the convention is ever violated. Consumers fetch with
  `builtins.fetchTree { type = "file"; ... }`, lazily, keeping this flake's
  `inputs = { }` founding line intact.
- **The rolling release** (`data-rolling`) carries only what nothing may
  pin: `tip-outpaths.json` (rewritten as the channel moves — keyed,
  self-contained data whose staleness degrades to "no speedup", never to a
  wrong path), the census snapshots, the matcher's miss list, and the crawl
  graph the incremental jobs resume from.

A lagging pin is harmless by design: the delta between cuts is "versions
that closed since" — things that were current yesterday. A stale pin loses
the zero-eval fast path for exactly those versions, and the eval fallback
serves them meanwhile.

## The pipeline

The hourly [update-index workflow](../.github/workflows/update-index.yml)
appends a data pass after the index update, all of it incremental (the
scripts live in `tools/`, and `update-outpaths.sh` orchestrates them):

1. fetch the new bump's listing (`fetch-store-paths.py`);
2. extract `{attr → drv name}` at the tip (`extract-names.nix`), the pname
   source the matcher's candidates come from;
3. close versions and resolve digests (`match-outpaths.py --incremental`:
   already-closed matches are kept as-is, only the delta is resolved);
4. crawl cache.nixos.org for the newly matched digests and their transitive
   references (`crawl-narinfos.py`, resuming from the rolling crawl graph);
5. consolidate into the artifact files (`consolidate-outpaths.py`), with the
   previously published copies as fallback for digests this runner never
   crawled;
6. recover sibling outputs (`extract-outputs.py`).

Once a day, the first run after a channel bump shards the artifacts by
closing period (`shard-data.py`), uploads whatever differs from its pin to a
dated tag, and repoints `data-pins.json` (`cut-data-release.sh`) — the one
pin-churn commit a day. No bump, no cut.

The one-time backfill (every listing, the full 1.4M-path crawl, the
per-revision name evaluations) ran once on a big machine and seeded the
first dated release; CI never re-runs it.

## Credits

The fake-derivation technique that turns these digests into installables —
build an attrset that walks like a derivation and let `appendContext` give
its outPath real store context — is
[tomberek](https://github.com/tomberek)'s, from
[fastpkgs](https://github.com/tomberek/fastpkgs). The store-path index is
what lets it cover every version back to 2013.

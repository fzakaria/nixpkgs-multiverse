#!/usr/bin/env python3
"""Bake the committed JSON index into the SQLite database `mvs` reads.

The JSON files stay canonical: this is a pure projection of revisions.json,
releases.json, index/versions.json and index/history.json into a shape queries
can be written against. It is run from a derivation (`nix build .#index-db`),
never committed, so the database can never be older than the index it came
from.

One row per *run* — an unbroken stretch of revisions over which an attribute
held one version. 8.4% of (attr, version) pairs are non-contiguous, so
collapsing runs to "newest offset" would silently answer `at`, `solve` and
`diff` wrong.
"""

import glob
import gzip
import json
import os
import sqlite3
import sys

# The offsets in index/*.json are indices into revisions.json, so a database
# built from files that disagree about how many revisions exist would join rows
# that describe different revisions. Every input is checked against this.
USAGE = "build-db.py <root> <out.db> [--data-dir DIR]"

# A store path basename is `<digest>-<name>`: 32 characters of Nix base32,
# a dash, the name. The digest length is what splits a reference basename
# back into its two halves.
DIGEST_LEN = 32

SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE revisions(
  off     INTEGER PRIMARY KEY,   -- offset into revisions.json; the join key everywhere
  rev     TEXT NOT NULL,
  date    TEXT NOT NULL,
  name    TEXT,
  narhash TEXT
);
CREATE INDEX revisions_rev  ON revisions(rev);
CREATE INDEX revisions_date ON revisions(date);

CREATE TABLE releases(name TEXT PRIMARY KEY, rev TEXT, date TEXT, build INTEGER, channel_name TEXT);

CREATE TABLE attrs(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);

-- WITHOUT ROWID, keyed by attr_id, is what keeps the database smaller than the
-- JSON it comes from. Measured on the 331,307-run index:
--
--   rowid table + runs_attr + runs_span    16.1 MB
--   WITHOUT ROWID + runs_span              13.7 MB
--   WITHOUT ROWID, no secondary index       6.8 MB   <- this
--
-- The primary key doubles as the by-attribute index every hot query needs
-- (`versions`, `when`, `at`, `solve` all start from an attribute name), so a
-- separate runs_attr would be a second copy of the same ordering.
--
-- runs_span is dropped on purpose. It only helps the "every run covering
-- offset X" shape, which is `diff` and nothing else, and it half-scans anyway
-- because `first <= X` matches most of the table. The full scan it replaces
-- costs 35 ms, twice per diff.
CREATE TABLE runs(
  attr_id INTEGER NOT NULL REFERENCES attrs(id),
  version TEXT NOT NULL,
  first   INTEGER NOT NULL,
  last    INTEGER NOT NULL,
  PRIMARY KEY(attr_id, version, first)
) WITHOUT ROWID;
"""

# The store-path tables, created only under --data-dir. A database built
# without one has none of these, and `mvs` keys off the `store_paths` meta
# entry rather than probing for tables.
#
# Store paths are interned: (digest, name) once in store_paths, names once in
# store_names — a handful of glibcs and bashes are referenced by nearly every
# path, so repeating names per edge would dwarf everything else. References
# are then pure integer edges.
#
# Two indexes are dropped on purpose, the same trade runs_span makes above:
#
#   - no index on path_refs(dst): only `mvs rdeps` asks the reverse question,
#     once per invocation, and a scan of the edge table answers it.
#   - no index on store_paths(digest): it would cost 36 MB (measured, 873k
#     paths) to serve `mvs identify` and `mvs deps`' name fallback, each of
#     which is one scan per invocation.
STORE_SCHEMA = """
CREATE TABLE store_names(id INTEGER PRIMARY KEY, name TEXT NOT NULL);

CREATE TABLE store_paths(
  id      INTEGER PRIMARY KEY,
  digest  TEXT NOT NULL,            -- 32 chars of Nix base32; unique by construction
  name_id INTEGER REFERENCES store_names(id)  -- NULL for a bare digest seen only in refs
);

-- One row per (attr, version) pair whose store path is known: the digest it
-- built to, whether the pair is current at the index tip, and — when the
-- digest was found at an older offset than the pair's newest run — where.
CREATE TABLE pairs(
  attr_id   INTEGER NOT NULL REFERENCES attrs(id),
  version   TEXT NOT NULL,
  path_id   INTEGER NOT NULL REFERENCES store_paths(id),
  tip       INTEGER NOT NULL,       -- 1 when current at the index tip
  found_off INTEGER,                -- offset the digest was found at, when it differs
  PRIMARY KEY(attr_id, version)
) WITHOUT ROWID;

-- Cache facts per store path: narinfo liveness and sizes, closure totals.
-- path_id is the rowid, so this table carries no index of its own.
CREATE TABLE path_info(
  path_id       INTEGER PRIMARY KEY,
  live          INTEGER,            -- 1 while the path is still in the binary cache
  nar_size      INTEGER,            -- unpacked NAR bytes
  file_size     INTEGER,            -- compressed download bytes
  closure_bytes INTEGER,
  closure_paths INTEGER,
  closure_dead  INTEGER             -- closure members no longer in the cache
);

CREATE TABLE path_refs(
  src INTEGER NOT NULL,             -- store_paths.id of the referrer
  dst INTEGER NOT NULL,             -- store_paths.id of the reference
  PRIMARY KEY(src, dst)
) WITHOUT ROWID;

-- Sibling outputs of multi-output packages, keyed by derivation name because
-- that is how the artifact records them — the same drv name can build to
-- different digests across revisions, and the artifact keeps one entry.
CREATE TABLE outputs(
  drv_name_id INTEGER NOT NULL REFERENCES store_names(id),
  suffix      TEXT NOT NULL,        -- "dev", "lib", "man", ...
  path_id     INTEGER NOT NULL REFERENCES store_paths(id),
  nar_size    INTEGER,
  PRIMARY KEY(drv_name_id, suffix)
) WITHOUT ROWID;
"""


def runs_of(value, tip):
    """Normalise a history entry to a list of [first, last] runs.

    build-history.sh writes the common single-run case as a bare [first, last]
    pair and only nests when a version came back after leaving. A run still open
    at the newest revision the file covers ends in null rather than in that
    offset, which is what keeps an append from rewriting every unchanged version
    — see docs/design.md. It is closed here, so the `last INTEGER NOT NULL`
    column and everything reading it are unaffected.
    """
    runs = [value] if value and isinstance(value[0], int) else value
    return [[first, tip if last is None else last] for first, last in runs]


def parse_args(argv):
    """`<root> <out.db>` plus an optional `--data-dir DIR` anywhere."""
    args = list(argv[1:])

    data_dir = None
    if "--data-dir" in args:
        at = args.index("--data-dir")
        if at + 1 >= len(args):
            sys.exit(USAGE)
        data_dir = args[at + 1]
        del args[at : at + 2]

    if len(args) != 2:
        sys.exit(USAGE)
    return args[0], args[1], data_dir


def load_artifact(data_dir, stem):
    """Merge every shard of one artifact into a single dict.

    The gz artifacts may be sharded by period — refs-indexed-2024.json.gz,
    refs-indexed-2026-08.json.gz — instead of whole, so everything matching
    `<stem>*.json.gz` is merged, in filename order. Plain `<stem>*.json`
    shards are accepted too, which is what the tests write.
    """
    shards = sorted(
        glob.glob(os.path.join(data_dir, stem + "*.json.gz"))
        + glob.glob(os.path.join(data_dir, stem + "*.json"))
    )
    if not shards:
        sys.exit(f"build-db: no {stem}*.json.gz in {data_dir}")

    merged = {}
    for shard in shards:
        opener = gzip.open if shard.endswith(".gz") else open
        with opener(shard, "rt") as f:
            merged.update(json.load(f))
    return merged


def pair_fields(attr, version, value):
    """Unpack an outpaths entry: `[digest, drvNameIfDiffers?, offsetIfDiffers?]`.

    The derivation name defaults to `<attr>-<version>` and is only written out
    when it differs; likewise the offset the digest was found at. The two
    optional fields are told apart by type, not position, so either may appear
    alone.
    """
    drv_name = f"{attr}-{version}"
    found_off = None
    for extra in value[1:]:
        if isinstance(extra, str):
            drv_name = extra
        else:
            found_off = extra
    return value[0], drv_name, found_off


def build_store(db, data_dir, attr_ids, n_revs):
    """Project the store-path artifacts into the store tables.

    Returns (paths, edges) counts for the summary line.
    """

    def load_json(name):
        with open(os.path.join(data_dir, name)) as f:
            return json.load(f)

    outpaths = load_json("outpaths.json")
    tip_outpaths = load_json("tip-outpaths.json")
    info = load_artifact(data_dir, "info-indexed")
    refs = load_artifact(data_dir, "refs-indexed")
    closures = load_artifact(data_dir, "closures")
    outs = load_artifact(data_dir, "outs-indexed")

    # The same offset invariant as the history check in main(): found offsets
    # index into revisions.json, and the two outpaths files must agree with
    # each other about how much they cover.
    if outpaths["revisionCount"] != tip_outpaths["revisionCount"]:
        sys.exit(
            f"build-db: outpaths.json covers {outpaths['revisionCount']} revisions "
            f"but tip-outpaths.json covers {tip_outpaths['revisionCount']}. "
            f"Rebuild the store-path artifacts together."
        )
    if outpaths["revisionCount"] > n_revs:
        sys.exit(
            f"build-db: outpaths.json was built against {outpaths['revisionCount']} "
            f"revisions but revisions.json has {n_revs}."
        )

    db.executescript(STORE_SCHEMA)

    # Intern every digest once, keeping the best name seen for it. Sources are
    # processed most-authoritative first — narinfo names, then derivation
    # names, then reference basenames — and a later, worse name never
    # overwrites an earlier one.
    path_name = {}

    def intern(digest, name=None):
        if digest not in path_name or (name is not None and path_name[digest] is None):
            path_name[digest] = name

    for digest, (_, _, _, name, _) in info.items():
        intern(digest, name)

    # (attr, version) -> (digest, drv_name, found_off, tip). Closed pairs
    # first, tip pairs second: a pair somehow in both is described by its tip
    # entry, which is the digest a user materialising it today would get.
    pairs = {}
    for tip, source in ((0, outpaths["attrs"]), (1, tip_outpaths["attrs"])):
        for attr, versions in source.items():
            for version, value in versions.items():
                digest, drv_name, found_off = pair_fields(attr, version, value)
                pairs[(attr, version)] = (digest, drv_name, found_off, tip)
                intern(digest, drv_name)

    # A sibling output's store name is the derivation name plus its suffix:
    # cups-2.4.2's dev output lives at <digest>-cups-2.4.2-dev.
    for drv_name, siblings in outs.items():
        for suffix, digest, _, _ in siblings:
            intern(digest, f"{drv_name}-{suffix}")

    # Reference basenames carry their own names; the occasional bare digest
    # interns nameless and picks a name up later if any source has one.
    for digest, targets in refs.items():
        intern(digest)
        for basename in targets:
            intern(basename[:DIGEST_LEN], basename[DIGEST_LEN + 1 :] or None)
    for siblings in outs.values():
        for _, _, _, out_refs in siblings:
            for digest in out_refs:
                intern(digest)
    for digest in closures:
        intern(digest)

    # Assign the integer ids everything else joins on.
    path_ids = {digest: i for i, digest in enumerate(path_name, start=1)}

    name_ids = {}

    def name_id(name):
        if name is None:
            return None
        if name not in name_ids:
            name_ids[name] = len(name_ids) + 1
        return name_ids[name]

    db.executemany(
        "INSERT INTO store_paths(id, digest, name_id) VALUES (?,?,?)",
        ((path_ids[d], d, name_id(n)) for d, n in path_name.items()),
    )

    # An attribute can appear in the outpaths without ever entering history —
    # matching ran against more data than versions.json keeps — so unseen
    # attributes are added rather than dropped on the floor.
    def attr_id(name):
        if name not in attr_ids:
            attr_ids[name] = len(attr_ids) + 1
            db.execute("INSERT INTO attrs(id, name) VALUES (?,?)", (attr_ids[name], name))
        return attr_ids[name]

    db.executemany(
        "INSERT INTO pairs(attr_id, version, path_id, tip, found_off) VALUES (?,?,?,?,?)",
        (
            (attr_id(attr), version, path_ids[digest], tip, found_off)
            for (attr, version), (digest, _, found_off, tip) in pairs.items()
        ),
    )

    # Cache facts: narinfo fields and closure totals share a row per path.
    def info_rows():
        for digest in info.keys() | closures.keys():
            narinfo = info.get(digest)
            closure = closures.get(digest)
            yield (
                path_ids[digest],
                narinfo[0] if narinfo else None,
                narinfo[1] if narinfo else None,
                narinfo[2] if narinfo else None,
                closure[0] if closure else None,
                closure[1] if closure else None,
                closure[2] if closure else None,
            )

    db.executemany(
        "INSERT INTO path_info(path_id, live, nar_size, file_size,"
        " closure_bytes, closure_paths, closure_dead) VALUES (?,?,?,?,?,?,?)",
        info_rows(),
    )

    # Every reference as an integer edge — the primary paths' references and
    # the sibling outputs' alike, since both are questions `mvs deps` answers.
    # OR IGNORE: a source repeated across shards would repeat its edges.
    def edges():
        for digest, targets in refs.items():
            src = path_ids[digest]
            for basename in targets:
                yield (src, path_ids[basename[:DIGEST_LEN]])
        for siblings in outs.values():
            for _, digest, _, out_refs in siblings:
                src = path_ids[digest]
                for ref in out_refs:
                    yield (src, path_ids[ref])

    db.executemany("INSERT OR IGNORE INTO path_refs(src, dst) VALUES (?,?)", edges())

    db.executemany(
        "INSERT INTO outputs(drv_name_id, suffix, path_id, nar_size) VALUES (?,?,?,?)",
        (
            (name_id(drv_name), suffix, path_ids[digest], nar_size)
            for drv_name, siblings in outs.items()
            for suffix, digest, nar_size, _ in siblings
        ),
    )

    # Names last: name_id() hands out ids up to the final outputs insert.
    db.executemany(
        "INSERT INTO store_names(id, name) VALUES (?,?)",
        ((i, name) for name, i in name_ids.items()),
    )

    n_edges = db.execute("SELECT count(*) FROM path_refs").fetchone()[0]
    return len(path_ids), n_edges


def main():
    root, out, data_dir = parse_args(sys.argv)

    def load(*parts):
        with open(os.path.join(root, *parts)) as f:
            return json.load(f)

    revisions = load("revisions.json")
    releases = load("releases.json")
    history = load("index", "history.json")

    # The offset invariant, the same one multiverse.nix asserts at eval time: an
    # index built against more revisions than revisions.json holds would index
    # past the end of the array, and one built against fewer is merely stale.
    n_revs = len(revisions)
    if history["revisionCount"] > n_revs:
        sys.exit(
            f"build-db: index/history.json was built against "
            f"{history['revisionCount']} revisions but revisions.json has "
            f"{n_revs}. Re-run tools/build-history.sh."
        )

    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript(SCHEMA)

    db.executemany(
        "INSERT INTO revisions(off, rev, date, name, narhash) VALUES (?,?,?,?,?)",
        (
            (i, r["rev"], r["date"], r.get("name"), r.get("narHash"))
            for i, r in enumerate(revisions)
        ),
    )

    db.executemany(
        "INSERT INTO releases(name, rev, date, build, channel_name) VALUES (?,?,?,?,?)",
        (
            (name, r["rev"], r["date"], r.get("build"), r.get("name"))
            for name, r in releases.items()
        ),
    )

    # Attribute names are interned: repeating each of the ~31,800 names once per
    # run would be most of the database.
    attr_ids = {}
    for name in sorted(history["attrs"]):
        attr_ids[name] = len(attr_ids) + 1
    db.executemany(
        "INSERT INTO attrs(id, name) VALUES (?,?)",
        ((i, name) for name, i in attr_ids.items()),
    )

    # Against history's own revisionCount, not len(revisions): a revision
    # appended since the last indexing run is one the history has never looked
    # at, so no run of it can be open there.
    tip = history["revisionCount"] - 1

    def all_runs():
        for attr, versions in history["attrs"].items():
            attr_id = attr_ids[attr]
            for version, value in versions.items():
                for first, last in runs_of(value, tip):
                    yield (attr_id, version, first, last)

    db.executemany("INSERT INTO runs(attr_id, version, first, last) VALUES (?,?,?,?)", all_runs())

    # The store-path tables only exist when the artifacts were given; without
    # them the database is exactly what it always was, and `mvs` refuses the
    # store subcommands by the absence of the `store_paths` meta key.
    store_counts = None
    if data_dir is not None:
        store_counts = build_store(db, data_dir, attr_ids, n_revs)

    # `built_from` names the checkout the data came from, so a database found on
    # its own can be traced back. The flake passes self.rev; a dirty tree has
    # nothing honest to say and leaves it unset.
    meta = {
        "schema": "1",
        "revisionCount": str(history["revisionCount"]),
        "revisionsInFile": str(n_revs),
        "skipped": json.dumps(history.get("skipped", [])),
    }
    if store_counts is not None:
        meta["store_paths"] = "1"
    if os.environ.get("MVS_BUILT_FROM"):
        meta["built_from"] = os.environ["MVS_BUILT_FROM"]
    db.executemany("INSERT INTO meta(key, value) VALUES (?,?)", meta.items())

    db.commit()
    db.execute("VACUUM")
    db.execute("ANALYZE")
    db.commit()

    n_runs = db.execute("SELECT count(*) FROM runs").fetchone()[0]
    store = ""
    if store_counts is not None:
        n_paths, n_edges = store_counts
        store = f", {n_paths} store paths, {n_edges} refs"
    print(
        f"built {out}: {n_revs} revisions, {len(attr_ids)} attrs, {n_runs} runs{store}, "
        f"{os.path.getsize(out) / 1e6:.1f} MB"
    )
    db.close()


if __name__ == "__main__":
    main()

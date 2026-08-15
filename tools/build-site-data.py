#!/usr/bin/env python3
"""Build the site's store-data products from the pinned data artifacts.

Usage: build-site-data.py <repo> <datadir> <out>
  repo:    the nixpkgs-multiverse checkout (revisions.json, index/)
  datadir: outpaths.json, tip-outpaths.json, outs-indexed.json.gz, and the
           graph artifacts either whole (info-indexed.json.gz, ...) or as
           period shards (info-indexed-2024.json.gz, ...) — every file
           matching <stem>*.json.gz is merged
  out:     the site tree to write into

Emits, beside whatever the rest of the site build produces:
  meta/<shard>.json      per-attr store entries: digest, liveness, sizes,
                         closure, interned direct deps, sibling outputs
  revdeps/<shard>.json   reverse dependencies, capped per version
  identify/<xx>.json     digest -> [attr, version], sharded by digest prefix
  census.json            the aliveness census aggregates the stats page draws
  universe.bin           every measured version as one dot (see below)

The census `at` field is the index tip's date, not today: the build runs in a
sandbox with no clock worth trusting, and the data is only as fresh as the
newest revision it covers anyway.
"""
import glob
import gzip
import json
import os
import statistics
import struct
import sys
from collections import defaultdict

# Multi-output suffixes recognised when resolving a reference like
# ffmpeg-7.1-lib back to the indexed ffmpeg 7.1.
OUTPUT_SUFFIXES = {
    "lib", "bin", "dev", "out", "doc", "man", "info", "data", "debug",
    "static", "terminfo", "py", "dist",
}

# How many reverse dependencies a version keeps in its shard; the count is
# recorded in full either way.
REVDEP_CAP = 200

# How many rows each census leaderboard keeps.
LEADERBOARD_ROWS = 200

DIGEST_LEN = 32

repo, datadir, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)

J = lambda *p: os.path.join(*p)
load = lambda p: json.load(open(p))


def dump(obj, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(obj, open(path, "w"), separators=(",", ":"), sort_keys=True)


def shard_key(attr):
    return "".join(c if c.isalnum() else "_" for c in attr[:2].lower()) or "_"


def load_stem(stem):
    """Merge <stem>.json.gz / <stem>-<period>.json.gz — whichever exist."""
    merged = {}
    files = sorted(glob.glob(J(datadir, f"{stem}*.json.gz")))
    if not files:
        print(f"NOTE: no {stem} files, building without them")
        return merged
    for p in files:
        merged.update(json.load(gzip.open(p, "rt")))
    return merged


# ---- repo data: versions/history with the open tip closed -------------------
revisions = load(J(repo, "revisions.json"))
versions = load(J(repo, "index", "versions.json"))
history = load(J(repo, "index", "history.json"))
TIPOFF = versions["revisionCount"] - 1


def close_tip(data):
    tip = data["revisionCount"] - 1

    def close(value):
        if value is None:
            return tip
        if isinstance(value, list):
            if value and isinstance(value[0], list):
                return [close(run) for run in value]
            first, last = value
            return [first, tip if last is None else last]
        return value

    data["attrs"] = {
        attr: {v: close(val) for v, val in vers.items()}
        for attr, vers in data["attrs"].items()
    }
    return data


versions_closed = close_tip(versions)
history_closed = close_tip(history)
vattrs = versions_closed["attrs"]

# ---- the data artifacts -----------------------------------------------------
outpaths = load(J(datadir, "outpaths.json"))
tips = load(J(datadir, "tip-outpaths.json"))
info = load_stem("info-indexed")
refs = load_stem("refs-indexed")
closures = load_stem("closures")
# drv name -> [[suffix, digest, narSize, [ref basenames]], ...]: the sibling
# outputs of multi-output packages, recovered from consumers' closures.
outs = load_stem("outs-indexed")

# digest -> (attr, ver). Aliased attrs share a digest; the shortest name is
# the closest thing to canonical.
by_digest = {}
by_name = {}
pairs = {}  # (attr, ver) -> (digest, name, is_tip)
for src, is_tip in ((outpaths, False), (tips, True)):
    for attr, vers in src["attrs"].items():
        for ver, entry in vers.items():
            digest = entry[0]
            name = entry[1] if len(entry) > 1 else f"{attr}-{ver}"
            pairs[(attr, ver)] = (digest, name, is_tip)
            for table, key in ((by_digest, digest), (by_name, name)):
                cur = table.get(key)
                if cur is None or len(attr) < len(cur[0]):
                    table[key] = (attr, ver)


def resolve(digest, name):
    """A reference back to an indexed (attr, version). Exact digest first —
    then by derivation name, which also catches the SAME version built at a
    different revision (consumers link the build from their own revision, not
    the newest one this index records) — then by name with a multi-output
    suffix stripped, so a ref to ffmpeg-7.1-lib still reads as ffmpeg 7.1."""
    hit = by_digest.get(digest) or by_name.get(name)
    if hit:
        return hit
    base, _, suffix = name.rpartition("-")
    if suffix in OUTPUT_SUFFIXES:
        return by_name.get(base)
    return None


print(f"{len(pairs)} pairs with digests, {len(by_digest)} distinct digests")

# ---- meta shards -----------------------------------------------------------
# Per shard: an interned table of reference targets and per-version entries.
class MetaShard:
    def __init__(self):
        self.paths = []
        self.idx = {}
        self.attrs = defaultdict(dict)


meta_buckets = defaultdict(MetaShard)
revdeps = defaultdict(lambda: defaultdict(set))  # tattr -> tver -> {(a,v)}

for (attr, ver), (digest, name, is_tip) in pairs.items():
    b = meta_buckets[shard_key(attr)]
    inf = info.get(digest)
    cl = closures.get(digest)
    entry = {"d": digest}
    if name != f"{attr}-{ver}":
        entry["n"] = name
    if inf:
        ok, ns, fs = inf[0], inf[1], inf[2]
        entry["ok"] = ok
        if ns:
            entry["ns"] = ns
        if fs:
            entry["fs"] = fs
    if cl:
        entry["cs"], entry["cn"] = cl[0], cl[1]

    def add_refs(rlist):
        r_idx = []
        for base in rlist:
            rd, rn = base[:DIGEST_LEN], (base[DIGEST_LEN + 1 :] or base[:DIGEST_LEN])
            hit = resolve(rd, rn)
            key = (rn, hit[0] if hit else None, hit[1] if hit else None)
            i = b.idx.get(key)
            if i is None:
                i = len(b.paths)
                b.idx[key] = i
                b.paths.append([rn, *hit] if hit else [rn])
            r_idx.append(i)
            if hit and hit != (attr, ver):
                revdeps[hit[0]][hit[1]].add((attr, ver))
        return r_idx

    rlist = refs.get(digest)
    if rlist:
        entry["r"] = add_refs(rlist)

    # Multi-output packages: surface the sibling outputs, and when the
    # default output is an empty stub (ffmpeg's 96-byte `out`), borrow the
    # richest sibling's references so the page still shows real deps.
    sibs = outs.get(name)
    if sibs:
        entry["o"] = [[s, sz] for s, _, sz, _ in sibs]
        if not rlist:
            richest = max(sibs, key=lambda x: len(x[3]))
            own = {name} | {f"{name}-{s}" for s, _, _, _ in sibs}
            sib_refs = [x for x in richest[3] if x[DIGEST_LEN + 1 :] not in own]
            if sib_refs:
                entry["r"] = add_refs(sib_refs)
                entry["rsrc"] = richest[0]
    b.attrs[attr][ver] = entry

os.makedirs(J(out, "meta"), exist_ok=True)
for key, b in meta_buckets.items():
    dump({"paths": b.paths, "attrs": b.attrs}, J(out, "meta", key + ".json"))
print(f"meta: {len(meta_buckets)} shards")

# ---- revdeps shards --------------------------------------------------------
rd_buckets = defaultdict(dict)
for tattr, tvers in revdeps.items():
    rd_buckets[shard_key(tattr)][tattr] = {
        tver: {"c": len(deps), "l": [list(d) for d in sorted(deps)[:REVDEP_CAP]]}
        for tver, deps in tvers.items()
    }
os.makedirs(J(out, "revdeps"), exist_ok=True)
for key, attrs in rd_buckets.items():
    dump({"attrs": attrs}, J(out, "revdeps", key + ".json"))
print(f"revdeps: {len(rd_buckets)} shards")

# ---- identify shards -------------------------------------------------------
id_buckets = defaultdict(dict)
for digest, (attr, ver) in by_digest.items():
    id_buckets[digest[:2]][digest] = [attr, ver]
os.makedirs(J(out, "identify"), exist_ok=True)
for key, entries in id_buckets.items():
    dump(entries, J(out, "identify", key + ".json"))
print(f"identify: {len(id_buckets)} shards")

# ---- census ---------------------------------------------------------------
year_of = {}
for (attr, ver), (digest, _, is_tip) in pairs.items():
    off = vattrs.get(attr, {}).get(ver)
    year_of[(attr, ver)] = (
        revisions[off]["date"][:4] if off is not None else revisions[TIPOFF]["date"][:4]
    )

by_year = defaultdict(lambda: {"pairs": 0, "alive": 0, "aliveBytes": 0})
bloat = defaultdict(lambda: {"ns": [], "cs": [], "nd": [], "cn": []})
alive_total = alive_bytes = 0
dead_list = []
sizes_by_attr = defaultdict(list)
for (attr, ver), (digest, _, is_tip) in pairs.items():
    inf = info.get(digest)
    if not inf:
        continue
    y = year_of[(attr, ver)]
    ok, ns = inf[0], inf[1] or 0
    by_year[y]["pairs"] += 1
    if ok:
        by_year[y]["alive"] += 1
        by_year[y]["aliveBytes"] += ns
        alive_total += 1
        alive_bytes += ns
    elif ns:
        dead_list.append((attr, ver, ns))
    if ns:
        bloat[y]["ns"].append(ns)
        off = vattrs.get(attr, {}).get(ver)
        sizes_by_attr[attr].append((TIPOFF if off is None else off, ver, ns))
    rl = refs.get(digest)
    if rl is not None:
        bloat[y]["nd"].append(len(rl))
    cl = closures.get(digest)
    if cl and cl[0]:
        bloat[y]["cs"].append(cl[0])
        bloat[y]["cn"].append(cl[1])

# The single version bumps that gained the most weight: consecutive versions
# of one attribute in shipping order, ranked by NAR delta.
jumps = []
for attr, lst in sizes_by_attr.items():
    lst.sort()
    for (o1, v1, n1), (o2, v2, n2) in zip(lst, lst[1:]):
        jumps.append((attr, v1, v2, n2 - n1, o2))
jumps.sort(key=lambda x: -x[3])

# The immortals: versions still shipping today whose current run started
# longest ago.
immortals = []
for attr, vers in history_closed["attrs"].items():
    for ver, h in vers.items():
        runs = [h] if h and not isinstance(h[0], list) else (h or [])
        if not runs:
            continue
        first, last = runs[-1]
        if last == TIPOFF and (attr, ver) in pairs:
            immortals.append((attr, ver, revisions[first]["date"]))
immortals.sort(key=lambda x: x[2])

tip_pairs = [(a, v) for (a, v), (_, _, t) in pairs.items() if t]
top_closures = sorted(
    (
        (a, v, closures[pairs[(a, v)][0]][0])
        for a, v in tip_pairs
        if pairs[(a, v)][0] in closures
    ),
    key=lambda x: -x[2],
)[:LEADERBOARD_ROWS]

# Most depended-upon: current versions ranked by recorded dependents.
dep_counts = []
for a, v in tip_pairs:
    n = len(revdeps.get(a, {}).get(v, ()))
    if n:
        dep_counts.append((a, n))
dep_counts.sort(key=lambda x: -x[1])

census = {
    "at": revisions[TIPOFF]["date"],
    "totals": {
        "universe": sum(len(v) for v in vattrs.values()),
        "pairs": len(pairs),
        "matched": sum(1 for p in pairs.values() if p[0] in info),
        "alive": alive_total,
        "aliveBytes": alive_bytes,
    },
    "byYear": [{"y": y, **c} for y, c in sorted(by_year.items())],
    "bloat": [
        {
            "y": y,
            "medianNs": int(statistics.median(b["ns"])) if b["ns"] else None,
            "medianCs": int(statistics.median(b["cs"])) if b["cs"] else None,
            "medianNd": statistics.median(b["nd"]) if b["nd"] else None,
            "medianCn": statistics.median(b["cn"]) if b["cn"] else None,
            "n": len(b["ns"]),
        }
        for y, b in sorted(bloat.items())
    ],
    "topClosures": top_closures,
    "topDeps": dep_counts[:LEADERBOARD_ROWS],
    "biggestDead": sorted(dead_list, key=lambda x: -x[2])[:LEADERBOARD_ROWS],
    "immortals": [list(x) for x in immortals[:LEADERBOARD_ROWS]],
    "jumps": [[a, v1, v2, d] for a, v1, v2, d, _ in jumps[:LEADERBOARD_ROWS]],
}
dump(census, J(out, "census.json"))
print("census written")

# ---- the universe: every measured version as one dot ------------------------
# A binary sidecar the stats page draws on canvas: per version its lifetime
# [first, last] as uint16 revision offsets, its NAR size as uint32, and an
# index into the attribute name table. ~9 bytes a dot.
hist_u = history_closed["attrs"]
uni_names, uni_idx = [], {}
firsts, lasts, usizes, attr_is, ver_strs = [], [], [], [], []
for (attr, ver), (digest, _, is_tip) in sorted(pairs.items()):
    inf = info.get(digest)
    if not inf or not inf[1]:
        continue
    h = hist_u.get(attr, {}).get(ver)
    if h:
        runs = [h] if not isinstance(h[0], list) else h
        first = min(r[0] for r in runs)
        last = max(r[1] for r in runs)
    else:
        off = vattrs.get(attr, {}).get(ver)
        first = last = TIPOFF if off is None else off
    ai = uni_idx.setdefault(attr, len(uni_names))
    if ai == len(uni_names):
        uni_names.append(attr)
    firsts.append(first)
    lasts.append(last)
    usizes.append(min(inf[1], 2**32 - 1))
    attr_is.append(ai)
    ver_strs.append(ver)

n = len(firsts)
with open(J(out, "universe.bin"), "wb") as f:
    f.write(struct.pack("<I", n))
    f.write(struct.pack(f"<{n}H", *firsts))
    f.write(struct.pack(f"<{n}H", *lasts))
    f.write(struct.pack(f"<{n}I", *usizes))
    f.write(struct.pack(f"<{n}H", *attr_is))
dump({"attrs": uni_names, "versions": ver_strs}, J(out, "universe-meta.json"))
print(f'universe: {n} dots, {os.path.getsize(J(out, "universe.bin")):,} bytes binary')

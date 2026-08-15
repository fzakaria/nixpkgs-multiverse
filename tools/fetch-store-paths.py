#!/usr/bin/env python3
"""Fetch the channel's store-path listing for named revisions.

Every nixos-unstable channel bump published a store-paths.xz (or, in the
pre-2017 era, a MANIFEST) listing every path Hydra built for it. Each named
revision in revisions.json is fetched into a per-offset pickle of
{drv name -> store digest} under the paths directory.

MANIFEST-era files also carry NarSize/Size/References/System per path; those
are saved alongside so the old era needs no narinfo crawl at all. Only
x86_64-linux entries are kept from manifests (store-paths.xz era files are
x86_64-only already).

Incremental by construction: an offset whose pickle already exists is
skipped, so the hourly job pays for exactly the bumps it has never seen.
"""
import argparse
import bz2
import json
import lzma
import os
import pickle
import re
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

RELEASES_BASE = "https://nix-releases.s3.amazonaws.com/nixos/unstable/"
STORE_PREFIX = "/nix/store/"
DIGEST_LEN = 32
USER_AGENT = "nixpkgs-multiverse"
TIMEOUT_SECONDS = 120


def split_base(path):
    """/nix/store/<digest>-<name> -> (digest, name)."""
    base = path[len(STORE_PREFIX) :]
    return base[:DIGEST_LEN], base[DIGEST_LEN + 1 :]


def parse_storepaths(raw):
    m = {}
    for line in lzma.decompress(raw).decode().splitlines():
        line = line.strip()
        if not line.startswith(STORE_PREFIX):
            continue
        digest, name = split_base(line)
        m.setdefault(name, digest)
    return m, None


MANIFEST_FIELD = re.compile(
    r"^\s*(StorePath|NarURL|Size|NarSize|References|System):\s*(.*)$"
)


def parse_manifest(text):
    m, meta, cur = {}, {}, {}
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.endswith("{"):
            cur = {}
        elif stripped == "}":
            sp = cur.get("StorePath")
            if sp and cur.get("System", "x86_64-linux") == "x86_64-linux":
                digest, name = split_base(sp)
                m.setdefault(name, digest)
                refs = [
                    split_base(p)
                    for p in cur.get("References", "").split()
                    if p.startswith(STORE_PREFIX)
                ]
                meta[digest] = {
                    "narSize": int(cur["NarSize"]) if cur.get("NarSize") else None,
                    "fileSize": int(cur["Size"]) if cur.get("Size") else None,
                    "narUrl": cur.get("NarURL"),
                    "refs": refs,
                }
        else:
            f = MANIFEST_FIELD.match(line)
            if f:
                cur[f.group(1)] = f.group(2)
    return m, meta


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as r:
        return r.read()


def fetch(outdir, job):
    off, r = job
    out = f"{outdir}/{off}.pkl"
    if os.path.exists(out):
        return off, "cached"

    # store-paths.xz first; 404 falls back through the two MANIFEST spellings
    # the pre-2017 channels used.
    prefix = RELEASES_BASE + r["name"] + "/"
    try:
        try:
            m, meta = parse_storepaths(get(prefix + "store-paths.xz"))
            kind = "store-paths"
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            try:
                text = bz2.decompress(get(prefix + "MANIFEST.bz2")).decode()
            except urllib.error.HTTPError as e2:
                if e2.code != 404:
                    raise
                text = get(prefix + "MANIFEST").decode()
            m, meta = parse_manifest(text)
            kind = "manifest"
    except Exception as e:
        return off, f"FAIL {e}"

    with open(out + ".tmp", "wb") as f:
        pickle.dump({"names": m, "meta": meta, "kind": kind}, f, protocol=4)
    os.replace(out + ".tmp", out)
    return off, f"{kind} {len(m)}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--revisions", required=True, help="revisions.json")
    ap.add_argument("--outdir", required=True, help="per-offset pickle directory")
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument(
        "--min-offset",
        type=int,
        default=0,
        help="skip revisions below this offset — the hourly job passes the "
        "previous artifacts' coverage so a fresh runner fetches only the new "
        "bumps, not thirteen years of listings",
    )
    ap.add_argument(
        "--limit", type=int, default=0, help="fetch at most this many (smoke test)"
    )
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    revs = json.load(open(args.revisions))

    # Only revisions with a channel name have a listing to fetch; the cached
    # ones cost a stat each, so an up-to-date run is effectively free.
    jobs = [
        (i, r)
        for i, r in enumerate(revs)
        if r.get("name") and i >= args.min_offset
    ]
    jobs = [j for j in jobs if not os.path.exists(f"{args.outdir}/{j[0]}.pkl")]
    if args.limit:
        jobs = jobs[: args.limit]
    print(f"{len(jobs)} listings to fetch", flush=True)

    fails = 0
    with ThreadPoolExecutor(args.threads) as ex:
        for i, (off, status) in enumerate(
            ex.map(lambda j: fetch(args.outdir, j), jobs)
        ):
            if status.startswith("FAIL"):
                fails += 1
                print(f"{off} {revs[off]['name']} {status}", flush=True)
            if i and i % 100 == 0:
                print(f"... {i}/{len(jobs)}", file=sys.stderr, flush=True)
    print(f"done: {len(jobs)} fetched, {fails} failures", flush=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

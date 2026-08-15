#!/usr/bin/env python3
"""Crawl cache.nixos.org narinfos for every matched digest, then BFS the
References graph until closed (or the budget runs out).

Wave 0 is every digest named by the seed files (outpaths.json,
tip-outpaths.json) not already in the graph. Each narinfo's References names
more digests; each following wave crawls the ones not seen yet. The result is
the full dependency graph of every indexed version.

State is one file, --graph (jsonl.gz), one record per crawled digest:

  {"d": digest, "ok": bool, "name": basename-after-digest or null,
   "ns": NarSize, "fs": FileSize, "url": nar url, "refs": [digest, ...]}

The file is loaded to know what has been crawled and appended to as waves
finish (concatenated gzip streams are a valid gzip file), so a run resumes
where the last one stopped and the hourly job pays only for digests it has
never seen. --recheck-dead re-fetches seed digests recorded as dead, for
liveness refreshes.
"""
import argparse
import gzip
import http.client
import json
import os
import sys
import threading
import time
from queue import Queue

CACHE_HOST = "cache.nixos.org"
USER_AGENT = "nixpkgs-multiverse"
RETRIES = 3
TIMEOUT_SECONDS = 30
DIGEST_LEN = 32


def parse_narinfo(text):
    out = {}
    for line in text.splitlines():
        k, _, v = line.partition(": ")
        out[k] = v
    refs = [base[:DIGEST_LEN] for base in out.get("References", "").split()]
    sp = out.get("StorePath", "")
    name = sp[len("/nix/store/") + DIGEST_LEN + 1 :] if sp.startswith("/nix/store/") else None
    return {
        "name": name,
        "ns": int(out["NarSize"]) if out.get("NarSize") else None,
        "fs": int(out["FileSize"]) if out.get("FileSize") else None,
        "url": out.get("URL"),
        "refs": refs,
    }


class Worker(threading.Thread):
    def __init__(self, q, results, stats):
        super().__init__(daemon=True)
        self.q, self.results, self.stats = q, results, stats
        self.conn = None

    def connect(self):
        if self.conn:
            try:
                self.conn.close()
            except Exception:
                pass
        self.conn = http.client.HTTPSConnection(CACHE_HOST, timeout=TIMEOUT_SECONDS)
        return self.conn

    def fetch(self, digest):
        for attempt in range(RETRIES):
            try:
                conn = self.conn or self.connect()
                conn.request(
                    "GET", f"/{digest}.narinfo", headers={"User-Agent": USER_AGENT}
                )
                r = conn.getresponse()
                body = r.read()
                if r.status == 200:
                    rec = parse_narinfo(body.decode())
                    rec.update(d=digest, ok=True)
                    return rec
                if r.status == 404:
                    return {"d": digest, "ok": False}
                # transient (429/5xx): retry on a fresh connection
                self.connect()
            except Exception:
                self.connect()
            time.sleep(0.5 * (attempt + 1))
        return {"d": digest, "ok": False, "err": True}

    def run(self):
        while True:
            digest = self.q.get()
            if digest is None:
                return
            rec = self.fetch(digest)
            with self.stats["lock"]:
                self.results.append(rec)
                self.stats["done"] += 1
                if rec.get("ok"):
                    self.stats["ok"] += 1
                n = self.stats["done"]
            if n % 10000 == 0:
                rate = n / (time.time() - self.stats["t0"])
                print(f"  {n} crawled ({rate:.0f}/s)", flush=True)


def load_seeds(seed_files):
    seed = set()
    for f in seed_files:
        data = json.load(open(f))
        for vers in data["attrs"].values():
            for entry in vers.values():
                seed.add(entry[0])
    return seed


def load_graph(path):
    """Digests already in the graph: natively crawled ones, currently-dead
    ones, and stubs.

    A stub (written by tools/restore-outpaths-state.sh when no rolling graph
    exists) marks a digest whose published artifacts are already truth: it is
    never re-crawled as a root, but it does NOT satisfy a closure walk — the
    first time a new root's BFS reaches one it is crawled natively, which is
    what keeps closures complete without a cold runner re-crawling thirteen
    years of paths up front."""
    native, dead, stubs = set(), set(), set()
    if not os.path.exists(path):
        return native, dead, stubs
    with gzip.open(path, "rt") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            d = rec["d"]
            if rec.get("stub"):
                stubs.add(d)
                continue
            native.add(d)
            stubs.discard(d)
            if rec.get("ok"):
                dead.discard(d)
            else:
                dead.add(d)
    return native, dead, stubs


def crawl_wave(digests, threads, stats_label):
    stats = {"done": 0, "ok": 0, "lock": threading.Lock(), "t0": time.time()}
    results = []
    q = Queue(maxsize=threads * 4)
    workers = [Worker(q, results, stats) for _ in range(threads)]
    for w in workers:
        w.start()
    for d in digests:
        q.put(d)
    for _ in workers:
        q.put(None)
    for w in workers:
        w.join()
    print(f"{stats_label}: {stats['done']} crawled, {stats['ok']} alive", flush=True)
    return results


def append_graph(path, records):
    # A separate gzip member per wave: readers see one concatenated stream,
    # and a crashed run loses at most the wave being written.
    with gzip.open(path, "at") as f:
        for rec in records:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seeds", nargs="+", required=True, help="outpaths json files")
    ap.add_argument("--graph", required=True, help="crawl state, jsonl.gz")
    ap.add_argument("--threads", type=int, default=32)
    ap.add_argument("--max-total", type=int, default=3_000_000)
    ap.add_argument(
        "--recheck-dead",
        action="store_true",
        help="re-fetch seed digests recorded as dead (liveness refresh)",
    )
    args = ap.parse_args()

    native, dead, stubs = load_graph(args.graph)
    print(
        f"{len(native)} natively crawled, {len(stubs)} stubs, {len(dead)} dead",
        flush=True,
    )

    # Roots: seed digests neither crawled nor covered by published truth.
    seeds = load_seeds(args.seeds)
    frontier = seeds - native - stubs
    if args.recheck_dead:
        frontier |= seeds & dead

    crawled = set(native)
    total = len(native)
    wave = 0
    while frontier and total < args.max_total:
        batch = sorted(frontier)[: args.max_total - total]
        print(f"wave {wave}: {len(batch)} to crawl", flush=True)
        results = crawl_wave(batch, args.threads, f"wave {wave}")
        append_graph(args.graph, results)
        crawled.update(batch)
        total += len(batch)

        # Next frontier: every reference this wave surfaced that has never
        # been crawled natively. A stub qualifies — reaching one through a
        # closure walk is exactly when it earns a real record.
        frontier = set()
        for rec in results:
            for r in rec.get("refs") or []:
                if r not in crawled:
                    frontier.add(r)
        wave += 1

    print(f"done: {total} total, frontier left {len(frontier)}", flush=True)


if __name__ == "__main__":
    sys.exit(main())

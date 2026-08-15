#!/usr/bin/env python3
"""The weekly census: is every indexed store path still downloadable?

For every digest named by the seed files, GET the narinfo and then HEAD the
NAR payload it points at. The narinfo says the cache remembers the path; the
HEAD says the bytes are actually there. Both checks matter — the prototype
found narinfos whose NAR had been garbage-collected exactly never, but that
is a claim to keep re-earning, not to assume.

Outputs:
  census-results.json   {at, total, narinfoOk, narOk, missingNarinfo: [...],
                         missingNar: [...]} — the snapshot the rolling
                         release publishes.
  --graph (optional)    newly dead digests are appended to the crawl graph
                         as {"d": ..., "ok": false} records, so the next
                         consolidation marks them dead without a re-crawl.
"""
import argparse
import gzip
import http.client
import json
import sys
import threading
import time
from queue import Queue

CACHE_HOST = "cache.nixos.org"
USER_AGENT = "nixpkgs-multiverse-census"
RETRIES = 3
TIMEOUT_SECONDS = 30


def load_seeds(seed_files):
    seed = set()
    for f in seed_files:
        data = json.load(open(f))
        for vers in data["attrs"].values():
            for entry in vers.values():
                seed.add(entry[0])
    return seed


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

    def request(self, method, path):
        for attempt in range(RETRIES):
            try:
                conn = self.conn or self.connect()
                conn.request(method, path, headers={"User-Agent": USER_AGENT})
                r = conn.getresponse()
                body = r.read()
                if r.status in (200, 404):
                    return r.status, body
                # transient (429/5xx): retry on a fresh connection
                self.connect()
            except Exception:
                self.connect()
            time.sleep(0.5 * (attempt + 1))
        return None, b""

    def check(self, digest):
        status, body = self.request("GET", f"/{digest}.narinfo")
        if status != 200:
            return {"d": digest, "narinfo": False, "nar": False, "err": status is None}

        # The narinfo's URL field is relative (nar/<hash>.nar.xz); HEAD it to
        # prove the payload bytes are still served, not just remembered.
        nar_url = None
        for line in body.decode().splitlines():
            k, _, v = line.partition(": ")
            if k == "URL":
                nar_url = v
                break
        if not nar_url:
            return {"d": digest, "narinfo": True, "nar": False}
        status, _ = self.request("HEAD", f"/{nar_url}")
        return {"d": digest, "narinfo": True, "nar": status == 200}

    def run(self):
        while True:
            digest = self.q.get()
            if digest is None:
                return
            rec = self.check(digest)
            with self.stats["lock"]:
                self.results.append(rec)
                self.stats["done"] += 1
                n = self.stats["done"]
            if n % 10000 == 0:
                rate = n / (time.time() - self.stats["t0"])
                print(f"  {n} checked ({rate:.0f}/s)", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seeds", nargs="+", required=True, help="outpaths json files")
    ap.add_argument("--out", required=True, help="census-results.json")
    ap.add_argument(
        "--graph", help="crawl graph to append newly dead digests to (optional)"
    )
    ap.add_argument("--threads", type=int, default=32)
    ap.add_argument("--date", required=True, help="the snapshot's date, YYYY-MM-DD")
    args = ap.parse_args()

    digests = sorted(load_seeds(args.seeds))
    print(f"{len(digests)} digests to check", flush=True)

    stats = {"done": 0, "lock": threading.Lock(), "t0": time.time()}
    results = []
    q = Queue(maxsize=args.threads * 4)
    workers = [Worker(q, results, stats) for _ in range(args.threads)]
    for w in workers:
        w.start()
    for d in digests:
        q.put(d)
    for _ in workers:
        q.put(None)
    for w in workers:
        w.join()

    # A digest that timed out through every retry is unknown, not dead; it is
    # excluded from the missing lists so a flaky hour cannot declare a
    # massacre, and the count is reported so a flaky hour is still visible.
    errors = [r for r in results if r.get("err")]
    checked = [r for r in results if not r.get("err")]
    missing_narinfo = sorted(r["d"] for r in checked if not r["narinfo"])
    missing_nar = sorted(r["d"] for r in checked if r["narinfo"] and not r["nar"])

    summary = {
        "at": args.date,
        "total": len(digests),
        "checked": len(checked),
        "unreachable": len(errors),
        "narinfoOk": sum(1 for r in checked if r["narinfo"]),
        "narOk": sum(1 for r in checked if r["nar"]),
        "missingNarinfo": missing_narinfo,
        "missingNar": missing_nar,
    }
    json.dump(summary, open(args.out, "w"), indent=1, sort_keys=True)
    print(
        f"census: {summary['narOk']}/{summary['checked']} fully alive, "
        f"{len(missing_narinfo)} narinfos missing, {len(missing_nar)} NARs "
        f"missing, {len(errors)} unreachable",
        flush=True,
    )

    # Feed the deaths back into the graph so consolidation sees them; a
    # missing NAR is a dead path even though its narinfo lingers.
    newly_dead = missing_narinfo + missing_nar
    if args.graph and newly_dead:
        with gzip.open(args.graph, "at") as f:
            for d in newly_dead:
                f.write(json.dumps({"d": d, "ok": False}) + "\n")
        print(f"{len(newly_dead)} dead digests appended to {args.graph}", flush=True)


if __name__ == "__main__":
    sys.exit(main())

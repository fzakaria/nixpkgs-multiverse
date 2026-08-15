// The cache.nixos.org client: narinfo parsing and fetching, and the live
// closure walker. cache.nixos.org serves narinfos with open CORS, so the
// browser can ask the cache directly — is a path still there, what does it
// reference, what is its full closure. The components that render these
// answers live in views/package-store.js; this module is the data side.

import { HTTP_NOT_FOUND } from "./config.js";

// The binary cache every indexed path was built into. Serves narinfos with
// open CORS, so the page can ask it directly whether a path is still there.
export const CACHE_URL = "https://cache.nixos.org/";
export const STORE_DIR = "/nix/store/";
// A store digest: 32 chars of nix base-32.
export const DIGEST_RE = /^[0-9abcdfghijklmnpqrsvwxyz]{32}$/;
// How many narinfos a live closure walk may touch before stopping.
export const WALK_CAP = 1500;
// How many narinfos the walk fetches at once.
const WALK_BATCH = 24;

// The full /nix/store path for a version's meta entry.
export const storePathOf = (attr, v, entry) =>
  `${STORE_DIR}${entry.d}-${entry.n ?? `${attr}-${v}`}`;

// A narinfo is "Key: value" lines. References holds path basenames; only
// their digests matter here.
function parseNarinfo(text) {
  const out = {};
  for (const line of text.split("\n")) {
    const i = line.indexOf(": ");
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 2);
  }
  return {
    ns: out.NarSize ? Number(out.NarSize) : null,
    fs: out.FileSize ? Number(out.FileSize) : null,
    url: out.URL || null,
    name: out.StorePath ? out.StorePath.slice(44) : null,
    refs: (out.References || "")
      .split(" ")
      .filter(Boolean)
      .map((b) => b.slice(0, 32)),
  };
}

const narinfoCache = new Map();
export function fetchNarinfo(digest) {
  if (!narinfoCache.has(digest)) {
    narinfoCache.set(
      digest,
      fetch(`${CACHE_URL}${digest}.narinfo`).then((r) => {
        if (r.status === HTTP_NOT_FOUND) return { dead: true };
        if (!r.ok) throw new Error(`narinfo: HTTP ${r.status}`);
        return r.text().then(parseNarinfo);
      }),
    );
  }
  return narinfoCache.get(digest);
}

// Walk the References graph live against cache.nixos.org, narinfo by narinfo,
// until the closure is complete (or the cap). No index data is involved —
// this is the browser asking the cache what the closure is, which both
// verifies the precomputed number and produces the full path list.
export async function walkClosure(digest, onProgress) {
  const seen = new Map();
  const queued = new Set([digest]);
  let frontier = [digest];
  while (frontier.length && seen.size < WALK_CAP) {
    const batch = frontier.splice(0, WALK_BATCH);
    const infos = await Promise.all(
      batch.map((d) =>
        fetchNarinfo(d)
          .then((i) => ({ d, ...i }))
          .catch(() => ({ d, err: true })),
      ),
    );
    for (const i of infos) {
      seen.set(i.d, i);
      for (const r of i.refs || [])
        if (!queued.has(r)) {
          queued.add(r);
          frontier.push(r);
        }
    }
    onProgress(seen.size, frontier.length);
  }
  return { seen, complete: !frontier.length };
}

// Everything the site fetches out of its own data files: the per-attribute
// shards, the whole files, and the derived lookups over them. All of it is
// cached at module scope, so a re-mounted component never refetches.

import { useState, useEffect } from "htm/preact";

import { HTTP_NOT_FOUND, SHARD_ERROR } from "./config.js";

export const fetchJson = (f) =>
  fetch(f).then((r) => {
    if (!r.ok) throw new Error(`${f}: HTTP ${r.status}`);
    return r.json();
  });

/* ---------- per-attribute shards ----------
 *
 * versions.json is 5.3 MB and history.json is 8 MB, and a package page is
 * about one attribute out of each, so the site build splits both by the first
 * two characters of the attribute name and this fetches the one shard of
 * each. Median shard is 1.4 KB of versions and 2 KB of history.
 *
 * That is what makes a package URL cheap enough to be worth indexing: the
 * whole page used to wait on the 5.3 MB index before it could draw a row.
 *
 * Cached per shard at module scope: opening five packages beginning "py"
 * fetches once.
 */
export const Shard = {
  VERSIONS: "versions",
  HISTORY: "history",
  // Per-version store metadata: digest, sizes, closure, liveness, direct
  // references (interned in the shard's own "paths" table).
  META: "meta",
  // Inverted references: who depended on each version of this attribute.
  REVDEPS: "revdeps",
};

const shardOf = (attr) =>
  [...attr.slice(0, 2).toLowerCase()]
    .map((c) => (/[a-z0-9]/.test(c) ? c : "_"))
    .join("") || "_";

const shardCache = new Map();
function loadShard(dir, attr) {
  const path = `${dir}/${shardOf(attr)}.json`;
  if (!shardCache.has(path)) {
    shardCache.set(
      path,
      fetch(path).then((r) => {
        // A missing shard is not a failure: no file for "zz" means no
        // attribute starts with those two characters, which is the same
        // answer as a shard that loads and does not hold the attribute.
        if (r.status === HTTP_NOT_FOUND) return { attrs: {} };
        if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
        return r.json();
      }),
    );
  }
  return shardCache.get(path);
}

// One attribute's slice of a sharded file, refetched when the attribute
// changes.
//
// A failed fetch lands as the SHARD_ERROR sentinel rather than as {}. It used
// to be {}, which the timeline renders as nothing at all — indistinguishable
// from a package with no history, and the reason the graph looked like it
// "sometimes" did not appear.
export function useShard(dir, attr) {
  const [data, setData] = useState(null);
  useEffect(() => {
    let live = true;
    setData(null);
    loadShard(dir, attr)
      .then((d) => live && setData(d.attrs[attr] ?? {}))
      .catch(() => live && setData(SHARD_ERROR));
    return () => {
      live = false;
    };
  }, [dir, attr]);
  return data;
}

// One fetch per package page each. The timeline and every version row read
// the same two objects, so opening a row costs nothing extra.
export const useHistory = (attr) => useShard(Shard.HISTORY, attr);
export const useVersions = (attr) => useShard(Shard.VERSIONS, attr);

// The whole shard file rather than one attribute's slice: the meta shard
// carries a "paths" intern table beside "attrs" and every reference is an
// index into it, so a consumer needs both halves.
export function useWholeShard(dir, attr) {
  const [data, setData] = useState(null);
  useEffect(() => {
    let live = true;
    setData(null);
    loadShard(dir, attr)
      .then((d) => live && setData(d))
      .catch(() => live && setData(SHARD_ERROR));
    return () => {
      live = false;
    };
  }, [dir, attr]);
  return data;
}

export const useMeta = (attr) => useWholeShard(Shard.META, attr);
export const useRevdeps = (attr) => useShard(Shard.REVDEPS, attr);

// A reference entry out of the meta shard's intern table: [name] for a path
// that is not an indexed package, [name, attr, version] for one that is.
export const refName = (p) => p[0];
export const refAttr = (p) => p[1];
export const refVer = (p) => p[2];

/* ---------- whole files, fetched only by what needs them ----------
 *
 * Neither of these belongs in the boot chain. A package page is the URL worth
 * indexing and the one a search engine renders 30,000 times, so it loads its
 * two shards and nothing else; the two files below are fetched by the
 * components that actually read them, the first time one is mounted.
 */

// Every attribute name and its version count: what the search box matches
// against, and all it needs.
const NAMES_FILE = "names.json";

// The whole index. Only the revisions tab reads it, because "what is pinned
// at this revision" is a question about every attribute at once and no shard
// can answer it.
const INDEX_FILE = "versions.json";

const fileCache = new Map();
// The same fetch as useFile, for callers outside the render cycle — an event
// handler that must resolve something before it can decide where to go. It
// shares fileCache, so a file either view already pulled costs nothing.
// Rejections surface as null rather than the SHARD_ERROR sentinel: an
// imperative caller is choosing a branch, not rendering a state.
export function loadFile(file) {
  if (!fileCache.has(file)) fileCache.set(file, fetchJson(file));
  return fileCache.get(file).catch(() => null);
}

export function useFile(file) {
  const [data, setData] = useState(null);
  useEffect(() => {
    let live = true;
    if (!fileCache.has(file)) fileCache.set(file, fetchJson(file));
    fileCache
      .get(file)
      .then((d) => live && setData(d))
      .catch(() => live && setData(SHARD_ERROR));
    return () => {
      live = false;
    };
  }, [file]);
  return data;
}

// The attribute-name map itself, unwrapped, with the error sentinel passed
// through so a caller can tell "failed" from "still loading".
export function useNames() {
  const file = useFile(NAMES_FILE);
  return file && file !== SHARD_ERROR ? file.attrs : file;
}

export const useFullIndex = () => useFile(INDEX_FILE);

// On disk a version with one unbroken run is [first, last]; one with gaps is a
// list of those pairs. Same collapse multiverse.nix expands in runsOf.
export const runsOf = (v) => (v && !Array.isArray(v[0]) ? [v] : v);

// The index records only the NEWEST revision shipping each version, so this
// answers "which package versions are pinned at this revision", not "what was
// in it" — the full contents of a revision are the whole of nixpkgs.
// Built once per loaded index, on the first open row.
let pinsCache = null;
export function pinsFor(index, offset) {
  if (!pinsCache) {
    pinsCache = new Map();
    for (const [attr, versions] of Object.entries(index.attrs))
      for (const [v, off] of Object.entries(versions)) {
        let l = pinsCache.get(off);
        if (!l) pinsCache.set(off, (l = []));
        l.push([attr, v]);
      }
    for (const l of pinsCache.values())
      l.sort((x, y) => (x[0] < y[0] ? -1 : 1));
  }
  return pinsCache.get(offset) || [];
}

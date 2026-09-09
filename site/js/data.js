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
  // references (interned in the shard's own "paths" table). One directory per
  // system, because a store path belongs to one, so these are prefixes rather
  // than directories: metaDirFor and revdepsDirFor name the file to fetch.
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
    if (!dir) return;
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
/**
 * A whole shard, or nothing at all when `dir` is null.
 *
 * The null case is what makes a second system lazy: the package view calls
 * this for the alternate system's meta directory on every render, and until a
 * reader actually switches system there is no directory to read and no
 * request goes out.
 */
export function useWholeShard(dir, attr) {
  const [data, setData] = useState(null);
  useEffect(() => {
    let live = true;
    setData(null);
    if (!dir) return;
    loadShard(dir, attr)
      .then((d) => live && setData(d))
      .catch(() => live && setData(SHARD_ERROR));
    return () => {
      live = false;
    };
  }, [dir, attr]);
  return data;
}

/**
 * The systems the site publishes store paths for, newest build first in the
 * file: the one every aggregate view is built from, then the alternates.
 *
 * Fetched once per page load and shared, since every package view asks.
 */
let systemsPromise = null;
export function useSystems() {
  const [systems, setSystems] = useState(null);
  useEffect(() => {
    let live = true;
    systemsPromise ??= fetch("systems.json")
      .then((r) => (r.ok ? r.json() : []))
      .catch(() => []);
    systemsPromise.then((s) => live && setSystems(s));
    return () => {
      live = false;
    };
  }, []);
  return systems;
}

// The system the site aggregates, substituted by the build out of the
// systems.json it just wrote. A package page names its shards before it has
// fetched anything, so the default cannot wait on systems.json — that is one
// round trip in front of the two files the page exists to load.
const SITE_SYSTEM = "__SITE_SYSTEM__";

// Where one system's store data lives. Every directory names its system,
// including the aggregated one: a digest belongs to exactly one system, and a
// reader working out which directory holds the default has been handed a rule
// instead of a name.
//
// Reverse dependencies are per system for the same reason the paths are: "used
// by 42 package versions" describes one system's dependency graph.
const dirFor = (base, system) => `${base}-${system || SITE_SYSTEM}`;

export const metaDirFor = (system) => dirFor(Shard.META, system);
export const revdepsDirFor = (system) => dirFor(Shard.REVDEPS, system);

// A reference entry out of the meta shard's intern table: [name] for a path
// that is not an indexed package, [name, attr, version] for one that is.
export const refName = (p) => p[0];
export const refAttr = (p) => p[1];
export const refVer = (p) => p[2];

/* ---------- whole files, fetched only by what needs them ----------
 *
 * A package page is the URL worth indexing and the one a search engine renders
 * 30,000 times, so it loads its two shards and nothing else; the files below
 * are fetched by the components that actually read them, the first time one is
 * mounted. stats.json is the exception — the summary line above the tabs reads
 * its totals, so App asks for it on every route — and it lives here anyway, so
 * that the shell and the stats tab share one response rather than two.
 */

// Every attribute name and its version count: what the search box matches
// against, and all it needs.
const NAMES_FILE = "names.json";

// The whole index. Only the revisions tab reads it, because "what is pinned
// at this revision" is a question about every attribute at once and no shard
// can answer it.
const INDEX_FILE = "versions.json";

// The channel-tip table, one entry per release. 3.8 KB, and only the releases
// tab reads it.
const RELEASES_FILE = "releases.json";

// Aggregates over the whole index: the totals in the summary line above the
// tabs, the churn column on the revisions tab, and every chart on the stats
// tab. The one file here the shell itself reads, so App holds it too — but
// through this cache, so opening the stats tab reuses the same response.
const STATS_FILE = "stats.json";

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
export const useReleases = () => useFile(RELEASES_FILE);
export const useStats = () => useFile(STATS_FILE);

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

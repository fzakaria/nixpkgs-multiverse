/* ---------- packages: the search box and everything it answers ----------
 *
 * The routed packages view: a name search over names.json, the identify
 * short-circuit for a pasted store path, the depends: edge search, and the
 * hand-off to PackageDetail when the route names one attribute.
 */

import { html, useEffect, useMemo, useRef } from "htm/preact";

import { MAX_RESULTS, SHARD_ERROR } from "../config.js";
import { STORE_DIR, DIGEST_RE } from "../cache.js";
import { Shard, useShard, useFile, useNames } from "../data.js";
import { Link, Nav } from "../router.js";
import { PackageDetail } from "./package.js";

/* ---------- identify: a store path pasted into the search box ----------
 *
 * The reverse index: digest -> (attr, version). Sharded by the digest's own
 * first two characters. This answers "what IS this store path" — for any of
 * the 300,000 outputs the index knows, from any machine's /nix/store or any
 * closure dump, thirteen years back.
 */
function IdentifyCard({ digest, navigate }) {
  const file = useFile(`identify/${digest.slice(0, 2)}.json`);
  if (!file)
    return html`<div id="status" class="muted">Looking up the digest…</div>`;
  const hit = file !== SHARD_ERROR && file[digest];
  if (!hit)
    return html`<div id="status" class="muted">
      <code>${digest}</code> is not an output the index knows — not a package
      output of any indexed nixos-unstable revision (it may be a non-default
      output, or from a private build).
    </div>`;
  const [attr, ver] = hit;
  return html`
    <div id="status" class="muted">identified:</div>
    <div class="identify">
      <${Link} class="pkg" to=${{ pkg: attr, ver }} navigate=${navigate}>
        <b>${attr}</b> <span class="muted">${ver}</span> — see when it shipped
        and how to run it →
      <//>
    </div>
  `;
}

// depends:<attr> — every package that ever linked against any version of
// <attr>, aggregated out of the reverse-dependency shards.
function DependsSearch({ target, navigate }) {
  const rd = useShard(Shard.REVDEPS, target);
  if (!rd) return html`<div id="status" class="muted">Loading…</div>`;
  if (rd === SHARD_ERROR || !Object.keys(rd).length)
    return html`<div id="status" class="muted">
      Nothing ever recorded a runtime dependency on <code>${target}</code>.
    </div>`;
  const counts = new Map();
  for (const entry of Object.values(rd))
    for (const [a] of entry.l) counts.set(a, (counts.get(a) || 0) + 1);
  const rows = [...counts.entries()].sort((x, y) => y[1] - x[1]);
  const total = Object.values(rd).reduce((s, e) => s + e.c, 0);
  return html`
    <div id="status" class="muted">
      ${rows.length.toLocaleString()} packages linked against
      <code>${target}</code> across ${total.toLocaleString()} recorded
      version-edges
    </div>
    <div id="results">
      ${rows.slice(0, MAX_RESULTS).map(
        ([a, n]) => html`
          <${Link}
            class="pkg"
            to=${{ pkg: a, ver: "" }}
            navigate=${navigate}
            key=${a}
          >
            ${a}
            <span class="muted"
              >· ${n} linked version${n === 1 ? "" : "s"}</span
            >
          <//>
        `,
      )}
    </div>
  `;
}

// Mounted whenever the packages tab is not showing one package, so landing on
// the bare page starts the name list downloading before anything is typed.
function SearchResults({ q, navigate }) {
  const names = useNames();
  // json.dump wrote the names sorted, but only a sort here says so.
  const attrNames = useMemo(
    () => (names && names !== SHARD_ERROR ? Object.keys(names).sort() : null),
    [names],
  );

  const raw = q.trim();

  // A pasted store path or bare digest short-circuits the name search: the
  // question is "what is this", not "what is called this" — and it needs no
  // name list, so it renders ahead of the loading states below.
  const pathish = raw.startsWith(STORE_DIR) ? raw.slice(STORE_DIR.length) : raw;
  const maybeDigest = pathish.split("-")[0];
  if (DIGEST_RE.test(maybeDigest))
    return html`<${IdentifyCard} digest=${maybeDigest} navigate=${navigate} />`;

  // depends:openssl — search by edge rather than by name.
  if (raw.toLowerCase().startsWith("depends:")) {
    const target = raw.slice("depends:".length).trim();
    if (target)
      return html`<${DependsSearch} target=${target} navigate=${navigate} />`;
  }

  if (names === SHARD_ERROR)
    return html`<div id="status" class="muted">
      Could not load the package list.
    </div>`;
  if (!names)
    return html`<div id="status" class="muted">Loading the package list…</div>`;

  const query = raw.toLowerCase();
  if (!query) return null;

  // startsWith matches rank ahead of substring matches.
  const starts = [],
    contains = [];
  for (const a of attrNames) {
    const i = a.toLowerCase().indexOf(query);
    if (i === 0) starts.push(a);
    else if (i > 0) contains.push(a);
    if (starts.length >= MAX_RESULTS) break;
  }
  const hits = starts.concat(contains).slice(0, MAX_RESULTS);
  const status = !hits.length
    ? "no matches"
    : hits.length === MAX_RESULTS
      ? `first ${MAX_RESULTS} matches`
      : `${hits.length} matches`;

  return html`
    <div id="status" class="muted">${status}</div>
    <div id="results">
      ${hits.map(
        (a) => html`
          <${Link}
            class="pkg"
            to=${{ pkg: a, ver: "" }}
            navigate=${navigate}
            key=${a}
          >
            ${a}
            <span class="muted">· ${names[a]} versions</span>
          <//>
        `,
      )}
    </div>
  `;
}

export function Packages({ route, navigate, revisions }) {
  // Focus the search box once on a fresh packages landing, like the old
  // autofocus attribute (which does not fire on framework-inserted nodes).
  const inputRef = useRef(null);
  useEffect(() => {
    if (route.view === "packages" && !route.pkg)
      inputRef.current?.focus({ preventScroll: true });
  }, []);

  return html`
    <input
      ref=${inputRef}
      type="search"
      placeholder="Search 30,000+ packages or paste a /nix/store path, or try depends:openssl"
      value=${route.pkg || route.q}
      onInput=${(e) =>
        navigate({ q: e.currentTarget.value, pkg: "", ver: "" }, Nav.REPLACE)}
    />
    ${route.pkg
      ? html`<${PackageDetail}
          attr=${route.pkg}
          route=${route}
          revisions=${revisions}
          navigate=${navigate}
        />`
      : html`<${SearchResults} q=${route.q} navigate=${navigate} />`}
  `;
}

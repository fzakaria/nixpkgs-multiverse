// The site is a Preact app written with htm tagged templates — no build
// step, no JSX. "htm/preact" resolves through the import map in index.html
// to a pinned, integrity-checked single-file CDN bundle (~13 KB). The app is
// plain ES modules under js/: this entry module composes the router and the
// views into the App component and boots the render.
import { html, render, useState, useEffect, useMemo } from "htm/preact";

import { REV_ABBREV, VIEWS } from "./config.js";
import { fetchJson } from "./data.js";
import { Link, useRouter } from "./router.js";
import { Packages } from "./views/packages.js";
import { Revisions } from "./views/revisions.js";
import { Releases } from "./views/releases.js";
import { Stats } from "./views/stats.js";

/* ---------- app ---------- */

function App() {
  const [route, navigate] = useRouter();
  const [small, setSmall] = useState(null); // { revisions, releases } — load fast
  const [stats, setStats] = useState(null); // stats.json — 27 KB, charts
  const [error, setError] = useState(null);

  // Everything the first paint needs, and nothing else. stats.json rides with
  // the two small files: it is 27 KB, it is all the charts need, and it also
  // carries the totals the summary line used to count out of the whole index.
  useEffect(() => {
    Promise.all([
      fetchJson("revisions.json"),
      fetchJson("releases.json"),
      fetchJson("stats.json"),
    ])
      .then(([revisions, releases, s]) => {
        setSmall({ revisions, releases });
        setStats(s);
      })
      .catch((err) => setError(err.message));
  }, []);

  // Counting these by walking every attribute meant the line could not appear
  // until the whole 5.3 MB index had. stats.json states them outright.
  const summary = useMemo(() => {
    const t = stats?.totals;
    if (!t) return null;
    return (
      `${t.versions.toLocaleString()} package versions across ` +
      `${t.attrsEverSeen.toLocaleString()} attributes, from ` +
      `${t.revisions.toLocaleString()} revisions · ` +
      `${t.firstDate} → ${t.lastDate}`
    );
  }, [stats]);

  return html`
    <p class="muted" id="stats">
      ${error
        ? `Failed to load index data: ${error}`
        : (summary ?? "Loading index…")}
    </p>

    <nav>
      ${VIEWS.map(
        (v) => html`
          <${Link}
            class=${route.view === v ? "active" : ""}
            to=${{ ...route, view: v }}
            navigate=${navigate}
            key=${v}
          >
            ${v[0].toUpperCase() + v.slice(1)}
          <//>
        `,
      )}
    </nav>

    <section hidden=${route.view !== "packages"}>
      <${Packages}
        route=${route}
        navigate=${navigate}
        revisions=${small?.revisions ?? []}
      />
    </section>

    <section hidden=${route.view !== "revisions"}>
      ${small &&
      html`<${Revisions}
        route=${route}
        revisions=${small.revisions}
        stats=${stats}
        navigate=${navigate}
      />`}
    </section>

    <section hidden=${route.view !== "stats"}>
      ${route.view === "stats" &&
      html`<${Stats}
        stats=${stats}
        revisions=${small?.revisions ?? []}
        navigate=${navigate}
      />`}
    </section>

    <section hidden=${route.view !== "releases"}>
      ${small &&
      html`<${Releases}
        route=${route}
        releases=${small.releases}
        revisions=${small.revisions}
        navigate=${navigate}
      />`}
    </section>
  `;
}

// The container ships a static "Loading index…" placeholder for the moment
// before this module executes; Preact does not clear pre-existing children,
// so drop the placeholder before mounting.
const root = document.getElementById("app");
root.textContent = "";
render(html`<${App} />`, root);

// The site build substitutes the deploying commit into BUILT_FROM and the
// derivation's own $out into STORE_PATH, so the footer names exactly the
// tree the data files came from and the store path serving them. A local
// checkout still carries the placeholders, and both lines stay hidden.
const BUILT_FROM = "__COMMIT__";
const STORE_PATH = "__STORE_PATH__";
const $ = (id) => document.getElementById(id);
if (!BUILT_FROM.startsWith("__")) {
  $("built-sha").textContent = BUILT_FROM.slice(0, REV_ABBREV);
  $("built-link").href =
    `https://github.com/fzakaria/nixpkgs-multiverse/commit/${BUILT_FROM}`;
  $("built").hidden = false;
}
if (!STORE_PATH.startsWith("__")) {
  $("store-path").textContent = STORE_PATH;
  $("store").hidden = false;
}

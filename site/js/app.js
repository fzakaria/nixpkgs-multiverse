// The site is a Preact app written with htm tagged templates — no build
// step, no JSX. "htm/preact" resolves through the import map in index.html
// to a pinned, integrity-checked single-file CDN bundle (~13 KB). The app is
// plain ES modules under js/: this entry module composes the router and the
// views into the App component and boots the render.
import { html, render, useState, useEffect, useMemo } from "htm/preact";

import { SHARD_ERROR, VIEWS } from "./config.js";
import { fetchJson, useStats } from "./data.js";
import { Link, useRouter } from "./router.js";
import { Packages } from "./views/packages.js";
import { Revisions } from "./views/revisions.js";
import { Releases } from "./views/releases.js";
import { Stats } from "./views/stats.js";

// The revision spine every view joins against: an index offset names nothing
// without it, so this is the one file the shell fetches for itself.
const REVISIONS_FILE = "revisions.json";

/* ---------- app ---------- */

// Whether a view has ever been the active one. The views stay mounted so their
// state — a typed search, a widened revision window, an expanded row — survives
// a trip to another tab, but a view nobody has opened has no state worth
// keeping and should not be building DOM: the revisions tab was rendering 150
// rows into a hidden section of every package page. Returns true from the
// render that activates it, so becoming visible costs no extra frame.
function useVisited(active) {
  const [visited, setVisited] = useState(active);
  useEffect(() => {
    if (active) setVisited(true);
  }, [active]);
  return visited || active;
}

function App() {
  const [route, navigate] = useRouter();
  const [revisions, setRevisions] = useState([]);
  const [error, setError] = useState(null);

  // stats.json rides the shared file cache rather than the fetch below. Only
  // the summary line, the revisions churn column and the stats tab read it,
  // and holding both in one Promise.all held the package table — the thing
  // every one of 30,000 indexed URLs exists to show — until the charts' data
  // had landed too.
  const statsFile = useStats();
  const stats = statsFile === SHARD_ERROR ? null : statsFile;

  // A view renders once it has been visited, and stays mounted from then on.
  const showRevisions = useVisited(route.view === "revisions");
  const showReleases = useVisited(route.view === "releases");
  const showStats = useVisited(route.view === "stats");

  // The one file whose failure is the page's failure, so App fetches it
  // directly and reports what went wrong rather than sharing useFile's
  // "something did not load" sentinel.
  useEffect(() => {
    fetchJson(REVISIONS_FILE)
      .then(setRevisions)
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
      <${Packages} route=${route} navigate=${navigate} revisions=${revisions} />
    </section>

    <section hidden=${route.view !== "revisions"}>
      ${showRevisions &&
      revisions.length > 0 &&
      html`<${Revisions}
        route=${route}
        revisions=${revisions}
        stats=${stats}
        navigate=${navigate}
      />`}
    </section>

    <section hidden=${route.view !== "stats"}>
      ${showStats &&
      html`<${Stats}
        stats=${stats}
        revisions=${revisions}
        navigate=${navigate}
      />`}
    </section>

    <section hidden=${route.view !== "releases"}>
      ${showReleases &&
      revisions.length > 0 &&
      html`<${Releases}
        route=${route}
        revisions=${revisions}
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

// The site build substitutes the derivation's own $out into STORE_PATH, so
// the footer names the store path serving the page. A local checkout still
// carries the placeholder, and the line stays hidden.
const STORE_PATH = "__STORE_PATH__";
if (!STORE_PATH.startsWith("__")) {
  document.getElementById("store-path").textContent = STORE_PATH;
  document.getElementById("store").hidden = false;
}

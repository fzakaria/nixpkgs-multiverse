/* ---------- store metadata: cache liveness, deps, closures ----------
 *
 * Everything here rides on two facts. The meta shards carry each version's
 * store digest, sizes, liveness at census time and direct references; and
 * cache.nixos.org serves narinfos with open CORS, so anything deeper — is it
 * still there right now, what is the full closure — the browser asks the
 * cache itself. The shards store breadth; the client computes depth. The
 * narinfo client and the walker live in cache.js; the components rendering
 * their answers inside a version row live here.
 */

import { html, useState, useEffect, useRef } from "htm/preact";

import { SHARD_ERROR } from "../config.js";
import {
  CACHE_URL,
  STORE_DIR,
  WALK_CAP,
  fetchNarinfo,
  walkClosure,
} from "../cache.js";
import { refName, refAttr, refVer, useNames, loadFile } from "../data.js";
import { fmtBytes, pnameOf } from "../format.js";
import { Link } from "../router.js";

// Asks the cache, live, whether this exact path still substitutes — and what
// it costs. The census answer from the shard renders immediately; the live
// answer replaces it when it arrives, so the badge is never stale.
export function CacheBadge({ entry }) {
  const [live, setLive] = useState(null);
  useEffect(() => {
    let on = true;
    fetchNarinfo(entry.d)
      .then((i) => on && setLive(i))
      .catch(() => on && setLive({ err: true }));
    return () => {
      on = false;
    };
  }, [entry.d]);

  // A failed fetch says nothing about the path — only a definite 404 does.
  // Anything else falls back to what the census recorded.
  //
  // `ok` can also be absent: the shard carries a verdict only for a digest
  // something actually probed, so an entry without one has never been looked
  // at. That is neither of the other two answers, and claiming the census
  // gave either would be inventing one, so the badge waits for the live
  // fetch — which is a moment.
  const verified = live && !live.err;
  const unknown = !verified && entry.ok == null;
  const alive = verified ? !live.dead : entry.ok === 1;
  const ns = live?.ns ?? entry.ns;
  const fs = live?.fs ?? entry.fs;

  return html`
    <div class="cachebadge">
      <span
        class=${unknown ? "badge-unknown" : alive ? "badge-ok" : "badge-dead"}
      >
        ${unknown ? "◍" : alive ? "●" : "○"}
        ${unknown
          ? " asking the cache"
          : alive
            ? ` still substitutable${verified ? "" : " (census)"}`
            : " no longer in the cache"}
      </span>
      ${fs != null &&
      html`<span class="muted">
        · ${fmtBytes(fs)} download · ${fmtBytes(ns)} installed</span
      >`}
      ${alive &&
      live?.url &&
      html`<span>
        · <a href=${CACHE_URL + live.url} rel="nofollow">download the NAR</a>
      </span>`}
    </div>
  `;
}

// The direct dependencies of one version, as recorded in the cache the day it
// was built. A dep that is itself an indexed package links to its page at the
// exact version; anything else (multi-output libs, private packages) shows as
// its store name.
export function Deps({ refs, src, navigate }) {
  const [showAll, setShowAll] = useState(false);
  if (!refs?.length) return null;
  const shown = showAll ? refs : refs.slice(0, 24);
  return html`
    <div class="capt">
      links against ${refs.length} paths directly
      ${src
        ? ` (from its ${src} output's narinfo — the default output is a stub)`
        : " (from its narinfo)"}
    </div>
    <div class="chips">
      ${shown.map((p) =>
        refAttr(p)
          ? html`<${Link}
              class="chip chip-link"
              to=${{ pkg: refAttr(p), ver: refVer(p) }}
              navigate=${navigate}
              key=${refName(p)}
            >
              ${refAttr(p)} <span class="muted">${refVer(p)}</span>
            <//>`
          : html`<span class="chip" key=${refName(p)} title=${refName(p)}>
              ${refName(p)}
            </span>`,
      )}
      ${refs.length > shown.length &&
      html`<button class="more" onClick=${() => setShowAll(true)}>
        +${refs.length - shown.length} more
      </button>`}
    </div>
  `;
}

// Who linked against this exact version — the inverted References index.
export function UsedBy({ rd, navigate }) {
  const [showAll, setShowAll] = useState(false);
  if (!rd || !rd.c) return null;
  const shown = showAll ? rd.l : rd.l.slice(0, 24);
  return html`
    <div class="capt">
      used by ${rd.c.toLocaleString()} package version${rd.c === 1 ? "" : "s"}
      ${rd.c > rd.l.length ? ` (showing ${rd.l.length})` : ""}
    </div>
    <div class="chips">
      ${shown.map(
        ([a, v]) => html`
          <${Link}
            class="chip chip-link"
            to=${{ pkg: a, ver: v }}
            navigate=${navigate}
            key=${`${a}@${v}`}
          >
            ${a} <span class="muted">${v}</span>
          <//>
        `,
      )}
      ${rd.l.length > shown.length &&
      html`<button class="more" onClick=${() => setShowAll(true)}>
        +${rd.l.length - shown.length} more
      </button>`}
    </div>
  `;
}

// What changed structurally against the previous version: dependencies
// gained, dropped, or re-versioned. Identity is the dep's attribute when
// resolved, its pname otherwise, so an openssl bump reads as a change to
// openssl rather than as one dep leaving and an unrelated one arriving.
const DIFF_SHOWN = 14;

export function DepDiff({ refs, prevRefs }) {
  const [showAll, setShowAll] = useState(false);
  if (!refs || !prevRefs) return null;
  const key = (p) => refAttr(p) ?? pnameOf(refName(p));
  const disp = (p) => refVer(p) ?? refName(p).slice(key(p).length + 1);
  const cur = new Map(refs.map((p) => [key(p), p]));
  const prev = new Map(prevRefs.map((p) => [key(p), p]));
  const items = [
    ...[...cur.keys()]
      .filter((k) => !prev.has(k))
      .map((k) => html`<span class="a" key=${`a${k}`}>+${k}</span>`),
    ...[...prev.keys()]
      .filter((k) => !cur.has(k))
      .map((k) => html`<span class="d" key=${`d${k}`}>−${k}</span>`),
    ...[...cur.keys()]
      .filter((k) => prev.has(k) && disp(cur.get(k)) !== disp(prev.get(k)))
      .map(
        (k) =>
          html`<span class="muted" key=${`b${k}`}
            >${k} ${disp(prev.get(k))}→${disp(cur.get(k))}</span
          >`,
      ),
  ];
  if (!items.length)
    return html`<div class="capt">
      same dependency set as the previous version
    </div>`;
  const shown = showAll ? items : items.slice(0, DIFF_SHOWN);
  return html`
    <div class="capt">vs the previous version (${items.length} changes)</div>
    <div class="depdiff delta">
      ${shown}
      ${items.length > shown.length &&
      html`<button class="more" onClick=${() => setShowAll(true)}>
        +${items.length - shown.length} more
      </button>`}
    </div>
  `;
}

export function ClosureLive({ entry }) {
  const [state, setState] = useState(null); // {n, left} | {done}
  const run = async () => {
    setState({ n: 0, left: 1 });
    const { seen, complete } = await walkClosure(entry.d, (n, left) =>
      setState({ n, left }),
    );
    const paths = [...seen.values()].filter((i) => !i.dead && !i.err);
    const dead = [...seen.values()].filter((i) => i.dead).length;
    const total = paths.reduce((s, i) => s + (i.ns || 0), 0);
    const top = paths
      .slice()
      .sort((a, b) => (b.ns || 0) - (a.ns || 0))
      .slice(0, 8);
    setState({ done: true, count: seen.size, dead, total, top, complete });
  };

  if (!state)
    return html`<button class="more" onClick=${run}>
      walk the full closure live from cache.nixos.org →
    </button>`;
  if (!state.done)
    return html`<div class="capt">
      walking… ${state.n} narinfos fetched, ${state.left} queued
    </div>`;
  return html`
    <div class="capt">
      closure, measured live:${" "}
      <b>${state.count} paths · ${fmtBytes(state.total)}</b>
      ${state.dead ? ` · ${state.dead} paths gone from the cache` : ""}
      ${state.complete ? "" : ` · stopped at ${WALK_CAP} paths`} ·
      heaviest${" "} ${state.top.length} paths:
    </div>
    <div class="chips">
      ${state.top.map(
        (i) =>
          html`<span class="chip" key=${i.d} title=${i.name}
            >${i.name ?? i.d} <span class="muted">${fmtBytes(i.ns)}</span></span
          >`,
      )}
    </div>
  `;
}

/* ---------- dependency graph explorer ----------
 *
 * The FULL transitive closure of one version, drawn as concentric rings by
 * dependency depth — fetched live from cache.nixos.org by the same walk the
 * closure button uses, so every node is a real narinfo and every edge a real
 * References entry. Median closure is 16 paths and p99 is ~500, so plain SVG
 * with viewBox zoom is plenty; the walk cap bounds the 0.03% tail.
 *
 * Tree edges only (first-discovery parent), or dense closures become a
 * hairball. Node area tracks NAR size. Scroll to zoom, drag to pan; labels
 * are drawn in graph units, so zooming in makes them readable.
 */
const GRAPH_RING = 150; // px between depth rings
const GRAPH_LABELED = 40; // nodes past depth 1 that still get labels
const ZOOM_STEP = 1.2;
const ZOOM_MAX_FACTOR = 40;

// The four layouts the graph offers, as one table rather than a copy inside
// each effect that needs one — the create effect and the layout-switch effect
// were carrying separate copies of the same switch.
//
// Every layout sets nodeDimensionsIncludeLabels, which is what keeps labels
// from colliding: without it a layout packs circles, and the text hanging off
// each circle is free to land on its neighbour. avoidOverlap adds the same
// promise for the node bodies. The numbers are otherwise the defaults, chosen
// to spread a ~150-node closure without pushing it off screen.
const GRAPH_PADDING = 30;
// Below this rendered font size cytoscape stops drawing labels entirely,
// which is what makes a zoomed-out closure legible as a shape.
const MIN_LABEL_FONT_PX = 7;
// How wide a label may get before it is ellipsised. Roughly the width of
// "libxml2-2.13.5", past which names start covering their neighbours.
const LABEL_MAX_WIDTH_PX = 110;
const LAYOUT_ANIMATION_MS = 400;

// The graph library is by far the heaviest thing the site can pull — 122 KB
// over the wire, 378 KB unpacked — and this component is the only thing that
// ever draws with it. A static import put it on the module graph every page
// loads at boot: the revisions, releases and stats tabs, which never draw a
// graph, and every package page whose visitor never presses the button below.
// `run` awaits this before it sets the state the draw effect keys off, so the
// effect still finds a loaded module and stays synchronous. The import map in
// index.html resolves the bare specifier and checks its integrity hash for a
// dynamic import exactly as it does for a static one.
let cytoscape = null;
const loadCytoscape = () =>
  import("cytoscape").then((m) => (cytoscape = m.default));

const layoutFor = (name, rootId) => {
  const shared = {
    padding: GRAPH_PADDING,
    animate: true,
    animationDuration: LAYOUT_ANIMATION_MS,
    nodeDimensionsIncludeLabels: true,
  };
  switch (name) {
    case "concentric":
      return {
        ...shared,
        name: "concentric",
        concentric: (n) => 100 - (n.data("depth") || 0),
        levelWidth: () => 1,
        avoidOverlap: true,
        minNodeSpacing: 24,
      };
    case "cose":
      return {
        ...shared,
        name: "cose",
        nodeRepulsion: () => 400000,
        idealEdgeLength: () => 70,
        nodeOverlap: 20,
        componentSpacing: 80,
      };
    case "circle":
      return {
        ...shared,
        name: "circle",
        avoidOverlap: true,
        spacingFactor: 1.2,
      };
    default:
      return {
        ...shared,
        name: "breadthfirst",
        directed: true,
        roots: [rootId],
        spacingFactor: 1.4,
        avoidOverlap: true,
      };
  }
};

export function GraphExplorer({ attr, v, entry, navigate }) {
  const [state, setState] = useState(null); // null | {walking: n} | {elements, count, total, rootId}
  const [layoutName, setLayoutName] = useState("breadthfirst");
  const containerRef = useRef(null);
  const cyRef = useRef(null);
  const names = useNames();

  const run = async () => {
    setState({ walking: 0 });
    // Both are network-bound and neither needs the other's answer, so the
    // library downloads while the closure is being walked rather than after.
    const drawing = loadCytoscape();
    const { seen, complete } = await walkClosure(entry.d, (n) =>
      setState({ walking: n }),
    );

    // BFS depths and parent mapping over the walk
    const depth = new Map([[entry.d, 0]]);
    const parent = new Map();
    let frontier = [entry.d];
    while (frontier.length) {
      const next = [];
      for (const d of frontier)
        for (const r of seen.get(d)?.refs || [])
          if (seen.has(r) && !depth.has(r)) {
            depth.set(r, depth.get(d) + 1);
            parent.set(r, d);
            next.push(r);
          }
      frontier = next;
    }

    const elements = [];
    let total = 0;

    for (const [d, dep] of depth) {
      const i = seen.get(d);
      const name = i?.name ?? d;
      const pn = pnameOf(name);
      const ns = i?.ns || 0;
      total += ns;
      const isRoot = dep === 0;
      // A colouring hint, not a destination: the name's pname matching an
      // attribute means this is probably a package the index knows, which is
      // worth a lighter node. Where it actually goes is settled by the
      // digest when the node is tapped — see the handler below.
      const link = names && names !== SHARD_ERROR && names[pn] ? pn : null;

      elements.push({
        data: {
          id: d,
          name,
          label: name,
          depth: dep,
          isRoot,
          link,
          ns,
          formattedSize: fmtBytes(ns),
          color: isRoot ? "#3b82f6" : link ? "#60a5fa" : "#64748b",
          size: isRoot
            ? 24
            : Math.max(
                12,
                Math.min(28, 8 + Math.log10((ns || 1) / 1024 + 1) * 6),
              ),
        },
      });

      const p = parent.get(d);
      if (p) {
        elements.push({
          data: {
            id: `e_${p}_${d}`,
            source: p,
            target: d,
          },
        });
      }
    }

    await drawing;
    setState({ elements, count: depth.size, complete, total, rootId: entry.d });
  };

  useEffect(() => {
    if (!containerRef.current || !state?.elements) return;

    const isDark =
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches;
    const labelColor = isDark ? "#e2e8f0" : "#1e293b";
    const edgeColor = isDark ? "#475569" : "#cbd5e1";
    // What the label panel is painted with: the page behind the graph, so a
    // label reads as sitting on the canvas rather than in a box.
    const panelColor = isDark ? "#0f172a" : "#ffffff";

    const cy = cytoscape({
      container: containerRef.current,
      elements: state.elements,
      style: [
        {
          selector: "node",
          style: {
            "background-color": "data(color)",
            label: "data(label)",
            color: labelColor,
            "font-size": "11px",
            "font-family": "system-ui, sans-serif",
            "text-valign": "bottom",
            "text-margin-y": 4,
            // Three defences against a wall of overlapping text in a dense
            // closure. Labels disappear below the zoom where they would be
            // unreadable anyway, so the zoomed-out view shows shape rather
            // than mush; a long derivation name is clipped rather than
            // sprawling across its neighbours; and each label sits on a
            // panel of the page background, so where two do overlap the
            // front one stays readable instead of interleaving.
            "min-zoomed-font-size": MIN_LABEL_FONT_PX,
            "text-wrap": "ellipsis",
            "text-max-width": LABEL_MAX_WIDTH_PX,
            "text-background-color": panelColor,
            "text-background-opacity": 0.85,
            "text-background-padding": 2,
            "text-background-shape": "roundrectangle",
            // The label is decoration; a tap belongs to the node under it.
            "text-events": "no",
            width: "data(size)",
            height: "data(size)",
            cursor: "pointer",
          },
        },
        {
          selector: "node[?isRoot]",
          style: {
            "border-width": 3,
            "border-color": "#60a5fa",
            "font-weight": "bold",
          },
        },
        {
          selector: "edge",
          style: {
            width: 1.5,
            "line-color": edgeColor,
            "target-arrow-shape": "triangle",
            "target-arrow-color": edgeColor,
            "curve-style": "bezier",
            opacity: 0.7,
            "arrow-scale": 0.8,
          },
        },
      ],
      layout: layoutFor(layoutName, state.rootId),
    });

    // Where a node goes is decided by the digest, not by its name. A closure
    // holds whatever the consumer's own revision linked against, so the
    // name's version is frequently not one this index recorded for that
    // attribute — a multi-output sibling (gcc-9.3.0-lib parses as version
    // "9.3.0-lib") or an older build of the same library. Measured over real
    // reference lists, 36% of the nodes whose pname matches an attribute
    // would land on an (attr, version) pair that does not exist.
    //
    // identify/<xx>.json is the index's own digest -> (attr, version) map, so
    // one small cached fetch answers exactly, aliases included. A digest the
    // index never recorded is not a dead end either: the search box's
    // identify card explains what it is instead.
    cy.on("tap", "node", async (evt) => {
      const { id, name } = evt.target.data();
      const shard = await loadFile(`identify/${id.slice(0, 2)}.json`);
      const hit = shard && shard[id];
      if (hit) {
        navigate({ pkg: hit[0], ver: hit[1] });
        return;
      }
      navigate({ q: `${STORE_DIR}${id}-${name}` });
    });

    cyRef.current = cy;
    return () => {
      cy.destroy();
      cyRef.current = null;
    };
  }, [state]);

  useEffect(() => {
    if (cyRef.current && state?.rootId) {
      cyRef.current.layout(layoutFor(layoutName, state.rootId)).run();
    }
  }, [layoutName]);

  if (!entry.d) return null;
  if (!state)
    return html`<button class="more" onClick=${run}>
      draw full dependency graph live from cache.nixos.org →
    </button>`;
  if (state.walking != null)
    return html`<div class="capt">
      walking the closure… ${state.walking} narinfos fetched
    </div>`;

  return html`
    <div class="graphbox" style="margin-top:0.5rem">
      <div
        style="display:flex; justify-space:space-between; align-items:center; margin-bottom:0.4rem; flex-wrap:wrap; gap:0.4rem"
      >
        <div
          style="display:flex; gap:0.3rem; align-items:center; font-size:12px"
        >
          <span class="muted">Layout:</span>
          <button
            class="more"
            style=${`font-size:12px; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid var(--line); ${layoutName === "breadthfirst" ? "background:var(--line); font-weight:600" : ""}`}
            onClick=${() => setLayoutName("breadthfirst")}
          >
            Tree
          </button>
          <button
            class="more"
            style=${`font-size:12px; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid var(--line); ${layoutName === "concentric" ? "background:var(--line); font-weight:600" : ""}`}
            onClick=${() => setLayoutName("concentric")}
          >
            Radial
          </button>
          <button
            class="more"
            style=${`font-size:12px; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid var(--line); ${layoutName === "cose" ? "background:var(--line); font-weight:600" : ""}`}
            onClick=${() => setLayoutName("cose")}
          >
            Force
          </button>
          <button
            class="more"
            style=${`font-size:12px; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid var(--line); ${layoutName === "circle" ? "background:var(--line); font-weight:600" : ""}`}
            onClick=${() => setLayoutName("circle")}
          >
            Circle
          </button>
        </div>
        <button
          class="more"
          style="font-size:12px; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid var(--line); margin-left:auto"
          onClick=${() => cyRef.current?.fit()}
        >
          Fit View
        </button>
      </div>

      <div
        ref=${containerRef}
        style="width:100%; height:480px; background:var(--bg, transparent); border-radius:6px; border:1px solid var(--line);"
      ></div>

      <div class="capt" style="margin-top:0.4rem">
        the complete runtime closure, fetched live from
        <a href="https://cache.nixos.org">cache.nixos.org</a>:
        <b>${state.count} paths · ${fmtBytes(state.total)}</b>${state.complete
          ? ""
          : ` (stopped at ${WALK_CAP} paths)`}
      </div>
    </div>
  `;
}

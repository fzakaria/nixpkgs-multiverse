/* ---------- the universe: every measured version, one dot each ----------
 *
 * A canvas scatter of all ~240k versions: x is the revision that first
 * shipped it, y is installed size on a log scale. The slider picks a moment
 * in the 13 years; versions alive at that revision light up, everything else
 * stays as dim background. Canvas, not SVG — a quarter-million dots redraw
 * in a few milliseconds, which is what makes scrubbing feel like time travel.
 */

import { html, useState, useEffect, useMemo, useRef } from "htm/preact";

import { fetchJson } from "../data.js";
import { fmtBytes } from "../format.js";
import { YEAR_GAP, useWidth, Tooltip } from "../charts.js";

const UNI_H = 430;
const UNI_PAD = { left: 54, right: 12, top: 12, bottom: 26 };
const UNI_LOG_LO = 3; // 1 KB
const UNI_LOG_HI = 10.3; // ~20 GB
const UNI_GRID = 10; // px per hover-lookup cell

export function Universe({ revisions, navigate }) {
  const [data, setData] = useState(null);
  const [t, setT] = useState(null);
  const [hover, setHover] = useState(null);
  const canvasRef = useRef(null);
  const gridRef = useRef(null);
  const [wrapRef, width] = useWidth();

  const load = async () => {
    setData("loading");
    try {
      const [bin, meta] = await Promise.all([
        fetch("universe.bin").then((r) => {
          if (!r.ok) throw new Error(`universe.bin: HTTP ${r.status}`);
          return r.arrayBuffer();
        }),
        fetchJson("universe-meta.json"),
      ]);
      const n = new DataView(bin).getUint32(0, true);
      let o = 4;
      const firsts = new Uint16Array(bin, o, n);
      o += 2 * n;
      const lasts = new Uint16Array(bin, o, n);
      o += 2 * n;
      const sizes = new Uint32Array(bin, o, n);
      o += 4 * n;
      const attrs = new Uint16Array(bin, o, n);
      setData({ n, firsts, lasts, sizes, attrs, meta });
      setT(revisions.length - 1);
    } catch {
      setData("error");
    }
  };

  const alive = useMemo(() => {
    if (!data || typeof data === "string" || t == null) return 0;
    let a = 0;
    for (let i = 0; i < data.n; i++)
      if (data.firsts[i] <= t && t <= data.lasts[i]) a++;
    return a;
  }, [data, t]);

  useEffect(() => {
    if (!data || typeof data === "string" || t == null) return;
    const c = canvasRef.current;
    if (!c) return;
    const w = Math.max(320, Math.floor(width));
    const dpr = devicePixelRatio || 1;
    c.width = w * dpr;
    c.height = UNI_H * dpr;
    c.style.height = `${UNI_H}px`;
    const ctx = c.getContext("2d");
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, UNI_H);

    const css = getComputedStyle(document.documentElement);
    const cAlive = css.getPropertyValue("--chart-series").trim();
    const cDead = css.getPropertyValue("--muted").trim();
    const cText = css.getPropertyValue("--muted").trim();
    const cGrid = css.getPropertyValue("--line").trim();

    const plotW = w - UNI_PAD.left - UNI_PAD.right;
    const plotH = UNI_H - UNI_PAD.top - UNI_PAD.bottom;
    const nRev = revisions.length;
    const X = (off) => UNI_PAD.left + (off / (nRev - 1)) * plotW;
    const Y = (ns) =>
      UNI_PAD.top +
      (1 -
        (Math.min(UNI_LOG_HI, Math.max(UNI_LOG_LO, Math.log10(ns))) -
          UNI_LOG_LO) /
          (UNI_LOG_HI - UNI_LOG_LO)) *
        plotH;

    // Axes first, under the dots.
    ctx.font = "11px system-ui, sans-serif";
    ctx.fillStyle = cText;
    ctx.strokeStyle = cGrid;
    ctx.lineWidth = 1;
    for (const [exp, label] of [
      [3, "1 KB"],
      [6, "1 MB"],
      [9, "1 GB"],
    ]) {
      const y = Y(10 ** exp);
      ctx.beginPath();
      ctx.moveTo(UNI_PAD.left, y);
      ctx.lineTo(w - UNI_PAD.right, y);
      ctx.stroke();
      ctx.textAlign = "right";
      ctx.fillText(label, UNI_PAD.left - 6, y + 4);
    }
    ctx.textAlign = "center";
    let lastX = -Infinity;
    let lastYear = "";
    revisions.forEach((r, off) => {
      const year = r.date.slice(0, 4);
      if (year === lastYear) return;
      lastYear = year;
      const x = X(off);
      if (x - lastX < YEAR_GAP) return;
      lastX = x;
      ctx.fillText(year, x, UNI_H - 8);
    });

    // Dots in three states: alive at t (bright), superseded (its package
    // still ships a lit version — the ordinary march of upgrades, dim gray),
    // and extinct (no version of its package is alive at t — the lineage
    // itself is gone, dim red). Also rebuild the hover grid — cheap, and it
    // must match this exact layout.
    const cGone = css.getPropertyValue("--chart-removed").trim();
    const grid = new Map();
    const cell = (x, y) =>
      `${Math.floor(x / UNI_GRID)}:${Math.floor(y / UNI_GRID)}`;
    const { n, firsts, lasts, sizes, attrs } = data;
    const attrAlive = new Uint8Array(65536);
    for (let i = 0; i < n; i++)
      if (firsts[i] <= t && t <= lasts[i]) attrAlive[attrs[i]] = 1;
    // The future is not drawn: a version first shipped after `t` is unborn,
    // not dead, and painting it "extinct" red was a lie. Scrubbing forward
    // therefore grows the universe left to right.
    ctx.globalAlpha = 0.15;
    ctx.fillStyle = cDead;
    for (let i = 0; i < n; i++) {
      if (firsts[i] > t) continue;
      const liveNow = t <= lasts[i];
      const x = X(firsts[i]);
      const y = Y(sizes[i]);
      if (!liveNow && attrAlive[attrs[i]]) ctx.fillRect(x, y, 1.5, 1.5);
      const k = cell(x, y);
      if (!grid.has(k)) grid.set(k, []);
      grid.get(k).push(i);
    }
    ctx.globalAlpha = 0.3;
    ctx.fillStyle = cGone;
    for (let i = 0; i < n; i++) {
      if (firsts[i] > t || t <= lasts[i]) continue;
      if (attrAlive[attrs[i]]) continue;
      ctx.fillRect(X(firsts[i]), Y(sizes[i]), 1.5, 1.5);
    }
    ctx.globalAlpha = 0.9;
    ctx.fillStyle = cAlive;
    for (let i = 0; i < n; i++) {
      if (!(firsts[i] <= t && t <= lasts[i])) continue;
      ctx.fillRect(X(firsts[i]) - 1, Y(sizes[i]) - 1, 2.5, 2.5);
    }
    ctx.globalAlpha = 1;
    gridRef.current = { grid, X, Y };
  }, [data, t, width]);

  const findNearest = (e) => {
    const g = gridRef.current;
    if (!g || !data || typeof data === "string") return null;
    const box = canvasRef.current.getBoundingClientRect();
    const mx = e.clientX - box.left;
    const my = e.clientY - box.top;
    let best = null;
    let bestD = UNI_GRID * UNI_GRID;
    for (let dx = -1; dx <= 1; dx++)
      for (let dy = -1; dy <= 1; dy++) {
        const k = `${Math.floor(mx / UNI_GRID) + dx}:${Math.floor(my / UNI_GRID) + dy}`;
        for (const i of g.grid.get(k) || []) {
          const x = g.X(data.firsts[i]);
          const y = g.Y(data.sizes[i]);
          const d = (x - mx) ** 2 + (y - my) ** 2;
          if (d < bestD) {
            bestD = d;
            best = { i, x, y };
          }
        }
      }
    return best;
  };

  if (!data)
    return html`<button class="more" onClick=${load}>
      draw the universe — all measured versions on one canvas →
    </button>`;
  if (data === "loading")
    return html`<div class="capt">loading the universe…</div>`;
  if (data === "error")
    return html`<div class="capt">could not load universe.bin</div>`;

  const onMove = (e) => {
    const hit = findNearest(e);
    if (!hit) return setHover(null);
    const { i, x, y } = hit;
    setHover({
      x,
      y,
      attr: data.meta.attrs[data.attrs[i]],
      ver: data.meta.versions[i],
      ns: data.sizes[i],
      from: revisions[data.firsts[i]].date,
      to: revisions[data.lasts[i]].date,
    });
  };
  // The full target, not a patch: a patch merges onto the CURRENT route,
  // which here is view=stats — and the stats view drops `pkg` from the URL,
  // so the click silently did nothing. Same trap the Link component
  // documents.
  const onClick = () => {
    if (hover)
      navigate({
        view: "packages",
        pkg: hover.attr,
        ver: hover.ver,
        q: "",
        rev: "",
        release: "",
      });
  };

  return html`
    <figure class="universe" ref=${wrapRef}>
      <canvas
        ref=${canvasRef}
        onMouseMove=${onMove}
        onMouseLeave=${() => setHover(null)}
        onClick=${onClick}
        style=${hover ? "cursor:pointer" : ""}
      ></canvas>
      ${hover &&
      html`<${Tooltip} x=${hover.x} width=${width}>
        <b>${hover.attr}</b> ${hover.ver}
        <div class="k">${fmtBytes(hover.ns)} · ${hover.from} → ${hover.to}</div>
      <//>`}
      <div class="unislider">
        <input
          type="range"
          min="0"
          max=${revisions.length - 1}
          value=${t}
          onInput=${(e) => setT(+e.currentTarget.value)}
        />
        <span class="muted">
          ${revisions[t].date} — <b>${alive.toLocaleString()}</b> versions
          current, ${(data.n - alive).toLocaleString()} elsewhere in time
        </span>
      </div>
      <div class="capt">
        ${data.n.toLocaleString()} versions: x is the revision that first
        shipped it, y its installed size (log scale). Blue dots are what nixpkgs
        shipped at that moment; gray dots were superseded by a newer version of
        the same package; red dots belong to packages with no living version at
        that moment (extinct lineages).
      </div>
    </figure>
  `;
}

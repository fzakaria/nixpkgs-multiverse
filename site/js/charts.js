/* ---------- charts: shared plumbing ----------
 *
 * Hand-rolled SVG rather than a charting library: the page has no build step
 * and one pinned dependency, and these are a handful of charts with one or
 * two series each. This module holds what every chart shares — the plot
 * frame, tick placement, width measurement, hover mapping and the tooltip;
 * the charts themselves live with their views.
 *
 * Every chart carries a hover layer AND a table view. The tooltip is an
 * enhancement — no value is reachable only by hovering, which is also what
 * keeps the charts usable from a keyboard and in the CVD case.
 */

import { html, useState, useRef, useCallback } from "htm/preact";

// Left needs room for y-axis labels; right matches it so the plotted area is
// centred in the card rather than hugging the right edge — which also stops
// the end-dot and its surface ring being clipped by the figure bounds.
export const PLOT = { top: 16, right: 44, bottom: 22, left: 44 };
export const PLOT_H = 150;
export const TL_ROW_H = 15; // one version's row in the package timeline
export const TL_LABEL_W = 92;

// Axis ticks on clean numbers. A tick set derived from the raw max lands on
// values like 24,855 that nobody reads; step to the next 1/2/5×10ⁿ instead.
export function niceTicks(max, count = 4) {
  if (max <= 0) return [0];
  const raw = max / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10].find((m) => m * mag >= raw) * mag;
  // The top tick has to be at or above `max`. Stopping at the last tick within
  // `max` leaves the scale topping out below the data — 24,855 attributes on a
  // 20,000 axis draws the line 26px ABOVE the plot, and since the svg has
  // overflow visible it escapes upward into the subtitle rather than clipping.
  const top = Math.ceil(max / step) * step;
  const out = [];
  for (let v = 0; v <= top; v += step) out.push(v);
  return out;
}

// Year labels for a time axis, placed by pixel distance rather than by index.
//
// Counting rows (every Nth month, every Nth year) assumes the months are evenly
// spread and they are not: the index is sparse before 2016 — one revision in
// 2013, none at all in 2014 — so the first four year-starts sit within a few
// pixels of each other and their labels overlap into mush. Dropping any label
// that lands within `minPx` of the last one drawn keeps the axis readable at
// every width, and is what lets the same code serve a 380px phone.
export function yearTicks(rows, X, minPx) {
  const firsts = [];
  rows.forEach((r, n) => {
    const y = r.month.slice(0, 4);
    if (!firsts.length || firsts[firsts.length - 1].y !== y)
      firsts.push({ y, n });
  });
  const out = [];
  let lastX = -Infinity;
  for (const t of firsts) {
    const x = X(t.n);
    if (x - lastX < minPx) continue;
    out.push({ ...t, x });
    lastX = x;
  }
  return out;
}
export const YEAR_GAP = 46; // px a four-digit year needs before the next one

// SVG scales to its container, but text must not scale with it, so the chart
// is drawn at the measured pixel width rather than through a viewBox.
//
// A callback ref rather than useRef + useEffect([]): a chart that shows a
// loading line before its figure exists has no node to measure at mount, and a
// once-only effect never gets a second chance — the chart then draws itself at
// the fallback width forever, overflowing its container on anything narrower.
// This attaches the observer whenever the node appears and detaches when it
// goes, so remounting is handled too.
export function useWidth(fallback = 640) {
  const [w, setW] = useState(fallback);
  const obs = useRef(null);
  const ref = useCallback((node) => {
    obs.current?.disconnect();
    obs.current = null;
    if (!node) return;
    // Zero means the node is not rendered yet — inside a section still marked
    // hidden, or measured before layout. Taking it would compute a negative
    // plot width and draw nothing; hold the fallback until a real width
    // arrives, which the observer below delivers.
    const w0 = node.getBoundingClientRect().width;
    if (w0 > 0) setW(w0);
    obs.current = new ResizeObserver(([e]) => {
      if (e.contentRect.width > 0) setW(e.contentRect.width);
    });
    obs.current.observe(node);
  }, []);
  return [ref, w];
}

// Shared hover plumbing: map a pointer x to the nearest data index. The hit
// area is the whole plot rather than the marks, so there is no pinpointing.
export function useNearest(count, width) {
  const [i, setI] = useState(null);
  const inner = width - PLOT.left - PLOT.right;
  const onMove = (e) => {
    const box = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - box.left - PLOT.left;
    setI(
      Math.max(0, Math.min(count - 1, Math.round((x / inner) * (count - 1)))),
    );
  };
  return { i, onMove, onLeave: () => setI(null) };
}

export function Tooltip({ x, width, children }) {
  // Flip the tooltip to the left of the crosshair near the right edge so it
  // never overflows the figure.
  const flip = x > width - 130;
  return html`<div
    class="tip"
    style=${`left:${flip ? x - 8 : x + 8}px; top:4px; transform:translateX(${flip ? "-100%" : "0"})`}
  >
    ${children}
  </div>`;
}

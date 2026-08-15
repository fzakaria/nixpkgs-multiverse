/* ---------- stats: the trend charts, the universe, the census ----------
 *
 * The charts here are hand-rolled SVG over the shared plumbing in charts.js.
 * The universe canvas lives in universe.js; this module holds the trend
 * charts, the leaderboards, the cache census, and the Stats view that
 * composes them.
 */

import { html, useState } from "htm/preact";

import { SHARD_ERROR } from "../config.js";
import { useFile } from "../data.js";
import { compact, fmtBytes } from "../format.js";
import { Link } from "../router.js";
import {
  PLOT,
  PLOT_H,
  niceTicks,
  yearTicks,
  YEAR_GAP,
  useWidth,
  useNearest,
  Tooltip,
} from "../charts.js";
import { Universe } from "./universe.js";

// A single-series trend over time. No legend by design — one series means the
// title already names what is plotted, and a one-swatch box just restates it.
function LineChart({ title, sub, rows, value, format, unit, tickFormat }) {
  const [ref, width] = useWidth();
  const pts = rows.map(value);
  const max = Math.max(...pts);
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1];
  const inner = width - PLOT.left - PLOT.right;
  const X = (n) => PLOT.left + (n / (rows.length - 1)) * inner;
  const Y = (v) => PLOT.top + (1 - v / top) * PLOT_H;
  const { i, onMove, onLeave } = useNearest(rows.length, width);

  const line = pts.map((v, n) => `${n ? "L" : "M"}${X(n)},${Y(v)}`).join("");
  const area = `${line}L${X(pts.length - 1)},${Y(0)}L${X(0)},${Y(0)}Z`;
  const last = pts.length - 1;

  const years = yearTicks(rows, X, YEAR_GAP);

  return html`
    <div class="chart">
      <h3>${title}</h3>
      <p class="sub">${sub}</p>
      <figure ref=${ref}>
        <svg
          height=${PLOT_H + PLOT.top + PLOT.bottom}
          onMouseMove=${onMove}
          onMouseLeave=${onLeave}
        >
          <g class="grid">
            ${ticks.map(
              (t) =>
                html`<line
                  x1=${PLOT.left}
                  x2=${width - PLOT.right}
                  y1=${Y(t)}
                  y2=${Y(t)}
                />`,
            )}
          </g>
          ${ticks.map(
            (t) =>
              html`<text x=${PLOT.left - 6} y=${Y(t) + 4} text-anchor="end"
                >${(tickFormat ?? compact)(t)}</text
              >`,
          )}
          ${years.map(
            ({ y, x }) =>
              html`<text x=${x} y=${PLOT_H + PLOT.top + 15} text-anchor="middle"
                >${y}</text
              >`,
          )}
          <path class="area" d=${area} />
          <path class="series" d=${line} />
          ${i !== null &&
          html`<line
            class="crosshair"
            x1=${X(i)}
            x2=${X(i)}
            y1=${PLOT.top}
            y2=${PLOT.top + PLOT_H}
          />`}
          <circle
            class="enddot"
            cx=${X(i ?? last)}
            cy=${Y(pts[i ?? last])}
            r="4"
          />
        </svg>
        ${i !== null &&
        html`<${Tooltip} x=${X(i)} width=${width}>
          <span class="k">${rows[i].month}</span>
          <b>${format(pts[i])}</b> ${unit}
        <//>`}
      </figure>
      <details class="tableview">
        <summary>table view</summary>
        <table>
          <thead>
            <tr>
              <th>month</th>
              <th>${unit}</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(
              (r, n) =>
                html`<tr>
                  <td>${r.month}</td>
                  <td>${format(pts[n])}</td>
                </tr>`,
            )}
          </tbody>
        </table>
      </details>
    </div>
  `;
}

// Added above the zero line, removed below — the polarity is the story, so
// this is a diverging pair rather than two arbitrary categorical hues.
function ChurnChart({ rows }) {
  const [ref, width] = useWidth();
  const max = Math.max(...rows.map((r) => Math.max(r.added, r.removed)));
  const ticks = niceTicks(max, 3);
  const top = ticks[ticks.length - 1];
  const half = PLOT_H / 2;
  const inner = width - PLOT.left - PLOT.right;
  const zero = PLOT.top + half;
  const Y = (v) => zero - (v / top) * half;
  // A 2px gap in the surface color separates neighbours; nothing is stroked.
  const bw = Math.max(1, inner / rows.length - 2);
  const X = (n) => PLOT.left + (n / rows.length) * inner;
  const { i, onMove, onLeave } = useNearest(rows.length, width);

  return html`
    <div class="chart">
      <h3>Packages added and removed</h3>
      <p class="sub">
        Attributes entering and leaving nixpkgs each month. Above the line is
        added, below is removed.
      </p>
      <div class="legend">
        <span><i style="background:var(--chart-added)"></i>added</span>
        <span><i style="background:var(--chart-removed)"></i>removed</span>
      </div>
      <figure ref=${ref}>
        <svg
          height=${PLOT_H + PLOT.top + PLOT.bottom}
          onMouseMove=${onMove}
          onMouseLeave=${onLeave}
        >
          ${ticks.slice(1).map(
            (t) => html`
              <g class="grid">
                <line
                  x1=${PLOT.left}
                  x2=${width - PLOT.right}
                  y1=${Y(t)}
                  y2=${Y(t)}
                />
                <line
                  x1=${PLOT.left}
                  x2=${width - PLOT.right}
                  y1=${Y(-t)}
                  y2=${Y(-t)}
                />
              </g>
              <text x=${PLOT.left - 6} y=${Y(t) + 4} text-anchor="end"
                >${compact(t)}</text
              >
              <text x=${PLOT.left - 6} y=${Y(-t) + 4} text-anchor="end"
                >${compact(t)}</text
              >
            `,
          )}
          ${rows.map(
            (r, n) => html`
              <rect
                class="bar-added"
                x=${X(n)}
                width=${bw}
                y=${Y(r.added)}
                height=${zero - Y(r.added)}
              />
              <rect
                class="bar-removed"
                x=${X(n)}
                width=${bw}
                y=${zero}
                height=${zero - Y(r.removed)}
              />
            `,
          )}
          <line
            class="zero"
            x1=${PLOT.left}
            x2=${width - PLOT.right}
            y1=${zero}
            y2=${zero}
          />
          ${yearTicks(rows, X, YEAR_GAP).map(
            ({ y, x }) =>
              html`<text x=${x} y=${PLOT_H + PLOT.top + 15} text-anchor="middle"
                >${y}</text
              >`,
          )}
        </svg>
        ${i !== null &&
        html`<${Tooltip} x=${X(i)} width=${width}>
          <span class="k">${rows[i].month}</span> <b>+${rows[i].added}</b> /
          <b>−${rows[i].removed}</b>
        <//>`}
      </figure>
      <details class="tableview">
        <summary>table view</summary>
        <table>
          <thead>
            <tr>
              <th>month</th>
              <th>added</th>
              <th>removed</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(
              (r) =>
                html`<tr>
                  <td>${r.month}</td>
                  <td>${r.added}</td>
                  <td>${r.removed}</td>
                </tr>`,
            )}
          </tbody>
        </table>
      </details>
    </div>
  `;
}

// A plain top-N table in the charts' visual register.
function Leaderboard({
  title,
  sub,
  cols,
  rows,
  navigate,
  initial = 15,
  page = 150,
}) {
  if (!rows?.length) return null;
  const [limit, setLimit] = useState(initial);
  const visible = rows.slice(0, limit);
  const remaining = rows.length - limit;

  return html`
    <div class="chart">
      <h3>${title}</h3>
      <p class="sub">${sub}</p>
      <div class="tableview" style="margin-top:0">
        <table>
          <thead>
            <tr>
              ${cols.map((c) => html`<th key=${c}>${c}</th>`)}
            </tr>
          </thead>
          <tbody>
            ${visible.map(
              (r, i) => html`
                <tr key=${i}>
                  <td>
                    <${Link}
                      to=${{ pkg: r[0], ver: r.ver || "" }}
                      navigate=${navigate}
                      >${r[0]}<//
                    >
                    ${r[1] ? html` <span class="muted">${r[1]}</span>` : ""}
                  </td>
                  <td>${r[2]}</td>
                </tr>
              `,
            )}
          </tbody>
        </table>
        ${remaining > 0 &&
        html`<button
          class="more"
          onClick=${() => setLimit(limit + page)}
          style="margin-top:0.4rem"
        >
          ${`show ${Math.min(page, remaining)} more · ${remaining.toLocaleString()} remaining →`}
        </button>`}
      </div>
    </div>
  `;
}

/* ---------- the census: is thirteen years of software still alive ---------- */
function CacheHealth({ navigate }) {
  const census = useFile("census.json");
  if (!census || census === SHARD_ERROR) return null;
  const t = census.totals;
  const years = census.byYear.map((y) => ({ ...y, month: String(y.y) }));
  const bloat = census.bloat.filter((b) => b.medianNs != null);

  return html`
    <h2>The cache census</h2>
    <p class="muted">
      Every matched store path was asked for, by name, at${" "}
      <a href="https://cache.nixos.org">cache.nixos.org</a
      >${" on "}${census.at}.
    </p>
    <div class="kpis">
      <div class="kpi">
        <div class="v">${t.matched.toLocaleString()}</div>
        <div class="l">
          versions with a known store
          path${t.universe &&
          html`${" "}<span
              title="The unmatched remainder is a limit of name matching, not evidence of deletion: unfree and broken packages were never built by Hydra at all, and some derivation names drifted from their attribute."
              style="cursor:help; border-bottom:1px dotted currentColor"
              >(${Math.round((100 * t.matched) / t.universe)}% of
              ${t.universe.toLocaleString()})</span
            >`}
        </div>
      </div>
      <div class="kpi">
        <div class="v">${((t.alive / t.matched) * 100).toFixed(1)}%</div>
        <div class="l">of those still substitutable today</div>
      </div>
      <div class="kpi">
        <div class="v">${fmtBytes(t.aliveBytes)}</div>
        <div class="l">of history still downloadable</div>
      </div>
      <div class="kpi">
        <div class="v">${(t.matched - t.alive).toLocaleString()}</div>
        <div class="l">matched versions gone from the cache</div>
      </div>
    </div>

    <${LineChart}
      title="Survival by vintage"
      sub="Of the package versions whose newest build landed in each year, the share cache.nixos.org still serves."
      rows=${years}
      value=${(r) => (r.pairs ? (100 * r.alive) / r.pairs : 0)}
      format=${(v) => `${v.toFixed(1)}%`}
      unit="% alive"
    />

    ${bloat.length > 2 &&
    html`
      <${LineChart}
        title="The bloat curve"
        sub="Median installed (NAR) size of the package versions closing in each year. Measured from the cache's own records, not from changelogs."
        rows=${bloat.map((b) => ({ ...b, month: String(b.y) }))}
        value=${(r) => r.medianNs}
        format=${fmtBytes}
        tickFormat=${fmtBytes}
        unit="median installed size"
      />
    `}
    ${census.bloat.filter((b) => b.medianNd != null).length > 2 &&
    html`
      <${LineChart}
        title="Dependencies per package"
        sub="Median count of direct runtime references, by the year a version last shipped."
        rows=${census.bloat
          .filter((b) => b.medianNd != null)
          .map((b) => ({ ...b, month: String(b.y) }))}
        value=${(r) => r.medianNd}
        format=${(v) => v.toFixed(1)}
        unit="median direct deps"
      />
    `}

    <${Leaderboard}
      title="The immortals"
      sub="Versions still shipping today whose current unbroken run started longest ago."
      cols=${["package", "shipping since"]}
      rows=${(census.immortals || []).map(([a, v, d]) =>
        Object.assign([a, v, d], { ver: v }),
      )}
      navigate=${navigate}
    />
    <${Leaderboard}
      title="Biggest single-bump weight gains"
      sub="Consecutive versions of one package, ranked by how much installed size the bump added."
      cols=${["package", "gained"]}
      rows=${(census.jumps || []).map(([a, v1, v2, d]) =>
        Object.assign([a, `${v1} → ${v2}`, `+${fmtBytes(d)}`], { ver: v2 }),
      )}
      navigate=${navigate}
    />

    <${Leaderboard}
      title="Heaviest closures shipping today"
      sub="Current versions, ranked by full runtime closure."
      cols=${["package", "closure"]}
      rows=${(census.topClosures || []).map(([a, v, cs]) =>
        Object.assign([a, v, fmtBytes(cs)], { ver: v }),
      )}
      navigate=${navigate}
    />
    <${Leaderboard}
      title="Most depended-upon today"
      sub="Current versions, ranked by how many packages link against them at runtime."
      cols=${["package", "dependents"]}
      rows=${(census.topDeps || []).map(([a, n]) => [
        a,
        "",
        n.toLocaleString(),
      ])}
      navigate=${navigate}
    />
    <${Leaderboard}
      title="Largest losses"
      sub="The biggest builds the cache no longer serves."
      cols=${["package", "installed size"]}
      rows=${(census.biggestDead || []).map(([a, v, ns]) =>
        Object.assign([a, v, fmtBytes(ns)], { ver: v }),
      )}
      navigate=${navigate}
    />
  `;
}

export function Stats({ stats, revisions, navigate }) {
  if (!stats)
    return html`<div id="status" class="muted">Loading stats.json…</div>`;
  const t = stats.totals;
  const velocity = stats.monthly.filter((m) => m.commitsPerDay != null);

  return html`
    <p class="muted">
      What the index says about nixpkgs itself, ${t.firstDate} → ${t.lastDate}.
    </p>
    <div class="kpis">
      <div class="kpi">
        <div class="v">${t.attrs.toLocaleString()}</div>
        <div class="l">versioned attributes today</div>
      </div>
      <div class="kpi">
        <div class="v">${t.versions.toLocaleString()}</div>
        <div class="l">package versions ever</div>
      </div>
      <div class="kpi">
        <div class="v">${t.additions.toLocaleString()}</div>
        <div class="l">attributes added all time</div>
      </div>
      <div class="kpi">
        <div class="v">${t.removals.toLocaleString()}</div>
        <div class="l">attributes removed all time</div>
      </div>
    </div>

    <${LineChart}
      title="Commits per day"
      sub=${"nixpkgs' own commit counter, read out of each channel bump's name and divided by the days since the previous one."}
      rows=${velocity}
      value=${(r) => r.commitsPerDay}
      format=${(v) => v.toFixed(0)}
      unit="commits/day"
    />

    <${LineChart}
      title="Versioned attributes in nixpkgs"
      sub="Top-level attributes carrying a version at each month's last channel bump. Package sets and anything without a .version are not counted."
      rows=${stats.monthly}
      value=${(r) => r.attrs}
      format=${(v) => v.toLocaleString()}
      unit="attributes"
    />

    <${ChurnChart} rows=${stats.monthly} />

    ${revisions.length > 1 &&
    html`
      <h2>The universe</h2>
      <p class="muted">
        Every package version the cache could measure, drawn at once.
      </p>
      <${Universe} revisions=${revisions} navigate=${navigate} />
    `}

    <${CacheHealth} navigate=${navigate} />
  `;
}

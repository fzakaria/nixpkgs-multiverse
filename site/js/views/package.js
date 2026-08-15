/* ---------- the package page ----------
 *
 * One attribute's version table, its shipping timeline, its weight chart, and
 * a row per version carrying the run/pin commands plus the store metadata
 * components out of package-store.js.
 */

import { html, useState, useEffect, useRef, useCallback } from "htm/preact";

import { FLAKE, REV_ABBREV, SHARD_ERROR } from "../config.js";
import { storePathOf } from "../cache.js";
import {
  Shard,
  useShard,
  useWholeShard,
  useHistory,
  useVersions,
  refAttr,
  refVer,
  runsOf,
} from "../data.js";
import {
  archiveFor,
  compareVersions,
  domId,
  fmtBytes,
  label,
} from "../format.js";
import { Link, Nav } from "../router.js";
import { Row, Cmd, useLinkableRow, useBulk, nextSeq } from "../ui.js";
import {
  PLOT,
  PLOT_H,
  TL_ROW_H,
  TL_LABEL_W,
  niceTicks,
  yearTicks,
  YEAR_GAP,
  useWidth,
  useNearest,
  Tooltip,
} from "../charts.js";
import {
  CacheBadge,
  Deps,
  UsedBy,
  DepDiff,
  ClosureLive,
  GraphExplorer,
} from "./package-store.js";

// The runs for one version: when it was actually the version nixpkgs shipped.
// Each end is a link to that revision, so a lifetime is navigable rather than
// just readable.
function Runs({ runs, revisions, navigate }) {
  if (!runs) return null;
  return html`
    <div class="capt">
      ${runs.length === 1
        ? "when this was the version nixpkgs shipped"
        : `${runs.length} separate stretches — it left nixpkgs and came back`}
    </div>
    <div class="runs">
      ${runs.map(([s, e]) => {
        const a = revisions[s],
          b = revisions[e];
        if (!a) return null;
        return html`<div>
          <${Link}
            to=${{ view: "revisions", rev: a.rev.slice(0, REV_ABBREV) }}
            navigate=${navigate}
            >${a.date}<//
          >${s === e
            ? html`<span class="muted"> · one revision</span>`
            : html`<span class="muted"> → </span>
                <${Link}
                  to=${{ view: "revisions", rev: b.rev.slice(0, REV_ABBREV) }}
                  navigate=${navigate}
                  >${b.date}<//
                >
                <span class="muted"> · ${e - s + 1} revisions</span>`}
        </div>`;
      })}
    </div>
  `;
}

function VersionRow({
  attr,
  v,
  r,
  runs,
  revisions,
  selected,
  bulk,
  onOpenChange,
  navigate,
  entry,
  paths,
  prevEntry,
  rd,
  metaReady,
}) {
  const { open, ref, toggle } = useLinkableRow(
    selected,
    (isOpen) => navigate({ ver: isOpen ? v : "" }, Nav.REPLACE),
    bulk,
  );

  useEffect(() => onOpenChange(v, open), [open]);

  const refsOf = (e) => e?.r && paths && e.r.map((i) => paths[i]);
  const archive = archiveFor("unstable", r.name);
  return html`
    <${Row}
      cols="cols-ver"
      id=${domId(`${attr}-${v}`)}
      label=${`version ${v}`}
      open=${open}
      toggle=${toggle}
      rowRef=${ref}
      body=${html`
        <${Cmd}
          text=${`nix run '${FLAKE}#versions.${attr}."${v}"'`}
          caption="run this version"
        />
        ${entry &&
        html`
          <${Cmd}
            text=${`nix-store --realise ${storePathOf(attr, v, entry)}`}
            caption="materialize with zero evaluation — substituted straight from cache.nixos.org"
          />
          <${CacheBadge} entry=${entry} />
        `}
        <${Cmd}
          text=${`github:NixOS/nixpkgs/${r.rev}`}
          caption="pin another flake's nixpkgs to it"
        />
        <${Runs} runs=${runs} revisions=${revisions} navigate=${navigate} />
        ${metaReady &&
        !entry &&
        html`<div class="capt">
          no store path is known for this version — it never appeared in a
          channel's store-paths listing (Hydra does not build unfree or broken
          packages), or its derivation name has drifted from the attribute name
          — so cache size, dependency and closure data are unavailable
        </div>`}
        ${entry &&
        !entry.r &&
        html`<div class="capt">
          no runtime references were recorded for this build — either the path
          genuinely references nothing, or this is a multi-output package whose
          payload lives in sibling outputs (‑lib, ‑bin) the prototype does not
          index
        </div>`}
        ${entry &&
        (() => {
          // A wrapper names its payload in its own references: the same
          // attribute with -unwrapped. Say so, or the tiny NAR above reads
          // as an error.
          const inner = refsOf(entry)?.find(
            (p) => refAttr(p) === `${attr}-unwrapped`,
          );
          return (
            inner &&
            html`<div class="capt">
              this attribute is a wrapper — the application itself is${" "}
              <${Link}
                to=${{ pkg: refAttr(inner), ver: refVer(inner) }}
                navigate=${navigate}
                >${refAttr(inner)} ${refVer(inner)}<//
              >; the installed size above is the wrapper's own
            </div>`
          );
        })()}
        ${entry?.o?.length &&
        html`<div class="capt">
          multi-output package — sibling outputs seen in consumers' closures:
          ${" " + entry.o.map(([s, sz]) => `${s} ${fmtBytes(sz)}`).join(" · ")}
        </div>`}
        ${entry &&
        html`
          <${Deps}
            refs=${refsOf(entry)}
            src=${entry.rsrc}
            navigate=${navigate}
          />
          <${DepDiff} refs=${refsOf(entry)} prevRefs=${refsOf(prevEntry)} />
          <${UsedBy} rd=${rd} navigate=${navigate} />
          ${entry.cs != null &&
          html`<div class="capt">
            closure at census: <b>${fmtBytes(entry.cs)}</b>
            ${` across ${entry.cn ?? "?"} paths`}
          </div>`}
          <div class="links">
            <${ClosureLive} entry=${entry} />
            <${GraphExplorer}
              attr=${attr}
              v=${v}
              entry=${entry}
              paths=${paths}
              navigate=${navigate}
            />
          </div>
        `}
      `}
    >
      <code>${v}</code>
      <span>
        <${Link}
          to=${{ view: "revisions", rev: r.rev.slice(0, REV_ABBREV) }}
          navigate=${navigate}
        >
          ${label(r)}
        <//>
      </span>
      <span class="rowsize muted">
        ${entry?.ns != null ? fmtBytes(entry.ns) : ""}
        ${entry && entry.ok === 0
          ? html`<span class="badge-dead">○</span>`
          : ""}
      </span>
      <span class="muted"
        >${archive && html`<a href=${archive}>${r.name}</a>`}</span
      >
    <//>
  `;
}

export function PackageDetail({ attr, route, revisions, navigate }) {
  const versions = useVersions(attr);
  const hist = useHistory(attr);
  const metaFile = useWholeShard(Shard.META, attr);
  const revdeps = useShard(Shard.REVDEPS, attr);
  const [bulk, bulkButton] = useBulk();
  const [openVers, setOpenVers] = useState(() => new Set());
  // Read inside toggleVer without making it depend on the set, so the callback
  // stays stable and every row does not re-render on each open/close.
  const openRef = useRef(openVers);
  openRef.current = openVers;

  const onOpenChange = useCallback((v, isOpen) => {
    setOpenVers((prev) => {
      if (prev.has(v) === isOpen) return prev;
      const next = new Set(prev);
      if (isOpen) next.add(v);
      else next.delete(v);
      return next;
    });
  }, []);

  // Clicking a bar drives the row directly rather than going through the URL.
  // `ver` can only name one version, so routing the click through it could
  // open a row but never close one — the timeline toggled on and never off.
  const [force, setForce] = useState({});
  // navigate closes over the current route, so it is a new function every
  // render; holding it in a ref keeps toggleVer stable and stops every row
  // re-rendering whenever the route changes.
  const navRef = useRef(navigate);
  navRef.current = navigate;

  const toggleVer = useCallback((v) => {
    const willOpen = !openRef.current.has(v);
    setForce((prev) => ({ ...prev, [v]: { open: willOpen, seq: nextSeq() } }));
    // The URL holds the most recently expanded version, whichever way it was
    // opened. Composing every open row into the query was the alternative and
    // does not scale: expanding all 1,538 revisions would be a ~20,000
    // character URL, past what servers and CDNs accept.
    navRef.current({ ver: willOpen ? v : "" }, Nav.REPLACE);
  }, []);

  // An expand-all supersedes every per-version force, otherwise a row touched
  // through the graph would ignore the button from then on.
  useEffect(() => setForce({}), [bulk?.seq]);
  if (!versions)
    return html`<div id="status" class="muted">Loading versions…</div>`;
  if (versions === SHARD_ERROR)
    return html`<div id="status" class="muted">
      Could not load the versions of <code>${attr}</code>.
    </div>`;
  if (!Object.keys(versions).length)
    return html`<div id="status" class="muted">
      No attribute named <code>${attr}</code> in the index.
    </div>`;
  // The table is a join against revisions.json: every row names the revision
  // that shipped its version, and the lifetime line below reads dates out of
  // it by offset. The shard is 11 KB and revisions.json is 342 KB, so the
  // shard now routinely wins the race that used to be impossible — versions
  // arrived behind revisions when both came out of one sequential chain.
  if (!revisions.length)
    return html`<div id="status" class="muted">Loading revisions…</div>`;

  const vers = Object.entries(versions).sort((a, b) =>
    compareVersions(b[0], a[0]),
  ); // newest first

  // Store metadata, when the shard has landed: per-version meta entries, the
  // shard's intern table for references, and this attr's reverse deps.
  const meta =
    metaFile && metaFile !== SHARD_ERROR ? metaFile.attrs?.[attr] : null;
  const metaPaths =
    metaFile && metaFile !== SHARD_ERROR ? metaFile.paths : null;
  const rds = revdeps && revdeps !== SHARD_ERROR ? revdeps : null;

  // Something the table does not already say: when this package entered
  // nixpkgs, and whether it is still there. "newest first, click to expand"
  // described the widget; this describes the package.
  // `hist` is the sentinel string "error" when the shard failed to load.
  // Treating that as data walks its characters and ends at revisions[NaN].date,
  // which throws — so everything below reads `history`, which is null instead.
  const history = hist && hist !== "error" ? hist : null;
  const offs = history
    ? Object.values(history).flatMap((v) => runsOf(v).flat())
    : [];
  const gone = offs.length && Math.max(...offs) < revisions.length - 1;
  // How much of this package the cache could measure, so a row without a
  // badge reads as a stated limit rather than a silent absence.
  const covered = meta ? vers.filter(([v]) => meta[v]).length : null;
  const coverage =
    covered != null && covered < vers.length
      ? ` · cache data for ${covered} of ${vers.length} versions`
      : "";
  const lifetime =
    (!offs.length
      ? `${vers.length} versions`
      : `${vers.length} versions · first packaged ${revisions[Math.min(...offs)].date}` +
        (gone ? ` · gone since ${revisions[Math.max(...offs)].date}` : "")) +
    coverage;

  return html`
    <h2 class="bulkline">
      <span>
        <code>${attr}</code>
        <span class="muted">· ${lifetime}</span>
      </span>
      ${bulkButton}
    </h2>
    <${Timeline}
      attr=${attr}
      hist=${hist}
      revisions=${revisions}
      openVers=${openVers}
      toggleVer=${toggleVer}
      route=${route}
      navigate=${navigate}
    />
    ${meta && html`<${WeightChart} attr=${attr} meta=${meta} vers=${vers} />`}
    <div class="head cols-ver">
      <span></span><span>version</span><span>newest revision shipping it</span
      ><span>size</span><span>channel build</span>
    </div>
    ${vers.map(([v, off], i) => {
      const r = revisions[off];
      if (!r) return null;
      return html`
        <${VersionRow}
          key=${`${attr}:${v}`}
          attr=${attr}
          v=${v}
          r=${r}
          runs=${history?.[v] && runsOf(history[v])}
          revisions=${revisions}
          selected=${route.ver === v}
          bulk=${force[v] ?? bulk}
          onOpenChange=${onOpenChange}
          navigate=${navigate}
          entry=${meta?.[v]}
          paths=${metaPaths}
          prevEntry=${meta?.[vers[i + 1]?.[0]]}
          rd=${rds?.[v]}
          metaReady=${!!(metaFile && metaFile !== SHARD_ERROR)}
        />
      `;
    })}
  `;
}

/* ---------- the weight of a package over time ----------
 *
 * Installed size (NarSize) and closure size per version, oldest to newest.
 * The exact numbers the cache recorded when each version was built — a
 * software-bloat curve nobody has been able to draw from changelogs.
 */
function WeightChart({ attr, meta, vers }) {
  const [ref, width] = useWidth();
  // Chronological by shipping revision, NOT by version number: release
  // trains overlap (firefox ESR ships beside current), and this chart is
  // about weight over TIME — so its x order can differ from the version
  // table's, which is version-number order.
  const rows = vers
    .slice()
    .sort((a, b) => a[1] - b[1])
    .map(([v]) => ({ v, e: meta[v] }))
    .filter((r) => r.e?.ns != null);
  if (rows.length < 3) return null;

  const hasCs = rows.some((r) => r.e.cs != null);
  const max = Math.max(...rows.map((r) => Math.max(r.e.ns, r.e.cs || 0)));
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1];
  const inner = width - PLOT.left - PLOT.right;
  const X = (n) => PLOT.left + (n / Math.max(1, rows.length - 1)) * inner;
  const Y = (v) => PLOT.top + (1 - v / top) * PLOT_H;
  const { i, onMove, onLeave } = useNearest(rows.length, width);

  const line = (val) =>
    rows
      .map((r, n) => {
        const y = val(r);
        return y == null ? null : `${n ? "L" : "M"}${X(n)},${Y(y)}`;
      })
      .filter(Boolean)
      .join("");

  // Version labels on the x axis, thinned by pixel distance like yearTicks.
  const labels = [];
  let lastX = -Infinity;
  rows.forEach((r, n) => {
    const x = X(n);
    if (x - lastX < 70) return;
    labels.push({ v: r.v, x });
    lastX = x;
  });

  return html`
    <div class="chart">
      <h3>How heavy each version was</h3>
      <p class="sub">
        Installed size${hasCs ? " and full closure size" : ""} of every version
        of <code>${attr}</code>, as recorded by cache.nixos.org the day it was
        built. Versions in shipping order, oldest to newest.
      </p>
      <div class="legend">
        <span
          class="whatis"
          title="The size of this version's own store path — the uncompressed NAR archive Hydra built. Its dependencies are not included; for wrappers and multi-output packages this can be tiny while the real payload sits in the closure."
          ><i style="background:var(--chart-series)"></i>installed (NAR)</span
        >
        ${hasCs &&
        html`<span
          class="whatis"
          title="The store path plus everything it references, transitively — what a fresh machine has to download to run this version."
          ><i style="background:var(--chart-removed)"></i>closure</span
        >`}
      </div>
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
                >${fmtBytes(t)}</text
              >`,
          )}
          ${labels.map(
            ({ v, x }) =>
              html`<text x=${x} y=${PLOT_H + PLOT.top + 15} text-anchor="middle"
                >${v.length > 10 ? v.slice(0, 9) + "…" : v}</text
              >`,
          )}
          ${hasCs &&
          html`<path class="series series-closure" d=${line((r) => r.e.cs)} />`}
          <path class="series" d=${line((r) => r.e.ns)} />
          ${i !== null &&
          html`<line
            class="crosshair"
            x1=${X(i)}
            x2=${X(i)}
            y1=${PLOT.top}
            y2=${PLOT.top + PLOT_H}
          />`}
        </svg>
        ${i !== null &&
        html`<${Tooltip} x=${X(i)} width=${width}>
          <span class="k">${rows[i].v}</span>
          <b>${fmtBytes(rows[i].e.ns)}</b> installed
          ${rows[i].e.cs != null &&
          html`<div><b>${fmtBytes(rows[i].e.cs)}</b> closure</div>`}
        <//>`}
      </figure>
    </div>
  `;
}

function Timeline({
  attr,
  hist,
  revisions,
  openVers,
  toggleVer,
  route,
  navigate,
}) {
  const [hover, setHover] = useState(null);
  const [ref, width] = useWidth();

  if (hist === SHARD_ERROR)
    return html`<p class="muted">
      Could not load the version history for <code>${attr}</code>.
    </p>`;
  if (!hist) return html`<p class="muted">Loading timeline…</p>`;

  const vers = Object.keys(hist).sort((a, b) => compareVersions(b, a));
  if (!vers.length) return null;

  // The axis spans this package's own lifetime, not the whole index. A package
  // first packaged in 2022 would otherwise spend three quarters of its chart on
  // empty years, squeezing every bar it does have into the right-hand corner.
  const bounds = vers.flatMap((v) => runsOf(hist[v]).flat());
  const span = Math.max(1, Math.max(...bounds) - Math.min(...bounds));
  const pad = Math.max(1, Math.round(span * 0.02));
  const lo = Math.max(0, Math.min(...bounds) - pad);
  const hi = Math.min(revisions.length - 1, Math.max(...bounds) + pad);

  // Adaptive density: firefox has 300+ versions, and 15px rows would make
  // the chart taller than the rest of the page combined. Rows shrink to as
  // little as 2px — the bars stay hoverable strips — and the per-row labels
  // go once rows are too thin to label; the tooltip still names them.
  const rowH = Math.max(2, Math.min(TL_ROW_H, Math.floor(560 / vers.length)));
  const showLabels = rowH >= 10;
  const gutter = showLabels ? Math.min(TL_LABEL_W, width * 0.28) : 8;
  const inner = width - gutter - PLOT.right;
  const X = (off) => gutter + ((off - lo) / Math.max(1, hi - lo)) * inner;
  const height = vers.length * rowH + PLOT.bottom;
  const barPad = showLabels ? 3 : Math.max(0, Math.floor((rowH - 3) / 2));

  // Same distance rule as the trend charts, over the visible window only: the
  // index has one revision in 2013 and none in 2014, so year-start offsets
  // bunch up wherever the sparse early period is on screen.
  const years = yearTicks(
    revisions.slice(lo, hi + 1).map((r) => ({ month: r.date })),
    (n) => X(lo + n),
    YEAR_GAP + 14,
  );

  return html`
    <div class="chart">
      <h3>When each version was the one nixpkgs shipped</h3>
      <p class="sub">
        One row per version. A version with a gap draws as more than one bar —
        it left nixpkgs and came back.
      </p>
      <figure ref=${ref}>
        <svg height=${height} onMouseLeave=${() => setHover(null)}>
          <g class="grid">
            ${years.map(
              ({ x }) =>
                html`<line x1=${x} x2=${x} y1="0" y2=${vers.length * rowH} />`,
            )}
          </g>
          ${years.map(
            ({ y, x }) =>
              html`<text x=${x} y=${height - 6} text-anchor="middle"
                >${y}</text
              >`,
          )}
          ${vers.map((v, n) => {
            const y = n * rowH;
            // Every open row, not just the one in the URL: `ver` holds a
            // single version, so with several rows expanded the graph would
            // highlight one of them and silently ignore the rest.
            const sel = openVers.has(v) || route.ver === v;
            return html`
              <g
                class=${`tl-row${sel ? " tl-sel" : ""}`}
                onMouseEnter=${() => setHover({ v, y })}
                onClick=${() => toggleVer(v)}
                style="cursor:pointer"
              >
                <rect
                  class="tl-bg"
                  x="0"
                  y=${y}
                  width=${Math.max(0, width)}
                  height=${rowH}
                  fill="transparent"
                />
                ${showLabels &&
                html`<text class="tl-label" x="0" y=${y + 11}>${v}</text>`}
                ${runsOf(hist[v]).map(([s, e]) => {
                  // A single-revision run would otherwise be invisible, so
                  // every bar gets a 2px floor.
                  const x = X(s);
                  const w = Math.max(2, X(e) - x);
                  return html`<rect
                    class="tl-bar"
                    x=${x}
                    y=${y + barPad}
                    width=${w}
                    height=${Math.max(2, rowH - 2 * barPad)}
                    rx="1"
                  />`;
                })}
              </g>
            `;
          })}
        </svg>
        ${hover &&
        html`<div
          class="tip"
          style=${`left:${gutter}px; top:${hover.y + rowH}px`}
        >
          <b>${hover.v}</b>
          ${runsOf(hist[hover.v]).map(
            ([s, e]) =>
              html`<div class="k">
                ${revisions[s].date}${s === e ? "" : ` → ${revisions[e].date}`}
              </div>`,
          )}
        </div>`}
      </figure>
    </div>
  `;
}

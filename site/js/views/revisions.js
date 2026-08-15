/* ---------- revisions ---------- */

import { html, useState, useEffect } from "htm/preact";

import {
  FLAKE,
  COMMIT_URL,
  MAX_PINS,
  REV_PAGE,
  REV_ABBREV,
  SHARD_ERROR,
} from "../config.js";
import { useFullIndex, pinsFor } from "../data.js";
import { archiveFor, domId, label } from "../format.js";
import { Link, Nav } from "../router.js";
import { Row, Cmd, useLinkableRow, useBulk } from "../ui.js";

function RevPins({ off, navigate }) {
  const [showAll, setShowAll] = useState(false);
  const index = useFullIndex();
  if (index === SHARD_ERROR)
    return html`<div class="muted">could not load the index</div>`;
  if (!index) return html`<div class="muted">index still loading…</div>`;

  const pins = pinsFor(index, off);
  const shown = showAll ? pins : pins.slice(0, MAX_PINS);
  return html`
    <div class="capt">
      ${pins.length.toLocaleString()} package versions pinned at this revision
      (their newest shipping revision is this one)
    </div>
    <div class="pins">
      ${shown.map(
        ([a, v]) => html`
          <div>
            <${Link} class="attr" to=${{ pkg: a, ver: "" }} navigate=${navigate}
              >${a}<//
            >${" "}
            <span class="muted">${v}</span>
          </div>
        `,
      )}
    </div>
    ${pins.length > shown.length &&
    html`<button class="more" onClick=${() => setShowAll(true)}>
      show all ${pins.length.toLocaleString()}
    </button>`}
  `;
}

// `churn` is [added, removed] for this revision against the one before it,
// read straight off stats.json by offset — the revisions table would otherwise
// have to load the 8 MB history to know it.
function RevRow({ r, off, selected, churn, bulk, navigate }) {
  // A revision pins up to MAX_PINS package versions, each one a link. That is
  // fine for a row opened on its own and ruinous for 150 at once, so a mass
  // expand shows the command and puts the pins one click away.
  //
  // Decided when the row opens, NOT read live from `bulk`: collapsing flips
  // bulk.open to false while every row is still open, so a live read renders
  // all 150 pin lists for one frame before the rows close — ~120k nodes built
  // and thrown away, measured at 2.8s against 60ms to expand.
  const [pins, setPins] = useState(false);
  const { open, ref, toggle } = useLinkableRow(
    selected,
    (isOpen) =>
      navigate({ rev: isOpen ? r.rev.slice(0, REV_ABBREV) : "" }, Nav.REPLACE),
    bulk,
  );
  // Must sit below `open` — naming it in the dependency array above the
  // declaration is a temporal-dead-zone throw at render time, not a warning.
  useEffect(() => setPins(open && !bulk?.open), [open]);

  const archive = archiveFor("unstable", r.name);
  return html`
    <${Row}
      cols="cols-rev"
      id=${domId(r.rev)}
      label=${`revision ${r.date}`}
      open=${open}
      toggle=${toggle}
      rowRef=${ref}
      body=${html`
        <${Cmd}
          text=${`nix run ${FLAKE}#${label(r)}.hello`}
          caption="run anything out of this revision"
        />
        ${pins
          ? html`<${RevPins} off=${off} navigate=${navigate} />`
          : html`<button class="more" onClick=${() => setPins(true)}>
              show the package versions pinned here
            </button>`}
      `}
    >
      <span>${r.date}</span>
      <code
        ><a href=${COMMIT_URL + r.rev}>${r.rev.slice(0, REV_ABBREV)}</a></code
      >
      <span class="delta">
        ${churn &&
        html`${churn[0]
          ? html`<span class="a">+${churn[0]}</span>`
          : null}${churn[0] && churn[1] ? " " : ""}${churn[1]
          ? html`<span class="d">−${churn[1]}</span>`
          : null}`}
      </span>
      <span class="muted">
        ${archive
          ? html`<a href=${archive}>${r.name}</a>`
          : r.name || r.channel || ""}
      </span>
    <//>
  `;
}

export function Revisions({ route, revisions, stats, navigate }) {
  const all = revisions.map((r, off) => ({ r, off })).reverse();
  const [shown, setShown] = useState(REV_PAGE);
  const [bulk, bulkButton] = useBulk();
  // A linked-to revision has to be rendered for its row to open itself, so
  // widen the window far enough to include it.
  const linked = route.rev
    ? all.findIndex(({ r }) => r.rev.startsWith(route.rev))
    : -1;
  const limit = Math.max(shown, linked + 1);
  const rows = all.slice(0, limit);
  return html`
    <h2 class="bulkline">
      <span class="muted"
        >${revisions.length.toLocaleString()} channel bumps ·
        ${revisions[0].date} → ${revisions[revisions.length - 1].date}</span
      >
      ${bulkButton}
    </h2>
    <div class="head cols-rev">
      <span></span><span>date</span><span>commit</span><span>packages</span
      ><span>channel build</span>
    </div>
    ${rows.map(
      ({ r, off }) => html`
        <${RevRow}
          key=${r.rev}
          r=${r}
          off=${off}
          selected=${!!route.rev && r.rev.startsWith(route.rev)}
          churn=${stats?.churn?.[off]}
          bulk=${bulk}
          navigate=${navigate}
        />
      `,
    )}
    ${limit < all.length &&
    html`<button class="more" onClick=${() => setShown(limit + REV_PAGE)}>
      ${`show ${Math.min(REV_PAGE, all.length - limit)} more · ${(
        all.length - limit
      ).toLocaleString()} older revisions remaining`}
    </button>`}
  `;
}

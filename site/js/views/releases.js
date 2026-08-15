/* ---------- releases ---------- */

import { html } from "htm/preact";

import { FLAKE, COMMIT_URL, REV_ABBREV } from "../config.js";
import { archiveFor, domId } from "../format.js";
import { Link, Nav } from "../router.js";
import { Row, Cmd, useLinkableRow, useBulk } from "../ui.js";

function ReleaseRow({ name, r, near, selected, bulk, navigate }) {
  const { open, ref, toggle } = useLinkableRow(
    selected,
    (isOpen) => navigate({ release: isOpen ? name : "" }, Nav.REPLACE),
    bulk,
  );

  const archive = archiveFor(name, r.name);
  return html`
    <${Row}
      cols="cols-rel"
      id=${domId(`rel-${name}`)}
      label=${`release ${name}`}
      open=${open}
      toggle=${toggle}
      rowRef=${ref}
      body=${html`
        <${Cmd}
          text=${`nix run ${FLAKE}#${name}.hello`}
          caption="run anything out of this release, backports included"
        />
        ${near &&
        html`<div class="links">
          <${Link}
            to=${{ view: "revisions", rev: near.rev.slice(0, REV_ABBREV) }}
            navigate=${navigate}
          >
            unstable as of ${r.date} →
          <//>
        </div>`}
      `}
    >
      <code>${name}</code>
      <span>${r.date}</span>
      <code
        ><a href=${COMMIT_URL + r.rev}>${r.rev.slice(0, REV_ABBREV)}</a></code
      >
      <span class="muted"
        >${archive
          ? html`<a href=${archive}>${r.name}</a>`
          : r.name || ""}</span
      >
    <//>
  `;
}

export function Releases({ route, releases, revisions, navigate }) {
  const rows = Object.entries(releases).reverse();
  const [bulk, bulkButton] = useBulk();
  return html`
    <p class="muted bulkline">
      <span>
        A release moves as backports land, exactly like
        <code>github:NixOS/nixpkgs/nixos-26.05</code>.
      </span>
      ${bulkButton}
    </p>
    <div class="head cols-rel">
      <span></span><span>release</span><span>as of</span><span>tip commit</span
      ><span>channel build</span>
    </div>
    ${rows.map(([name, r]) => {
      // A release tip lives on the release branch, so it is never an indexed
      // unstable revision; the honest internal link is unstable on the same
      // date — exactly what `at "<date>"` returns.
      let near = null;
      for (let i = revisions.length - 1; i >= 0; i--)
        if (revisions[i].date <= r.date) {
          near = revisions[i];
          break;
        }
      return html`
        <${ReleaseRow}
          key=${name}
          name=${name}
          r=${r}
          near=${near}
          selected=${route.release === name}
          bulk=${bulk}
          navigate=${navigate}
        />
      `;
    })}
  `;
}

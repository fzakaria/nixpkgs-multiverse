// Shared UI pieces used by every view: the disclosure row and the hooks that
// address it from the URL or drive it in bulk, and the copyable command block.

import { html, useState, useEffect, useRef } from "htm/preact";

import { COPY_FLASH_MS } from "./config.js";

const CopyIcon = () => html`
  <svg
    width="18"
    height="18"
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    stroke-width="1.4"
  >
    <rect x="5.5" y="5.5" width="8" height="8" rx="1" />
    <path d="M10.5 5.5v-2a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2" />
  </svg>
`;

// Shared behavior for a <details> row addressed by a URL param. A linked-to
// row (shared URL, or a click from another tab) opens itself and scrolls its
// summary line into view — the summary rather than the element, because
// centering the whole details would include the expanded body and land the
// viewport inside it. A row the user toggles by hand is already on screen,
// so it only records itself in the URL (or clears itself on close), without
// stacking history entries.
export function useLinkableRow(selected, record, bulk) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    if (!selected || open) return;
    setOpen(true);
    ref.current?.querySelector(".row").scrollIntoView({ block: "start" });
  }, [selected]);

  // Keyed on `seq` rather than on `open` so that expanding all, collapsing one
  // by hand, then expanding all again still fires.
  useEffect(() => {
    if (!bulk) return;
    setOpen(bulk.open);
  }, [bulk?.seq]);

  // Only a user action reaches here. The <details> version could not assume
  // that — the element fires `toggle` for programmatic opens too, so a bulk
  // expand looked exactly like 1,538 clicks and each one navigated. Driving
  // the open state ourselves makes the distinction structural.
  const toggle = () => {
    const next = !open;
    setOpen(next);
    if (next) record(true);
    else if (selected) record(false);
  };

  return { open, ref, toggle };
}

// The disclosure row.
//
// <details>/<summary> is the obvious markup and is exactly what Chromium
// flagged 348 times: everything visible while a row is collapsed has to live
// inside <summary>, these rows carry commit and channel-build links, and an
// interactive element nested inside a <summary> is not reliably reachable by
// keyboard or announced by assistive technology.
//
// So the disclosure is a real <button> and the links are its siblings — every
// one an ordinary tab stop, nothing nested inside anything interactive. The
// row stays clickable as a convenience on top of the button, never as the only
// way to open it, and a click that lands on a link is left alone.
export function Row({ cols, id, label, open, toggle, rowRef, children, body }) {
  const onClick = (e) => {
    if (e.target.closest("a")) return;
    toggle();
  };
  return html`
    <div class="item" ref=${rowRef}>
      <div class=${`row ${cols}`} onClick=${onClick}>
        <button
          class="disclose"
          type="button"
          aria-expanded=${open ? "true" : "false"}
          aria-controls=${id}
          aria-label=${`${open ? "Collapse" : "Expand"} ${label}`}
          onClick=${(e) => {
            e.stopPropagation();
            toggle();
          }}
        >
          ${open ? "▾" : "▸"}
        </button>
        ${children}
      </div>
      <div class="body" id=${id} hidden=${!open}>${open && body}</div>
    </div>
  `;
}

// Every {open, seq} force — expand-all and per-version alike — draws its
// sequence number from here. useLinkableRow keys its effect on `seq`, so two
// independent counters collide the moment both reach the same value: after one
// expand-all (seq 1), the first per-version toggle also minted seq 1, the dep
// did not change, and clicking a bar silently did nothing.
let forceSeq = 0;
export const nextSeq = () => ++forceSeq;

// One expand/collapse control per view. Returns the state to thread into every
// useLinkableRow on the page plus the button that drives it.
export function useBulk() {
  const [bulk, setBulk] = useState(null);
  const button = html`<button
    class="bulk"
    onClick=${() => setBulk({ open: !bulk?.open, seq: nextSeq() })}
  >
    ${bulk?.open ? "collapse all" : "expand all"}
  </button>`;
  return [bulk, button];
}

// A copyable command: one block, the command never wraps, the icon rides
// on the right edge and flashes a check after copying.
export function Cmd({ text, caption }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), COPY_FLASH_MS);
  };
  return html`
    ${caption && html`<div class="capt">${caption}</div>`}
    <div class="cmd">
      <code>${text}</code>
      <button title="copy" onClick=${copy}>
        ${copied ? "✓" : html`<${CopyIcon} />`}
      </button>
    </div>
  `;
}

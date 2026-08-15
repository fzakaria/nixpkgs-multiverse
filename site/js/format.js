// Pure formatting and comparison helpers, shared across modules. Nothing in
// this module touches the DOM, the network, or component state.

import { ARCHIVE_URL, REV_ABBREV } from "./config.js";

export const label = (r) => `${r.date}-${r.rev.slice(0, REV_ABBREV)}`;

// nixos/unstable/<name>/ for a revision, nixos/26.05/<name>/ for a release.
export const archiveFor = (channelDir, name) =>
  name ? `${ARCHIVE_URL}${channelDir}/${encodeURIComponent(name)}/` : null;

// Nix-style version ordering: split into digit and non-digit runs, compare
// digit runs numerically. Enough to put 3.12.10 after 3.12.7.
export function compareVersions(a, b) {
  const chunks = (s) => s.match(/\d+|\D+/g) || [];
  const ca = chunks(a),
    cb = chunks(b);
  for (let i = 0; i < Math.max(ca.length, cb.length); i++) {
    const x = ca[i] ?? "",
      y = cb[i] ?? "";
    if (x === y) continue;
    const nx = /^\d+$/.test(x),
      ny = /^\d+$/.test(y);
    if (nx && ny) return Number(x) - Number(y);
    return x < y ? -1 : 1;
  }
  return 0;
}

// A valid id from arbitrary text, for aria-controls.
export const domId = (s) => "b-" + s.replace(/[^a-zA-Z0-9_-]/g, "_");

export function fmtBytes(n) {
  if (n == null) return "?";
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = n;
  for (const u of units) {
    v /= 1024;
    if (v < 1024) return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${u}`;
  }
  return `${v.toFixed(1)} PB`;
}

// Strip the version off a drv name: "openssl-1.0.1f" -> "openssl". Same rule
// as Nix's parseDrvName — the version starts at the first dash before a digit.
export const pnameOf = (name) => name.split(/-(?=\d)/)[0];

// Compact axis-label numbers: 24,855 reads as "25k".
export const compact = (n) =>
  n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : `${n}`;

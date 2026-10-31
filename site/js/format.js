// Pure formatting helpers, shared across modules. Nothing in
// this module touches the DOM, the network, or component state.

import { ARCHIVE_URL, REV_ABBREV } from "./config.js";

export const label = (r) => `${r.date}-${r.rev.slice(0, REV_ABBREV)}`;

// nixos/unstable/<name>/ for a revision, nixos/26.05/<name>/ for a release.
// Every revision and every release carries the channel name the archive filed
// it under, so this always resolves to a listing.
export const archiveFor = (channelDir, name) =>
  `${ARCHIVE_URL}${channelDir}/${encodeURIComponent(name)}/`;

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

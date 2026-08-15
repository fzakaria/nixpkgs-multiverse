// Shared constants for the whole site. Every tunable number appears here —
// with its reasoning — exactly once, so a module never hard-codes a limit
// another module also depends on.

export const FLAKE = "github:fzakaria/nixpkgs-multiverse";
export const COMMIT_URL = "https://github.com/NixOS/nixpkgs/commit/";
// The channel archive: releases.nixos.org fronts the nix-releases bucket and
// renders ?prefix= as a browsable listing (a bare directory URL 404s).
export const ARCHIVE_URL = "https://releases.nixos.org/?prefix=nixos/";
export const MAX_RESULTS = 200;
export const MAX_PINS = 400;
// How many revision rows to render at once. All 1,538 is 52,000px of page
// before anything is even expanded, and expanding them all reaches 229,000px
// across 1,563 horizontally-scrollable <code> blocks — which lays out fine
// headless and janks a real browser badly. A window keeps both bounded.
export const REV_PAGE = 150;
// How much of a nixpkgs commit sha appears in labels and in the ?rev= param.
export const REV_ABBREV = 12;
export const COPY_FLASH_MS = 1200;

export const VIEWS = ["packages", "revisions", "releases", "stats"];

export const HTTP_NOT_FOUND = 404;

// What a data fetch resolves to when it fails. A sentinel rather than null,
// because "still loading" and "will never load" render differently and both
// have to be distinguishable from data.
export const SHARD_ERROR = "error";

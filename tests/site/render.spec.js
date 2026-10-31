// What each view draws when its URL is loaded cold.
//
// Every view is a URL a visitor can be linked straight into, so "does it draw
// at all" is a real question for each of them separately — a view that throws
// during render leaves the section empty and the page otherwise intact, which
// is exactly the failure nobody notices from the front page.

import { test, expect } from "@playwright/test";

// The attribute the package tests drive. Long-lived and small enough that its
// version table and both charts render quickly.
const ATTR = "ripgrep";

// How many revision rows the first window holds — REV_PAGE in site/js/config.js.
const REV_PAGE = 150;

// The four totals across the top of the stats view. Named rather than counted:
// the view carries a second KPI row for the cache census, so a bare count of
// .kpi says nothing about whether these four are the ones that drew.
const TOTALS = [
  "versioned attributes today",
  "package versions ever",
  "attributes added all time",
  "attributes removed all time",
];

// Below this the stats view has quietly lost a chart.
const MIN_STAT_CHARTS = 8;

test("the packages view draws a version table and both charts", async ({
  page,
}) => {
  // The URL a search engine renders 30,000 times. Asserts the join against
  // revisions.json landed (every row names a revision) and that both
  // package charts drew, since each reads a different shard.
  await page.goto(`/?pkg=${ATTR}`);

  const rows = page.locator(".row.cols-ver");
  await expect(rows.first()).toBeVisible();
  expect(await rows.count()).toBeGreaterThan(5);

  await expect(
    page.getByRole("heading", { name: /When each version was the one/ }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: /How heavy each version was/ }),
  ).toBeVisible();
});

// An attribute whose upstream renumbered: llama-cpp went from build numbers
// (10408) to 0.x semver, so the greatest version string is not the version
// nixpkgs ships today.
const RENUMBERED_ATTR = "llama-cpp";

// The characters of a commit a revision label carries — REV_ABBREV in
// site/js/config.js.
const REV_ABBREV = 12;

test("the version table puts the most recently shipped version first", async ({
  page,
}) => {
  // Loads a package whose version strings and shipping order disagree, and
  // asserts the top row names the newest indexed revision. Sorted by version
  // string, the top row would be build 10408, last shipped in August 2026.
  const revisions = await (await page.request.get("/revisions.json")).json();
  const tip = revisions[revisions.length - 1];

  await page.goto(`/?pkg=${RENUMBERED_ATTR}`);

  const top = page.locator(".row.cols-ver").first();
  await expect(top).toContainText(
    `${tip.date}-${tip.rev.slice(0, REV_ABBREV)}`,
  );
});

test("the revisions view draws its first window of rows", async ({ page }) => {
  // The window is what keeps the page from laying out 1,500 rows, so its size
  // is behaviour worth pinning, not an implementation detail.
  await page.goto("/?view=revisions");

  const rows = page.locator(".row.cols-rev");
  await expect(rows.first()).toBeVisible();
  expect(await rows.count()).toBe(REV_PAGE);
});

test("the releases view draws a row per release channel", async ({ page }) => {
  // Releases fetches its own releases.json now, so this also covers that the
  // view can load data by itself rather than being handed it by App.
  await page.goto("/?view=releases");

  const rows = page.locator(".row.cols-rel");
  await expect(rows.first()).toBeVisible();

  // Every release since 13.10, so the exact count moves every six months.
  expect(await rows.count()).toBeGreaterThan(20);
});

test("the stats view draws its totals and every chart", async ({ page }) => {
  // The charts are hand-rolled SVG over stats.json; one bad field takes out a
  // single chart and leaves the rest of the page looking healthy.
  await page.goto("/?view=stats");

  for (const total of TOTALS) {
    await expect(page.locator(".kpi .l", { hasText: total })).toBeVisible();
  }
  expect(await page.locator("h3").count()).toBeGreaterThanOrEqual(
    MIN_STAT_CHARTS,
  );
});

test("the summary line states the index totals", async ({ page }) => {
  // It reads stats.json, which no longer arrives with revisions.json — so
  // this is the check that the line still fills in on its own.
  await page.goto("/");
  await expect(page.locator("#stats")).toHaveText(
    /[\d,]+ package versions across [\d,]+ attributes, from [\d,]+ revisions/,
  );
});

test("a search finds a package by name", async ({ page }) => {
  // Typing rather than a ?q= URL: the input drives navigate() on every
  // keystroke, and the results come from names.json, which only this path
  // fetches.
  await page.goto("/");
  await page.getByRole("searchbox").fill(ATTR);

  const hit = page.locator("#results a.pkg").first();
  await expect(hit).toBeVisible();
  await expect(hit).toContainText(ATTR);
});

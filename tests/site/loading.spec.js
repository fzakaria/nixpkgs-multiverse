// What a page loads, and what it declines to load.
//
// This is the file that would have caught the three regressions the boot chain
// had accumulated, none of which is visible on screen: a package page fetching
// the releases table it never renders, pulling a 122 KB graph library for a
// graph nobody asked for, and building the revisions tab into a hidden section
// of itself. All three look perfect in a screenshot.

import { test, expect } from "@playwright/test";

const ATTR = "ripgrep";

// Exactly what a package URL is allowed to ask this origin for. The three
// whole files the shell needs, and one shard each of the four sharded indexes
// — "ri" being the first two characters of the attribute above.
//
// systems.json is the list of systems store paths are published for, which
// the picker offers. The alternate systems' own meta directories are
// deliberately absent: one is fetched only when a reader picks that system,
// which system.spec.js asserts from the other side.
//
// The store directories are named for their system, so the expected set is
// built from the site's own list rather than written down: the aggregated
// system is its first entry.
const packagePageFiles = (system) =>
  [
    "history/ri.json",
    `meta-${system}/ri.json`,
    `revdeps-${system}/ri.json`,
    "revisions.json",
    "stats.json",
    "systems.json",
    "versions/ri.json",
  ].sort();

// Every same-origin JSON file the page asked for while `run` was executing,
// sorted, so the set can be compared rather than searched.
async function jsonRequests(page, run) {
  const asked = new Set();
  const collect = (request) => {
    const url = new URL(request.url());
    if (url.origin !== new URL(page.url() || "http://127.0.0.1").origin) {
      return;
    }
    if (url.pathname.endsWith(".json")) {
      asked.add(url.pathname.replace(/^\//, ""));
    }
  };
  page.on("request", collect);
  await run();
  page.off("request", collect);
  return [...asked].sort();
}

test("a package page asks for exactly the files it renders", async ({
  page,
}) => {
  // An exact set, not a "does not contain releases.json" check: the point is
  // to notice anything new joining the boot chain, whichever file it is.
  const res = await page.request.get("/systems.json");
  expect(res.ok()).toBe(true);
  const [primary] = await res.json();

  const asked = await jsonRequests(page, async () => {
    await page.goto(`/?pkg=${ATTR}`);
    await expect(page.locator(".row.cols-ver").first()).toBeVisible();
  });
  expect(asked).toEqual(packagePageFiles(primary));
});

test("a package page does not pull the graph library", async ({ page }) => {
  // 122 KB over the wire for a graph that is drawn only on a button press.
  // It used to be a static import, so every page on the site paid for it.
  const asked = [];
  page.on("request", (r) => asked.push(r.url()));

  await page.goto(`/?pkg=${ATTR}`);
  await expect(page.locator(".row.cols-ver").first()).toBeVisible();

  expect(asked.filter((u) => u.includes("cytoscape"))).toEqual([]);
});

test("a package page builds no other view's DOM", async ({ page }) => {
  // The revisions and releases tabs used to render into hidden sections here —
  // 176 rows a package visitor never sees, and most of the page's markup.
  await page.goto(`/?pkg=${ATTR}`);
  await expect(page.locator(".row.cols-ver").first()).toBeVisible();

  expect(await page.locator(".row.cols-rev").count()).toBe(0);
  expect(await page.locator(".row.cols-rel").count()).toBe(0);
  expect(await page.locator(".kpi").count()).toBe(0);
});

test("a visited view keeps its state across a trip to another tab", async ({
  page,
}) => {
  // The reason the fix latches "has been visited" instead of just rendering
  // the active view: paging deeper into the revisions list, looking at
  // something else and coming back must not silently rewind the window.
  await page.goto("/?view=revisions");
  const rows = page.locator(".row.cols-rev");
  const firstWindow = await rows.count();

  await page.locator("button.more", { hasText: "show" }).click();
  const widened = await rows.count();
  expect(widened).toBeGreaterThan(firstWindow);

  await page.locator("nav a", { hasText: "Packages" }).click();
  await page.locator("nav a", { hasText: "Revisions" }).click();

  expect(await rows.count()).toBe(widened);
});

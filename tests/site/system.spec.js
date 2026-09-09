// The store paths a package page shows belong to one system, and the reader
// picks which.
//
// Four claims are worth a browser to check: that the picker offers exactly the
// systems the build published, that switching actually changes the paths, that
// the pick lands in the URL so it can be shared and walked back, and that an
// alternate system costs nothing until it is asked for. A picker wired to a
// stale list, or to nothing at all, looks identical to a correct one from the
// outside.

import { test, expect } from "@playwright/test";

// Long-lived, built for every system, and small enough that its shard loads
// quickly. The same attribute the other package tests drive.
const ATTR = "ripgrep";

// Read from the site rather than hard-coded: the list grows by one with every
// system backfilled. The first entry is the one the site aggregates and the
// one a page shows before anyone picks. See tools/build-site-data.py.
async function publishedSystems(page) {
  const res = await page.request.get("/systems.json");
  expect(res.ok()).toBe(true);
  return res.json();
}

// Every store-path line on the page, not one row's: a system carries digests
// only for the versions it was built for, so no single row has one on all of
// them.
const storePathsOf = (page) =>
  page.locator(".cmd", { hasText: "nix-store --realise" }).allInnerTexts();

// Pick a system by name in the select.
const pick = (page, system) =>
  page.locator(".syspick select").selectOption(system);

test("the picker offers every published system and defaults to the aggregated one", async ({
  page,
}) => {
  const systems = await publishedSystems(page);
  await page.goto(`/?pkg=${ATTR}`);

  const select = page.locator(".syspick select");
  await expect(select).toBeVisible();
  await expect(select.locator("option")).toHaveText(systems);

  // The first system in systems.json is the one every other view is built
  // from, so it is what the page shows before anyone chooses.
  await expect(select).toHaveValue(systems[0]);
});

test("the default page reads the aggregated system's directories", async ({
  page,
}) => {
  // The page cannot wait for systems.json to name its shards, so the build
  // substitutes the system into data.js. Nothing inside the page can notice
  // that going stale: a directory the build never wrote 404s, and a 404 shard
  // reads as "no attribute here" — every version renders with no store path
  // and no error. So check the name the page actually asks for against the
  // name the build published.
  const [primary] = await publishedSystems(page);

  const asked = [];
  await page.route("**/meta-*/**", (route) => {
    asked.push(new URL(route.request().url()).pathname.split("/")[1]);
    return route.continue();
  });

  await page.goto(`/?pkg=${ATTR}`);
  const first = page.locator(".row.cols-ver").first();
  await expect(first).toBeVisible();
  await first.click();
  await expect(
    page.locator(".cmd", { hasText: "nix-store --realise" }).first(),
  ).toBeVisible();

  expect([...new Set(asked)]).toEqual([`meta-${primary}`]);
});

test("an alternate system's shards are not fetched until it is picked", async ({
  page,
}) => {
  const [primary, alt] = await publishedSystems(page);
  test.skip(!alt, "only one system is published");

  const asked = new Set();
  for (const dir of ["meta", "revdeps"]) {
    await page.route(`**/${dir}-${alt}/**`, (route) => {
      asked.add(new URL(route.request().url()).pathname.split("/")[1]);
      return route.continue();
    });
  }

  await page.goto(`/?pkg=${ATTR}`);
  const first = page.locator(".row.cols-ver").first();
  await expect(first).toBeVisible();

  // Expanded, so the default system's store data has demonstrably landed: if
  // the page fetched every system it would have fetched them together, and
  // this is the moment that would show.
  await first.click();
  await expect(
    page.locator(".cmd", { hasText: "nix-store --realise" }).first(),
  ).toBeVisible();
  expect([...asked]).toEqual([]);
  expect(primary).not.toBe(alt);

  // Picking it fetches both of that system's directories, and only then.
  await pick(page, alt);
  await expect
    .poll(() => [...asked].sort(), {
      message: "picking a system fetches its shards",
    })
    .toEqual([`meta-${alt}`, `revdeps-${alt}`]);
});

test("switching to any system changes the store paths", async ({ page }) => {
  const systems = await publishedSystems(page);
  test.skip(systems.length < 2, "only one system is published");

  await page.goto(`/?pkg=${ATTR}`);
  await expect(page.locator(".row.cols-ver").first()).toBeVisible();

  // Every version at once: darwin's coverage starts where the channel started
  // building it, so a test pinned to one row fails the day that row is a miss.
  await page.locator("button.bulk").click();

  // Every system, not just the first alternate: a picker can be wired for two
  // and hand the third whatever the second left behind.
  const seen = new Map();
  for (const system of systems) {
    await pick(page, system);
    await expect
      .poll(() => storePathsOf(page).then((p) => p.length), {
        message: `${system} shows store paths`,
      })
      .toBeGreaterThan(0);

    const paths = await storePathsOf(page);
    for (const [other, otherPaths] of seen) {
      expect(
        paths.join("\n"),
        `${system} and ${other} show the same store paths`,
      ).not.toBe(otherPaths.join("\n"));
    }
    seen.set(system, paths);

    await expect(
      page.locator(".capt", { hasText: `the ${system} build` }).first(),
    ).toBeVisible();
  }
});

test("no caption on the page names a system other than the picked one", async ({
  page,
}) => {
  // The bug this catches: captions that interpolate the system and captions
  // that hardcode it look identical until you switch, and only some rows carry
  // the ones that would show it — a version missing on aarch64 said so in a
  // sentence that named x86_64-linux for a week.
  const systems = await publishedSystems(page);
  test.skip(systems.length < 2, "only one system is published");

  await page.goto(`/?pkg=${ATTR}`);
  await expect(page.locator(".row.cols-ver").first()).toBeVisible();

  for (const picked of systems.slice(1)) {
    await pick(page, picked);
    await page.locator("button.bulk").click();

    // Every caption at once, so a row type that only appears for some
    // versions is still covered.
    const captions = page.locator(".capt");
    await expect.poll(() => captions.count()).toBeGreaterThan(0);
    for (const text of await captions.allInnerTexts()) {
      for (const other of systems) {
        if (other === picked) continue;
        expect(text).not.toContain(other);
      }
    }
    // Collapse again, so the next system starts from the same page state.
    await page.locator("button.bulk").click();
  }
});

test("the picked system is in the URL, shareable and reversible", async ({
  page,
}) => {
  const [primary, alt] = await publishedSystems(page);
  test.skip(!alt, "only one system is published");

  await page.goto(`/?pkg=${ATTR}`);
  await expect(page.locator(".syspick select")).toBeVisible();

  // The default stays out of the URL, so every link that predates the picker
  // is still spelled the way it was.
  expect(new URL(page.url()).searchParams.get("sys")).toBe(null);

  await pick(page, alt);
  await expect
    .poll(() => new URL(page.url()).searchParams.get("sys"))
    .toBe(alt);

  // Replace, not push: switching refines this page, so Back leaves the
  // package rather than undoing one toggle at a time.
  await page.goBack();
  expect(new URL(page.url()).searchParams.get("pkg")).not.toBe(ATTR);

  // A pasted link opens on that system, which is the whole point of putting
  // it in the URL.
  await page.goto(`/?pkg=${ATTR}&sys=${alt}`);
  await expect(page.locator(".syspick select")).toHaveValue(alt);

  // Picking the default again clears it rather than spelling it out.
  await pick(page, primary);
  await expect
    .poll(() => new URL(page.url()).searchParams.get("sys"))
    .toBe(null);
});

test("a sys the build does not publish falls back to the default", async ({
  page,
}) => {
  // A hand-edited URL, or a link from a build that published more systems than
  // this one. The failure it prevents is a page quietly fetching meta-<junk>/
  // and rendering every version as having no store path.
  const [primary] = await publishedSystems(page);

  await page.goto(`/?pkg=${ATTR}&sys=sparc64-tru64`);
  await expect(page.locator(".syspick select")).toHaveValue(primary);

  const first = page.locator(".row.cols-ver").first();
  await expect(first).toBeVisible();
  await first.click();
  await expect(
    page.locator(".cmd", { hasText: "nix-store --realise" }).first(),
  ).toBeVisible();
});

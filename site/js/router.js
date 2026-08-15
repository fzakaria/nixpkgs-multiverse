// The URL-state layer, promoted to the site's router. The query string is
// parsed into a route object, a route serializes back to a minimal URL, and
// the useRouter hook owns navigation (push/replace), popstate wiring, and
// the <head> rewrite that describes every route to crawlers and share cards.
// Views receive `route` and `navigate` from App and link around with Link.

import { html, useState, useEffect } from "htm/preact";

import { VIEWS } from "./config.js";

// Whether a navigation adds a history entry (clicks) or amends the current
// one (typing, opening a row) — so Back walks views, not keystrokes.
export const Nav = { PUSH: "push", REPLACE: "replace" };

/* ---------- URL state ----------
 *
 * The query string is the single source of truth for what the page shows,
 * so every view is a shareable link:
 *   ?pkg=ripgrep                  a package's version table
 *   ?pkg=ripgrep&ver=14.1.0       …with one version row open
 *   ?q=python                     a search
 *   ?view=revisions&rev=<sha>     the revisions tab with one revision open
 *   ?view=releases&release=26.05  the releases tab with one release open
 */

// Every query parameter a route can carry beyond `view`. A route object
// always holds all of them, so a partial patch merges cleanly and a link
// target can be spelled out in full.
const ROUTE_PARAMS = ["q", "pkg", "ver", "rev", "release"];

function readRoute() {
  const p = new URLSearchParams(location.search);
  const view = VIEWS.includes(p.get("view")) ? p.get("view") : "packages";
  const route = { view };
  for (const k of ROUTE_PARAMS) {
    route[k] = p.get(k) || "";
  }
  return route;
}

// Serialize only what the active view needs, so URLs stay minimal and the
// bare page URL means "packages tab, empty search".
function routeToQuery(route) {
  const p = new URLSearchParams();
  if (route.view !== "packages") p.set("view", route.view);
  if (route.view === "packages" && route.pkg) {
    p.set("pkg", route.pkg);
    if (route.ver) p.set("ver", route.ver);
  } else if (route.view === "packages" && route.q) p.set("q", route.q);
  if (route.view === "revisions" && route.rev) p.set("rev", route.rev);
  if (route.view === "releases" && route.release)
    p.set("release", route.release);
  return p.toString();
}

const routeToHref = (route) => {
  const qs = routeToQuery(route);
  return location.pathname + (qs ? `?${qs}` : "");
};

/* ---------- what the page says it is ----------
 *
 * Every view is one query string over one HTML file, so a crawler that stops
 * at the markup sees the same document 30,000 times. index.html ships the
 * homepage's title, description and canonical URL; describeRoute supplies
 * them for everything else, and the effect in useRouter rewrites the head on
 * every navigation. Without that rewrite each package URL keeps index.html's
 * canonical and declares itself a duplicate of the homepage.
 */

const SITE_NAME = "nixpkgs-multiverse";
const SITE_ORIGIN = "https://nixmultiverse.com";

// Whether a route belongs in a search index. ?q= accepts anything, so search
// results are an unbounded crawl space that Google asks sites to keep out of
// the index; the results themselves are still followed for discovery.
const Robots = { INDEX: "index,follow", NOINDEX: "noindex,follow" };

// Whether a <meta> keys off name= (the standard tags) or property= (Open
// Graph, which uses a different attribute for the same job).
const MetaAttr = { NAME: "name", PROPERTY: "property" };

// The homepage's own copy, read out of the tags index.html serves rather than
// spelled out a second time here. Navigating from a package back to the bare
// page restores exactly what was shipped.
const homeHead = {
  title: document.title,
  description: headMeta(MetaAttr.NAME, "description").content,
  ogTitle: headMeta(MetaAttr.PROPERTY, "og:title").content,
  ogDescription: headMeta(MetaAttr.PROPERTY, "og:description").content,
};

// The subject is what the title leads with, ahead of the site name: a search
// result is scanned left to right, and "nixpkgs-multiverse — " in front of
// every one of 30,000 package titles is 21 characters of nothing.
function describeRoute(route) {
  const { view, pkg, ver, q, rev, release } = route;

  if (view === "packages" && pkg && ver) {
    return {
      subject: `${pkg} ${ver}`,
      description:
        `Every nixpkgs revision that shipped ${pkg} ${ver}, with the exact ` +
        `nix run and flake pin commands for that version.`,
      robots: Robots.INDEX,
    };
  }

  if (view === "packages" && pkg) {
    return {
      subject: pkg,
      description:
        `Every version of ${pkg} ever packaged in nixpkgs, across 13 years ` +
        `of revisions, each with the exact nix run and flake pin command.`,
      robots: Robots.INDEX,
    };
  }

  if (view === "packages" && q) {
    return {
      subject: `search “${q}”`,
      description: `nixpkgs packages matching “${q}”, across 300,000+ package versions.`,
      robots: Robots.NOINDEX,
    };
  }

  if (view === "revisions" && rev) {
    return {
      subject: `revision ${rev}`,
      description:
        `The nixpkgs revision ${rev}: its date, its channel build, and every ` +
        `package version pinned at it.`,
      robots: Robots.INDEX,
    };
  }

  if (view === "revisions") {
    return {
      subject: view,
      description:
        "Every nixos-unstable channel revision indexed by nixpkgs-multiverse, " +
        "with its date, what it added and removed, and what it pinned.",
      robots: Robots.INDEX,
    };
  }

  if (view === "releases" && release) {
    return {
      subject: release,
      description:
        `The nixpkgs ${release} release channel: the tip commit it currently ` +
        `points at, its date and its channel build.`,
      robots: Robots.INDEX,
    };
  }

  if (view === "releases") {
    return {
      subject: view,
      description:
        "Every nixpkgs release channel, from 13.10 to today, with the " +
        "revision each one currently points at.",
      robots: Robots.INDEX,
    };
  }

  if (view === "stats") {
    return {
      subject: view,
      description:
        "Statistics over 13 years of nixpkgs: how many packages, how many " +
        "versions of each, and how fast they turn over.",
      robots: Robots.INDEX,
    };
  }

  // The bare page: the packages tab with an empty search, which is the
  // homepage index.html already describes.
  return {
    subject: null,
    description: homeHead.description,
    robots: Robots.INDEX,
  };
}

// The <head> tag carrying one piece of that description, created on first use
// if index.html does not already ship it.
function headMeta(attr, key) {
  let el = document.head.querySelector(`meta[${attr}="${key}"]`);
  if (!el) {
    el = document.createElement("meta");
    el.setAttribute(attr, key);
    document.head.append(el);
  }
  return el;
}

function headCanonical() {
  let el = document.head.querySelector('link[rel="canonical"]');
  if (!el) {
    el = document.createElement("link");
    el.rel = "canonical";
    document.head.append(el);
  }
  return el;
}

// An internal link: a real href for copy-link / middle-click, an in-page
// navigation for a plain click.
export function Link({ to, navigate, children, ...rest }) {
  // `to` is a partial route, and `navigate` merges a patch onto the CURRENT
  // route — so navigating with the patch alone keeps whatever view the link
  // was clicked from. A package link inside the revisions tab then set `pkg`
  // and stayed on revisions, where routeToQuery drops `pkg` again, so the
  // click did nothing while the href beside it pointed at the package page.
  // Navigate to the same fully-resolved target the href names.
  const target = {
    view: "packages",
    q: "",
    pkg: "",
    ver: "",
    rev: "",
    release: "",
    ...to,
  };
  const onClick = (e) => {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)
      return;
    e.preventDefault();
    navigate(target);
  };
  return html`<a href=${routeToHref(target)} onClick=${onClick} ...${rest}
    >${children}</a
  >`;
}

// The route state App mounts once: the current route, and the navigate
// function every view receives. Owns the history writes, the popstate
// listener, and the head rewrite, so a view never touches the URL directly.
export function useRouter() {
  const [route, setRoute] = useState(readRoute);

  // Navigation writes the URL first, then re-renders from the same route, so
  // the address bar always matches the page. Re-navigating to the current
  // URL amends instead of stacking duplicate history entries.
  const navigate = (patch, mode = Nav.PUSH) => {
    const next = { ...route, ...patch };
    const href = routeToHref(next);
    // Safari rate-limits history writes; if one is refused the URL merely
    // lags a keystroke behind while the page itself stays correct.
    try {
      if (mode === Nav.PUSH && href !== location.pathname + location.search)
        history.pushState(null, "", href);
      else history.replaceState(null, "", href);
    } catch {
      /* throttled — ignore */
    }
    // A push is a move to a different page, so it starts at the top. Without
    // this the browser keeps the old offset: clicking a package from a
    // scrolled revisions list lands you part-way down its version table.
    // Replaces (opening a row, clicking a bar) deliberately keep their place,
    // and a row that scrolls itself into view does so in a later effect.
    if (mode === Nav.PUSH) scrollTo(0, 0);
    setRoute(next);
  };

  // Back/forward restore whatever route the URL then holds.
  useEffect(() => {
    const onPop = () => setRoute(readRoute());
    addEventListener("popstate", onPop);
    return () => removeEventListener("popstate", onPop);
  }, []);

  // Name the shared thing in the tab title, so pasted links read as what they
  // are — and tell a crawler the same thing, since the query string is the
  // only difference between this page and every other one served out of the
  // same index.html.
  useEffect(() => {
    const { subject, description, robots } = describeRoute(route);

    document.title = subject ? `${subject} — ${SITE_NAME}` : homeHead.title;
    headMeta(MetaAttr.NAME, "description").content = description;

    // The canonical URL is the whole point of the rewrite: index.html's is
    // hardcoded to the homepage, so without this every route consolidates
    // into "/" and only the homepage is ever indexed.
    const canonical = SITE_ORIGIN + routeToHref(route);
    headCanonical().href = canonical;

    // The share card follows the same route, so a pasted package link
    // previews as that package rather than as the front page. The bare page
    // restores index.html's wording, which is written for a share and says
    // more than the tab title does.
    const share = subject
      ? { title: document.title, description }
      : { title: homeHead.ogTitle, description: homeHead.ogDescription };
    headMeta(MetaAttr.PROPERTY, "og:url").content = canonical;
    headMeta(MetaAttr.PROPERTY, "og:title").content = share.title;
    headMeta(MetaAttr.PROPERTY, "og:description").content = share.description;

    // No robots tag at all is the same as index,follow, and the absent tag is
    // the cleaner statement of it.
    if (robots === Robots.NOINDEX) {
      headMeta(MetaAttr.NAME, "robots").content = robots;
      return;
    }
    document.head.querySelector('meta[name="robots"]')?.remove();
  }, [route]);

  return [route, navigate];
}

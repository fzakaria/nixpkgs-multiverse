#!/usr/bin/env python3
"""Render docs/*.md into the static HTML the site serves under /docs/.

The same markdown is read by GitHub and by this script, so every transform
here exists to make one source work in both places: heading anchors use
GitHub's slug algorithm, and `./page.md` links become `./page.html` on the
way out.

Usage: render-docs.py <cmark-gfm> <docs-dir> <out-dir> [origin] [store-path]
"""

import html
import os
import re
import shutil
import subprocess
import sys

from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

# The extensions GitHub itself renders with. `tagfilter` is deliberately left
# off: it strips raw <script>/<style> as a defence against untrusted markdown,
# and everything here is ours.
EXTENSIONS = ["table", "strikethrough", "autolink", "tasklist", "footnotes"]

SITE_TITLE = "nixpkgs-multiverse"
REPO = "https://github.com/fzakaria/nixpkgs-multiverse"
GA_ID = "G-JHW37D1S4W"

# The favicon and analytics that index.html carries, so a docs page and the
# index look like one site in the browser tab and in reporting.
FAVICON = (
    "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' "
    "viewBox='0 0 100 100'><text y='.9em' font-size='90'>🌌</text></svg>"
)


def slug(text):
    """GitHub's heading-anchor algorithm: lowercase, drop punctuation, join on
    hyphens. Kept identical to the checker in ci so a link that resolves on
    GitHub resolves on the site."""
    text = text.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text)


def strip_tags(fragment):
    """The visible text of a heading — `<code>mvs</code>` slugs as `mvs`."""
    return html.unescape(re.sub(r"<[^>]+>", "", fragment))


def render_markdown(cmark, path):
    cmd = [cmark, "--unsafe"]
    for ext in EXTENSIONS:
        cmd += ["--extension", ext]
    return subprocess.run(
        cmd + [path], check=True, capture_output=True, text=True
    ).stdout


def add_anchors(body):
    """Give every h2/h3 an id and collect the h2s for the sidebar.

    Duplicate slugs get a numeric suffix, matching how GitHub disambiguates
    two headings with the same text in one document.
    """
    seen = {}
    toc = []

    def replace(match):
        level, inner = match.group(1), match.group(2)
        base = slug(strip_tags(inner))
        n = seen.get(base, 0)
        seen[base] = n + 1
        anchor = base if n == 0 else f"{base}-{n}"
        if level == "2":
            toc.append((anchor, strip_tags(inner)))
        # The heading links to itself, so a reader can copy a deep link
        # without reading the source.
        return (
            f'<h{level} id="{anchor}">'
            f'<a class="anchor" href="#{anchor}">{inner}</a></h{level}>'
        )

    body = re.sub(r"<h([23])>(.*?)</h\1>", replace, body, flags=re.S)
    return body, toc


# `nowrap` because the <pre><code> around the block is already there and
# already styled; Pygments only supplies the spans inside it.
FORMATTER = HtmlFormatter(nowrap=True)

# cmark-gfm renders a fenced block with an info string as
# `<pre><code class="language-nix">`. Its contents are HTML-escaped, so the
# closing tag is unambiguous.
CODE_BLOCK = re.compile(r'<pre><code class="language-([^"]+)">(.*?)</code></pre>', re.S)


# The prompts these docs actually use, and what follows each one.
#
# Pygments' own `console` lexer gets two of the three wrong. `#` is the
# conventional root prompt, so it reads a comment line as a prompt plus a
# command and lexes the prose as shell words; and it has never heard of
# `nix-repl>`, so every REPL line falls through to undifferentiated output.
# Lexing the REPL lines as Nix is the bigger win — they are Nix expressions,
# and there are more of them than there are shell commands.
CONSOLE_PROMPTS = [
    (re.compile(r"^(\s*\$ )(.*)$"), "bash"),
    (re.compile(r"^(\s*nix-repl> )(.*)$"), "nix"),
]
CONSOLE_COMMENT = re.compile(r"^\s*#")

# Languages whose lexer paints shell builtins, and where that is misleading
# here: almost every command in these docs is `nix <subcommand>`, and several
# of those subcommands share a name with a bash builtin — `nix eval`, `nix
# hash`, `nix run -- test`. The lexer sees `eval` and colours it as the shell's
# own, which tells the reader something untrue about the word.
SHELL_LANGS = {"console", "sh", "bash", "shell"}
BUILTIN_SPAN = re.compile(r'<span class="nb">(.*?)</span>', re.S)


def drop_builtins(marked):
    """Strip builtin colouring from shell-lexed HTML, leaving the text.

    In a shell session the first word is the command and the rest are its
    arguments; whether the command happens to be a shell builtin is not a
    distinction worth painting.
    """
    return BUILTIN_SPAN.sub(r"\1", marked)


def highlight_console(code):
    """Highlight a shell session line by line.

    A session is not one language: it interleaves prompts, commands in two
    different languages, editorial comments, and program output. Only the
    command parts go through a lexer.
    """
    out = []
    # The lexer a trailing backslash carried onto the next line, if any, and
    # whether that lexer is a shell one.
    continuation = None
    continuation_is_shell = False

    for line in code.split("\n"):
        if not line.strip():
            out.append(line)
            continue

        if continuation is not None:
            marked = highlight(line, continuation, FORMATTER).rstrip("\n")
            out.append(drop_builtins(marked) if continuation_is_shell else marked)
            if not line.rstrip().endswith("\\"):
                continuation = None
            continue

        for pattern, lang in CONSOLE_PROMPTS:
            match = pattern.match(line)
            if not match:
                continue
            prompt, command = match.group(1), match.group(2)
            lexer = get_lexer_by_name(lang)
            marked = highlight(command, lexer, FORMATTER).rstrip("\n")
            # Only the shell half needs it — a `nix-repl>` line is Nix, where
            # `builtins` really is a builtin and should say so.
            is_shell = lang in SHELL_LANGS
            if is_shell:
                marked = drop_builtins(marked)
            out.append(f'<span class="gp">{html.escape(prompt)}</span>{marked}')
            if command.rstrip().endswith("\\"):
                continuation = lexer
                continuation_is_shell = is_shell
            break
        else:
            cls = "c1" if CONSOLE_COMMENT.match(line) else "go"
            out.append(f'<span class="{cls}">{html.escape(line)}</span>')

    return "\n".join(out)


def highlight_code(body):
    """Colour fenced blocks at build time.

    Doing it here rather than with a highlighter in the browser keeps the docs
    pages free of runtime JavaScript and of a CDN dependency, and means the
    markup a crawler sees is the markup a reader sees. `console` is the lexer
    that earns the most: it separates the prompt and the command from the
    output, which is what most of these blocks are.
    """

    def replace(match):
        lang, escaped = match.group(1), match.group(2)
        code = html.unescape(escaped)

        if lang == "console":
            marked = highlight_console(code)
            return (
                f'<pre><code class="language-console highlight">'
                f"{marked}</code></pre>"
            )

        try:
            lexer = get_lexer_by_name(lang)
        except ClassNotFound:
            # An unknown info string is not worth failing a build over; the
            # block still renders, just without colour.
            return match.group(0)
        marked = highlight(code, lexer, FORMATTER)
        if lang in SHELL_LANGS:
            marked = drop_builtins(marked)
        return f'<pre><code class="language-{lang} highlight">' f"{marked}</code></pre>"

    return CODE_BLOCK.sub(replace, body)


def rewrite_links(body):
    """Point the markdown's own links at their rendered equivalents.

    Two kinds need moving. A `./cli.md` link drops its extension, because the
    published URL is `/docs/cli`. And a link to something else in the
    repository — a workflow file, say — has no rendered counterpart at all, so
    it goes to GitHub rather than 404ing under /docs/.

    Every docs page lives directly in /docs/ and every URL resolves with that
    as its base, so these stay relative and need no notion of depth.
    """

    def replace(match):
        href = match.group(1)

        # Absolute URLs and bare anchors are already right.
        if re.match(r"[a-z]+:", href) or href.startswith("#"):
            return match.group(0)

        target, hash_, anchor = href.partition("#")

        # A sibling docs page: ./cli.md#x -> ./cli#x
        sibling = re.fullmatch(r"\./([A-Za-z0-9._-]+)\.md", target)
        if sibling:
            return f'href="./{sibling.group(1)}{hash_}{anchor}"'

        # Anything else relative points into the repository, not the site.
        repo_path = os.path.normpath(os.path.join("docs", target))
        return f'href="{REPO}/blob/main/{repo_path}{hash_}{anchor}"'

    return re.sub(r'href="([^"]+)"', replace, body)


def page_order(docs_dir):
    """The sidebar order, read from the ordered list in index.md — one source
    of truth that stays readable on GitHub."""
    with open(os.path.join(docs_dir, "index.md")) as fh:
        text = fh.read()
    order, seen = [], set()
    for name in re.findall(r"\]\(\./([A-Za-z0-9._-]+)\.md[^)]*\)", text):
        if name not in seen:
            seen.add(name)
            order.append(name)
    return order


def title_of(body, fallback):
    match = re.search(r"<h1>(.*?)</h1>", body, flags=re.S)
    return strip_tags(match.group(1)) if match else fallback


def sidebar(pages, current):
    """Every page, with the current page's own h2 headings nested underneath."""
    out = ['<nav class="doc-nav" aria-label="Documentation">', "<ul>"]
    for name, title, toc in pages:
        active = ' class="active"' if name == current else ""
        href = "./" if name == "index" else f"./{name}"
        out.append(f'<li><a{active} href="{href}">{html.escape(title)}</a>')
        if name == current and toc:
            out.append("<ul>")
            for anchor, text in toc:
                out.append(f'<li><a href="#{anchor}">{html.escape(text)}</a></li>')
            out.append("</ul>")
        out.append("</li>")
    out += ["</ul>", "</nav>"]
    return "\n".join(out)


def provenance(store_path):
    """The footer line naming the store path the pages are served from.

    The index browser writes the same line from app.js, which cannot help
    here — a docs page runs no JavaScript — so the path is stamped in as a
    placeholder the site derivation substitutes.
    """
    if not store_path:
        return ""
    return f'\n      <div id="store"><code>{html.escape(store_path)}</code></div>'


def url_of(name):
    """A page's URL path, without the `.html` a reader would have to type.

    The file on disk is still `<name>.html`; GitHub Pages resolves an
    extensionless request onto it, and `nix run .#serve` does the same so a
    local preview and the deploy agree. Because the URL has no trailing
    slash, its base directory is /docs/ either way, which is why every
    relative path on the page works unchanged.
    """
    return "/docs/" if name == "index" else f"/docs/{name}"


def canonical(origin, name):
    """A page is reachable both with and without its `index.html`, and the
    sitemap offers the shorter form. Naming the canonical one keeps a crawler
    from treating them as duplicates. Skipped when no origin is known, which
    is a local render rather than the deploy."""
    if not origin:
        return ""
    return f'\n    <link rel="canonical" href="{origin}{url_of(name)}" />'


def shell(title, body, nav, name, store_path, origin):
    """The page frame: the site's own header and footer, so /docs/ reads as
    part of nixmultiverse.com rather than as a separate manual."""
    edit = f"{REPO}/blob/main/docs/{name}.md"
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{html.escape(title)} · {SITE_TITLE}</title>{canonical(origin, name)}
    <link rel="icon" href="{FAVICON}" />
    <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)" />
    <meta name="theme-color" content="#16181d" media="(prefers-color-scheme: dark)" />
    <link rel="stylesheet" href="../style.css" />
    <link rel="stylesheet" href="../docs.css" />

    <!-- Google tag (gtag.js) -->
    <script async src="https://www.googletagmanager.com/gtag/js?id={GA_ID}"></script>
    <script>
      window.dataLayer = window.dataLayer || [];
      function gtag() {{
        dataLayer.push(arguments);
      }}
      gtag("js", new Date());
      gtag("config", "{GA_ID}");
    </script>
  </head>
  <body>
    <header class="site">
      <h1><a href="../">{SITE_TITLE}</a></h1>
      <nav class="site">
        <a href="../">Index</a>
        <a class="active" href="./">Documentation</a>
        <a href="https://fzakaria.github.io/grail/" title="grail: solve version-range queries over this index">Version ranges</a>
        <a href="{REPO}">GitHub</a>
      </nav>
    </header>

    <div class="doc-layout">
      {nav}
      <main class="doc-body">
{body}
        <p class="doc-edit">
          <a href="{edit}">Edit this page on GitHub</a>
        </p>
      </main>
    </div>

    <footer class="muted">
      Made with ❤️ by
      <a href="https://fzakaria.com">Farid Zakaria</a>
      ·
      <a href="{REPO}/blob/main/LICENSE">MIT</a>{provenance(store_path)}
    </footer>
  </body>
</html>
"""


def main():
    cmark, docs_dir, out_dir = sys.argv[1:4]
    # Rendering outside the site derivation — a local preview — knows neither
    # of these. An empty origin keeps the canonical link off the page; the
    # store-path placeholder is substituted by the site derivation.
    origin = sys.argv[4] if len(sys.argv) > 4 else ""
    store_path = sys.argv[5] if len(sys.argv) > 5 else "__STORE_PATH__"
    os.makedirs(out_dir, exist_ok=True)

    order = page_order(docs_dir)
    names = ["index"] + [n for n in order if n != "index"]

    # Render every page first: the sidebar needs each page's title, and the
    # active page's h2 list, before any page can be written.
    rendered = {}
    for name in names:
        source = os.path.join(docs_dir, f"{name}.md")
        if not os.path.exists(source):
            sys.exit(f"render-docs: {source} is listed in index.md but missing")
        body = rewrite_links(render_markdown(cmark, source))
        body, toc = add_anchors(body)
        body = highlight_code(body)
        rendered[name] = (body, toc, title_of(body, name))

    # Any page on disk that index.md never lists would silently never be
    # published; that is a mistake worth failing the build over.
    on_disk = {f[:-3] for f in os.listdir(docs_dir) if f.endswith(".md")}
    missing = on_disk - set(names)
    if missing:
        sys.exit("render-docs: not listed in index.md: " + ", ".join(sorted(missing)))

    pages = [(n, rendered[n][2], rendered[n][1]) for n in names]
    for name in names:
        body, _, title = rendered[name]
        page = shell(title, body, sidebar(pages, name), name, store_path, origin)
        # Flat `<name>.html` on disk, served at `/docs/<name>`. Both GitHub
        # Pages and `nix run .#serve` resolve the extensionless request onto
        # this file, so the URL a reader copies never carries `.html`.
        with open(os.path.join(out_dir, f"{name}.html"), "w") as fh:
            fh.write(page)

    # Anything beside the markdown — the diagrams a page links to as
    # `./name.svg` — goes across untouched. GitHub reads those links straight
    # out of the repository, so the site has to serve them under the same
    # names for one link to work in both readers.
    assets = [f for f in sorted(os.listdir(docs_dir)) if not f.endswith(".md")]
    for asset in assets:
        shutil.copyfile(os.path.join(docs_dir, asset), os.path.join(out_dir, asset))

    print(f"rendered {len(names)} docs pages, copied {len(assets)} assets")


if __name__ == "__main__":
    main()

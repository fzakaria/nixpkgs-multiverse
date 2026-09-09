# The system the site aggregates.
#
# Every store path belongs to one system, so the reverse-dependency counts, the
# census and the universe map all describe this one, and the page shows its
# store paths until a reader picks another. Three places have to agree on the
# name: tools/build-site-data.py takes it as an argument and writes it first in
# systems.json, site.nix substitutes it into site/js/data.js so a page can name
# its shards before it has fetched anything, and store-data.nix hands it to
# both. This is the statement they take it from.
{
  siteSystem = "x86_64-linux";
}

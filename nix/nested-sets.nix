# Package sets whose direct children are indexed alongside the top-level
# attributes, reached in the index as `<set>.<child>` — `jetbrains.idea`.
#
# An allow-list rather than a size cap or a deny-list, for three reasons.
# Nixpkgs adds package sets on its own schedule, and a deny-list would admit
# the next 19,000-attribute one the morning it lands, without anyone deciding
# to. A rule keyed on how big a set is *today* makes membership change as a set
# grows, and a set that crosses the line mid-history reads downstream as a
# package that was removed — `mvs query last-seen` and the site's timeline both
# believe it. And the same packages live under several names —
# `perlPackages`/`perl5Packages`, four spellings of `rubyPackages` — which only
# a list has an opinion about.
#
# Entries are effectively permanent. Once `jetbrains.idea` has a version
# history, dropping the set makes it look like the package left nixpkgs, so a
# name goes in only when it earns the space. See
# docs/building-the-index.md#indexing-a-nested-package-set for what earning it
# means and what adding one costs.
#
# One level deep: children of these sets are indexed, grandchildren are not.
[
  # 29 children, 27 of them IDEs with a `meta.mainProgram`, and only two share
  # a name with a top-level attribute. The set people ask for by name.
  "jetbrains"
]

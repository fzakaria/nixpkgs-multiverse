#!/usr/bin/env bash
# Refreshes revisions.json with nixos-unstable channel bumps.
#
# Source is the `nix-releases` S3 bucket, which archives every unstable channel
# ever published. That is the right list rather than "every commit on master":
# a directory appears there only once the channel actually advanced, meaning
# Hydra built it and its store paths are on cache.nixos.org. Commits that never
# became a channel were never fully built, so they were never substitutable.
#
# The git revision is embedded in the directory name
# (nixos-26.11pre1049422.f13ff45afd1b), so the whole list costs a few paginated
# listings rather than one fetch per channel.
#
# A short revision is expanded to a full commit and a date through the local
# nixpkgs clone when there is one, and through the GitHub API when there is not.
# The API path is what lets this run on CI, where a 5 GB clone is not worth its
# minutes; only genuinely new channels are ever looked up, because everything
# already in revisions.json is matched by short-hash prefix first.
#
# Existing entries keep their offset — only new revisions are appended, and the
# file is re-sorted by date. Reordering would invalidate index/versions.json,
# which stores offsets into this array, so it is refused rather than performed.
set -euo pipefail

# revisions.json must stay writable in the caller's checkout, which under
# `nix run` is not where this script lives; the flake wrapper passes that
# directory down as MULTIVERSE_ROOT.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Optional. Point NIXPKGS at a clone to resolve new revisions locally; with no
# clone they are resolved through the GitHub API instead.
NIXPKGS="${NIXPKGS:-}"
# A floor on the channel dates considered, for a run that only wants recent
# history. The default takes everything the archive has.
MIN_YEAR=0
# Adding a channel older than one already on file renumbers every offset after
# it, which invalidates every index. Refused unless asked for; see the guard at
# the bottom.
ALLOW_REORDER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-reorder) ALLOW_REORDER=1; shift ;;
    *) MIN_YEAR="$1"; shift ;;
  esac
done

python3 - "$NIXPKGS" "$MIN_YEAR" "$MT/revisions.json" "$ALLOW_REORDER" <<'PY'
import json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

nixpkgs, min_year, revfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
allow_reorder = sys.argv[4] == '1'
BASE = 'https://nix-releases.s3.amazonaws.com/'
API = 'https://api.github.com/repos/NixOS/nixpkgs/commits/'

# A ceiling on GitHub API lookups per run. Only channels this file has never
# seen reach the API, so a healthy run spends one or two; a much larger number
# means the prefix match is broken and the run should stop rather than spend an
# hour's rate limit finding out.
MAX_API_LOOKUPS = 50

# S3 resets a TLS handshake every so often (ConnectionResetError out of
# do_handshake), which says nothing about the request and is answered by making
# it again. Worth having here even though the listing is a handful of pages,
# because a reset on page three of the walk below loses the whole run.
RETRIES = 3
RETRY_BACKOFF_SECONDS = 0.5

# The clone is optional. Without one — CI, or a fresh checkout — every lookup
# goes through the API instead.
have_clone = bool(nixpkgs) and os.path.isdir(os.path.join(nixpkgs, '.git'))


def get(target):
    """urlopen with retries, returning the body.

    Retries the transport, never a verdict: an HTTP status below 500 is the
    server's considered answer — including the 422 GitHub returns for a short
    hash that is ambiguous across the fork network, which the callers below
    read as "unresolvable" and must keep reading that way.
    """
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(target, timeout=90) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == RETRIES - 1:
                raise
        except Exception:
            if attempt == RETRIES - 1:
                raise
        time.sleep(RETRY_BACKOFF_SECONDS * (attempt + 1))


names, marker = [], ''
while True:
    q = urllib.parse.urlencode({
        'delimiter': '/', 'prefix': 'nixos/unstable/',
        'max-keys': '1000', 'marker': marker,
    })
    # One page is the retried unit, so a failed attempt leaves neither `names`
    # nor `marker` advanced and the walk resumes where it was.
    xml = get(BASE + '?' + q).decode()
    got = re.findall(r'<Prefix>nixos/unstable/([^<]+)/</Prefix>', xml)
    if not got:
        break
    names += got
    if '<IsTruncated>true</IsTruncated>' not in xml:
        break
    marker = 'nixos/unstable/' + got[-1] + '/'

revs = json.load(open(revfile))

# Short hash -> existing entry. The channel name embeds 11 or 12 hex digits, so
# both lengths are indexed and a channel already on file is recognised without
# git or a network round trip. This is what keeps an incremental run cheap.
by_prefix = {}
for r in revs:
    for n in range(7, 13):
        by_prefix[r['rev'][:n]] = r


def full_rev(name):
    """The channel's own git-revision object — the authoritative full commit.

    The archive used 7-character hashes until part-way through the 18.03 cycle,
    and 7 hex characters are ambiguous across ~600k commits: git refuses to
    resolve them and the GitHub API answers 422. This object settles it, and it
    is published for every unstable channel from the 17.03 era onward.
    """
    try:
        with urllib.request.urlopen(BASE + f'nixos/unstable/{name}/git-revision', timeout=90) as r:
            rev = r.read().decode().strip()
    except Exception:
        return None
    return rev if re.fullmatch(r'[0-9a-f]{40}', rev) else None


def resolve_git(ref):
    """Full commit and commit date from the local clone, or None."""
    try:
        full = subprocess.run(
            ['git', '-C', nixpkgs, 'rev-parse', '--verify', f'{ref}^{{commit}}'],
            capture_output=True, text=True, check=True).stdout.strip()
        date = subprocess.run(
            ['git', '-C', nixpkgs, 'log', '-1', '--format=%cs', full],
            capture_output=True, text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        return None
    return full, date


def resolve_api(ref):
    """Same, from the GitHub commits API. GITHUB_TOKEN lifts the rate limit."""
    req = urllib.request.Request(API + ref, headers={
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'nixpkgs-multiverse',
    })
    token = os.environ.get('GITHUB_TOKEN')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            commit = json.load(r)
    except Exception:
        return None
    return commit['sha'], commit['commit']['committer']['date'][:10]


added = unresolved = named = api_calls = 0
original_order = [r['rev'] for r in revs]

# The channel name carries its nixpkgs commit in one of two spellings.
#
# From the 17.03 era on it is the last dot-separated field:
# `nixos-26.11pre1049422.f13ff45afd1b`.
#
# Before that, nixos and nixpkgs were separate repositories and the name
# carried one commit from each: `nixos-13.07pre4909_b32ef4d-2238a23` is the
# nixos commit and then the nixpkgs one. Only the trailing hash names a tree
# worth indexing -- the leading one belongs to the nixos repository, whose
# history was later grafted into nixpkgs, so it resolves against
# NixOS/nixpkgs just as happily and would silently index the wrong tree.
# Requiring the `_<hash>-` prefix is also what keeps the SVN-era names
# (`nixos-0.1pre33981-33982`) from matching a pair of revision numbers.
NEW_FORM = re.compile(r'\.([0-9a-f]{7,12})$')
OLD_FORM = re.compile(r'_[0-9a-f]{7,12}-([0-9a-f]{7,12})$')

for name in names:
    m = NEW_FORM.search(name) or OLD_FORM.search(name)
    if not m:
        continue
    short = m.group(1)

    # Already on file: record which S3 object published it, which is what the
    # README status block links to, and move on.
    known = by_prefix.get(short)
    if known is not None:
        if known.get('name') != name:
            known['name'] = name
            named += 1
        continue

    # Ask the channel what commit it is before trying to expand its short hash,
    # which may not be expandable at all.
    ref = full_rev(name) or short

    if have_clone:
        got = resolve_git(ref)
    elif api_calls < MAX_API_LOOKUPS:
        api_calls += 1
        got = resolve_api(ref)
    else:
        got = None
    if got is None:
        unresolved += 1
        continue

    full, date = got
    if int(date[:4]) < min_year:
        continue
    entry = {"rev": full, "date": date, "name": name}
    revs.append(entry)
    for n in range(7, 13):
        by_prefix[full[:n]] = entry
    added += 1

revs.sort(key=lambda r: (r['date'], r['rev']))

# index/versions.json stores offsets into this array, so an entry that lands
# anywhere other than the end silently repoints every version recorded after it.
# That is a full rebuild, not an append, and it is the caller's decision to make.
reordered = [r['rev'] for r in revs][:len(original_order)] != original_order
if reordered and not allow_reorder:
    sys.exit("revisions.json: a new revision sorted before an existing one; "
             "offsets would shift. Nothing written — rerun with --allow-reorder "
             "to accept a full rebuild.")

json.dump(revs, open(revfile, 'w'), indent=1)
source = 'clone' if have_clone else f'GitHub API ({api_calls} lookups)'
print(f"archived channels: {len(names):,}   added: {added}   "
      f"named: {named}   unresolved: {unresolved}   via: {source}")
print(f"revisions.json now holds {len(revs):,} revisions "
      f"({revs[0]['date']} .. {revs[-1]['date']})")
if reordered:
    # Every offset on file now points at the wrong revision, so say so in the
    # terms the recovery needs rather than reporting a plain append.
    print("OFFSETS SHIFTED: a revision landed before the end of the array.\n"
          "  index/versions.json and index/history.json are now wrong. Rebuild\n"
          "  both from the extraction cache (tools/build-index.sh, then\n"
          "  tools/build-history.sh), then rebuild the store-path artifacts\n"
          "  on the backfill machine (tools/update-outpaths.sh --full --shard).")
elif added:
    print("new revisions appended — run tools/build-index.sh --incremental to index them")
PY

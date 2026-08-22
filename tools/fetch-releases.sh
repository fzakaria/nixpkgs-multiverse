#!/usr/bin/env bash
# Refreshes releases.json with the current tip of every NixOS release channel.
#
# Unlike revisions.json, this file is MUTABLE. A release channel advances as
# backports land on its branch — 26.05 was ten weeks and several hundred
# commits past its release commit within one release cycle — and `at "26.05"`
# is meant to follow it, exactly like github:NixOS/nixpkgs/nixos-26.05 does.
#
# That mutability is why releases live in their own file. index/versions.json
# records each (attr, version) against an OFFSET into revisions.json, so an
# entry there can never change meaning: a backport that bumps a package version
# would silently invalidate every version recorded against that offset. Nothing
# in releases.json is ever indexed, so nothing here can invalidate anything.
#
# Source is the nix-releases bucket the unstable list also comes from:
#
#   nixos/<rel>/                     a release name is a top-level prefix that
#                                    looks like YY.MM, which excludes -small,
#                                    -aarch64, unstable and the virtualbox
#                                    image buckets
#   nixos-<rel>.<build>.<sha>/       a published bump; <build> is the Hydra
#                                    evaluation id and rises monotonically.
#                                    <sha> was 7 characters until 2018
#   nixos-<rel>beta<build>.<sha>/    a bump of the release branch from before
#                                    release day, skipped so that a release
#                                    appears here only once it has shipped
#
# The bump with the highest <build> is the channel tip. That ordering must be
# numeric: as text, nixos-26.05.590 sorts after nixos-26.05.1183.
#
# Every tip carries its narHash, which multiverse.nix checks the fetched tree
# against exactly as it does an indexed revision. A hash costs one tree, so it
# is computed only for a tip that actually moved: an unchanged channel carries
# its recorded hash forward untouched, and the ~20 releases that are past end of
# life never move again. Point NIXPKGS at a clone to pay it with `git archive`
# rather than a download.
set -euo pipefail

# releases.json lives in the caller's checkout, which under `nix run` is not
# where this script lives; the flake wrapper passes it down as MULTIVERSE_ROOT.
MT="${MULTIVERSE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Optional. Expands the 7-character hashes the channels used until 2018 (see
# `expand`), and hashes a moved tip without downloading it (see `narhash`).
NIXPKGS="${NIXPKGS:-}"

python3 - "$MT/releases.json" "$NIXPKGS" <<'PY'
import json, os, re, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

relfile, nixpkgs = sys.argv[1], sys.argv[2]
BASE = 'https://nix-releases.s3.amazonaws.com/'
API = 'https://api.github.com/repos/NixOS/nixpkgs/commits/'

# A release name: exactly YY.MM. The bucket also holds 26.05-small,
# 21.05-aarch64, unstable, unstable-small and two virtualbox image sets.
RELEASE = re.compile(r'^\d\d\.\d\d$')

# The oldest release the archive holds. Everything from here up evaluates on a
# current Nix, now that `overlays` is withheld from the revisions that predate
# it. Earlier names come from the era when NixOS and nixpkgs were separate
# repositories and carry two hashes, neither unambiguously a nixpkgs commit.
OLDEST = '13.10'

# A run makes one listing per release plus one for the bucket root — several
# dozen requests, each paying its own TLS handshake because urlopen keeps no
# connection alive. S3 resets one of those handshakes every so often
# (ConnectionResetError out of do_handshake), which says nothing about the
# request and is answered by making it again.
RETRIES = 3
RETRY_BACKOFF_SECONDS = 0.5


def get(target):
    """urlopen with retries, returning the body.

    Retries the transport, never a verdict: an HTTP status below 500 is the
    server's considered answer — 404, or the 422 GitHub returns for a short
    hash that is ambiguous across the fork network — and asking again only
    spends rate limit to hear it a second time.
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


def prefixes(prefix):
    """Every immediate child 'directory' of an S3 prefix."""
    out, marker = [], ''
    while True:
        q = urllib.parse.urlencode({
            'delimiter': '/', 'prefix': prefix,
            'max-keys': '1000', 'marker': marker,
        })
        # One page is the retried unit, so a failed attempt leaves neither
        # `out` nor `marker` advanced and the walk resumes where it was.
        xml = get(BASE + '?' + q).decode()
        got = re.findall(r'<Prefix>' + re.escape(prefix) + r'([^<]+)/</Prefix>', xml)
        if not got:
            break
        out += got
        if '<IsTruncated>true</IsTruncated>' not in xml:
            break
        marker = prefix + got[-1] + '/'
    return out


def expand(short):
    """Short hash -> (full commit, commit date).

    The clone first, because it is the only thing that can expand the
    7-character hashes the channels used until 2018: GitHub resolves a SHA
    against a repository's entire fork network, where 7 characters collide
    constantly, and answers 422 rather than picking one. Those hashes are
    unambiguous within nixpkgs itself, so a clone settles them.
    """
    if nixpkgs and os.path.isdir(os.path.join(nixpkgs, '.git')):
        try:
            rev = subprocess.run(
                ['git', '-C', nixpkgs, 'rev-parse', '--verify', f'{short}^{{commit}}'],
                capture_output=True, text=True, check=True).stdout.strip()
            # Forced to UTC, because the GitHub path below reports UTC and a
            # commit near midnight otherwise lands on a different day
            # depending on which source answered. %cs would use the timezone
            # the committer recorded.
            date = subprocess.run(
                ['git', '-C', nixpkgs, 'log', '-1',
                 '--format=%cd', '--date=format-local:%Y-%m-%d', rev],
                capture_output=True, text=True, check=True,
                env={**os.environ, 'TZ': 'UTC'}).stdout.strip()
            return rev, date
        except subprocess.CalledProcessError:
            pass

    req = urllib.request.Request(API + short, headers={
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'nixpkgs-multiverse',
    })
    token = os.environ.get('GITHUB_TOKEN')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    commit = json.loads(get(req))
    return commit['sha'], commit['commit']['committer']['date'][:10]


def in_clone(rev):
    return bool(nixpkgs) and subprocess.run(
        ['git', '-C', nixpkgs, 'cat-file', '-e', f'{rev}^{{commit}}'],
        capture_output=True).returncode == 0


def narhash(rev):
    """The narHash builtins.fetchTree will expect for a revision.

    `git archive` when the clone holds the commit, `nix flake prefetch`
    otherwise. The two agree because nixpkgs sets no `export-ignore`
    attributes, so the archive and the GitHub tarball hold identical files —
    the same premise tools/add-narhashes.sh rests on, verified there against
    25.05. Which one runs is only a question of whether a download is needed.

    The archive is streamed into the temp directory rather than buffered: a
    nixpkgs tree is a few hundred megabytes and does not belong in memory.
    """
    if in_clone(rev):
        with tempfile.TemporaryDirectory() as tmp:
            archive = subprocess.Popen(
                ['git', '-C', nixpkgs, 'archive', rev], stdout=subprocess.PIPE)
            subprocess.run(['tar', '-x', '-C', tmp], stdin=archive.stdout, check=True)
            archive.stdout.close()
            if archive.wait() != 0:
                sys.exit(f'releases.json: git archive failed for {rev}')
            return subprocess.run(
                ['nix', 'hash', 'path', '--sri', '--type', 'sha256', tmp],
                capture_output=True, text=True, check=True).stdout.strip()

    out = subprocess.run(
        ['nix', 'flake', 'prefetch', '--json', f'github:NixOS/nixpkgs/{rev}'],
        capture_output=True, text=True, check=True).stdout
    return json.loads(out)['hash']


known = json.load(open(relfile)) if os.path.exists(relfile) else {}
names = sorted(n for n in prefixes('nixos/') if RELEASE.match(n) and n >= OLDEST)

out, moved, held, lookups, hashed = {}, [], 0, 0, 0
for name in names:
    bump = re.compile(rf'^nixos-{re.escape(name)}\.(\d+)\.([0-9a-f]{{7,12}})$')
    published = [
        (int(m.group(1)), m.group(2))
        for d in prefixes(f'nixos/{name}/') if (m := bump.match(d))
    ]
    if not published:
        continue                                  # betas only: not shipped yet

    build, short = max(published)
    prior = known.get(name)

    # <build> is a Hydra evaluation id, so a channel tip only ever moves
    # forward. Backwards means the listing above came back short — a truncated
    # page is a smaller set of bumps, not an error — and recording it would
    # publish an older commit as an advance. Refuse the whole run instead:
    # nothing is written until every release has been listed.
    if prior and prior.get('build') is not None and build < prior['build']:
        sys.exit(f"releases.json: {name} moved backwards, build "
                 f"{prior['build']} -> {build}. The bucket listing was "
                 f"truncated; nothing written.")

    # An unchanged channel costs nothing: the short hash already on file
    # identifies the same commit, so neither the API, a tree, nor a rewrite is
    # needed. A prior without a narHash is not unchanged for this purpose —
    # that is how the field backfills on the first run after it was added.
    if (prior and prior['rev'].startswith(short) and prior.get('build') == build
            and prior.get('narHash')):
        out[name] = prior
        held += 1
        continue

    lookups += 1
    rev, date = expand(short)

    # Reuse a recorded hash when only the field was missing: the commit did not
    # move, so the tree behind it is the one already hashed.
    if prior and prior['rev'] == rev and prior.get('narHash'):
        digest = prior['narHash']
    else:
        hashed += 1
        digest = narhash(rev)

    out[name] = {'rev': rev, 'date': date, 'build': build, 'narHash': digest,
                 'name': f'nixos-{name}.{build}.{short}'}
    if prior and prior['rev'] != rev:
        moved.append(f"{name} {prior['rev'][:12]} -> {rev[:12]} ({prior['date']} -> {date})")

json.dump(out, open(relfile, 'w'), indent=1, sort_keys=True)

print(f"releases: {len(out)} tracked   unchanged: {held}   "
      f"resolved: {lookups} lookup(s)   hashed: {hashed} tree(s)")
for line in moved:
    print(f"  advanced: {line}")
if not moved and lookups:
    print(f"  first run: recorded {lookups} release tips")
PY

#!/usr/bin/env python3
"""Tests the retry in tools/fetch-store-paths.py, with the transport stubbed.

    python3 tests/fetch-retry.py [path/to/fetch-store-paths.py]

What it tests is the policy — what gets asked again and what is raised at once
— rather than the waiting or the network, neither of which a sandboxed build
has. The policy is worth a test because it is written once and only ever
exercised by a network that misbehaves: one unretried handshake timeout used to
discard every listing a backfill had already fetched.
"""
import importlib.util
import io
import os
import sys
import urllib.error

DEFAULT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools", "fetch-store-paths.py"
)


def load(path):
    """fetch-store-paths.py as a module. Its name has a dash, so `import` cannot."""
    spec = importlib.util.spec_from_file_location("fetch_store_paths", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def opener(calls, outcomes):
    """A urlopen that hands back the given outcomes in order, recording calls."""

    def fake(req, timeout=None):
        calls.append(req.full_url)
        outcome = outcomes[len(calls) - 1]
        if isinstance(outcome, Exception):
            raise outcome
        return io.BytesIO(outcome)

    return fake


def http(code):
    return urllib.error.HTTPError("http://example/u", code, "boom", {}, None)


def main():
    fsp = load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SCRIPT)
    fsp.RETRY_BACKOFF_SECONDS = 0

    # The case that cost a backfill its listings: a handshake that times out
    # twice and then succeeds. The bytes come back, on the third attempt.
    calls = []
    fsp.urllib.request.urlopen = opener(
        calls,
        [
            urllib.error.URLError("_ssl.c:1015: The handshake operation timed out"),
            urllib.error.URLError("_ssl.c:1015: The handshake operation timed out"),
            b"payload",
        ],
    )
    assert fsp.get("http://example/u") == b"payload"
    assert len(calls) == 3, calls

    # A 404 is not a failure, it is fetch() being told this bump spells its
    # listing differently — so it has to surface at once rather than after four
    # round trips, or every pre-2017 revision pays for the fallback chain.
    calls = []
    fsp.urllib.request.urlopen = opener(calls, [http(404)] * fsp.FETCH_ATTEMPTS)
    try:
        fsp.get("http://example/u")
        raise SystemExit("a 404 was retried instead of raised")
    except urllib.error.HTTPError as e:
        assert e.code == 404
    assert len(calls) == 1, calls

    # A 5xx is the server rather than the request, and is worth asking again.
    calls = []
    fsp.urllib.request.urlopen = opener(calls, [http(503), b"payload"])
    assert fsp.get("http://example/u") == b"payload"
    assert len(calls) == 2, calls

    # A failure that never clears still fails, after exactly the attempts it is
    # allowed and no more.
    calls = []
    fsp.urllib.request.urlopen = opener(
        calls, [urllib.error.URLError("down")] * fsp.FETCH_ATTEMPTS
    )
    try:
        fsp.get("http://example/u")
        raise SystemExit("a persistent failure was swallowed")
    except urllib.error.URLError:
        pass
    assert len(calls) == fsp.FETCH_ATTEMPTS, calls

    print(f"retry policy holds over {fsp.FETCH_ATTEMPTS} attempts")


if __name__ == "__main__":
    main()

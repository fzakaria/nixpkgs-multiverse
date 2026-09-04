#!/usr/bin/env python3
"""Tests tools/merge-nested-eval.py, the one piece of --topup that decides
what ends up in the file the join reads.

    python3 tests/topup-merge.py [path/to/merge-nested-eval.py]

Its inputs are two small JSON documents, so the whole thing is testable
without evaluating a revision — which is the reason the merge lives in a
script of its own rather than inline in the shell. What it has to get right is
that the expensive half carries across untouched, that the nested half is
replaced rather than appended to, and that a mismatched pair is refused
instead of quietly corrupting the file.
"""
import json
import os
import subprocess
import sys
import tempfile

DEFAULT_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "tools",
    "merge-nested-eval.py",
)

# A full evaluation carrying one stale nested row, as a revision indexed under
# an older package-set list would.
BASE = {
    "rev": "abc",
    "system": "x86_64-linux",
    "attrCount": 3,
    "errorCount": 1,
    "attrs": {
        "hello": {"name": "hello-2.12.2", "outputs": {"out": "aaaa"}},
        "ripgrep": {"name": "ripgrep-14.1.0", "outputs": {"out": "bbbb"}},
        "gone.child": {"name": "gone-1.0", "outputs": {"out": "cccc"}},
    },
}
BASE_ERRORS = {"broken": "error: no", "gone.child2": "error: stale"}

NESTED = {
    "rev": "abc",
    "system": "x86_64-linux",
    "attrCount": 1,
    "errorCount": 1,
    "attrs": {"jetbrains.idea": {"name": "idea-2025.3.1", "outputs": {"out": "dddd"}}},
}
NESTED_ERRORS = {"jetbrains.rider": "error: unfree"}


def write(work, name, obj):
    path = os.path.join(work, name)
    with open(path, "w") as f:
        json.dump(obj, f)
    return path


def merge(script, base, nested, out, **extra):
    """Run the merge, returning whether it accepted the pair."""
    cmd = [sys.executable, script, "--base", base, "--nested", nested, "--out", out]
    for flag, value in extra.items():
        cmd += [f"--{flag.replace('_', '-')}", value]
    return (
        subprocess.run(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode
        == 0
    )


def main():
    script = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SCRIPT

    with tempfile.TemporaryDirectory() as work:
        base = write(work, "base.json", BASE)
        base_errors = write(work, "base.errors.json", BASE_ERRORS)
        nested = write(work, "nested.json", NESTED)
        nested_errors = write(work, "nested.errors.json", NESTED_ERRORS)
        merged_path = os.path.join(work, "merged.json")
        merged_errors_path = os.path.join(work, "merged.errors.json")

        assert merge(
            script,
            base,
            nested,
            merged_path,
            base_errors=base_errors,
            nested_errors=nested_errors,
            out_errors=merged_errors_path,
        ), "the merge refused a pair it should accept"

        m = json.load(open(merged_path))
        errors = json.load(open(merged_errors_path))

        # A base built for another revision, and a nested run that reported a
        # top-level attribute: both would corrupt the file the join reads, so
        # both have to be refused rather than merged.
        wrong_rev = write(work, "wrong-rev.json", {**NESTED, "rev": "zzz"})
        stray = write(
            work,
            "stray.json",
            {**NESTED, "attrs": {"hello": NESTED["attrs"]["jetbrains.idea"]}},
        )
        for name, bad in [("wrong-rev", wrong_rev), ("stray", stray)]:
            if merge(script, base, bad, os.devnull):
                raise SystemExit(f"merge accepted {name}.json, which it must refuse")

    # Top-level rows carry across untouched — the whole point, since deriving
    # them again is what costs the 52 seconds.
    assert m["attrs"]["hello"]["outputs"]["out"] == "aaaa", m
    assert m["attrs"]["ripgrep"]["outputs"]["out"] == "bbbb", m

    # The new list's rows arrive.
    assert m["attrs"]["jetbrains.idea"]["outputs"]["out"] == "dddd", m

    # And a row from a set no longer on the list is gone, which is why this
    # replaces the nested half rather than appending to it.
    assert "gone.child" not in m["attrs"], m
    assert "gone.child2" not in errors, errors

    assert m["attrCount"] == 3, m
    assert m["rev"] == "abc" and m["system"] == "x86_64-linux", m
    assert errors == {"broken": "error: no", "jetbrains.rider": "error: unfree"}, errors
    assert m["errorCount"] == 2, m

    print(f"merged {m['attrCount']} attrs, {m['errorCount']} errors")


if __name__ == "__main__":
    main()

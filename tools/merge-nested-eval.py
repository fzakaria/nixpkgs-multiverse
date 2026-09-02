#!/usr/bin/env python3
"""Fold a nested-only evaluation into a full one, producing the file the join reads.

An evaluation file is {rev, system, attrCount, errorCount, attrs: {attr: ...}},
where a top-level attribute is a bare name and a child of a package set
nix/nested-sets.nix lists is a dotted path — `jetbrains.idea`. The two key
spaces cannot collide, which is what makes this a merge rather than a guess.

The nested rows are *replaced* rather than added to, so one operation covers
every edit to the list: adding a set brings new rows, removing one drops the
rows it used to contribute, and reordering changes nothing. Only the dotted
rows are touched; the top-level ones are carried across untouched, which is the
whole point — recomputing them costs 52 seconds a file against 3.

    merge-nested-eval.py --base <full.json> --nested <nested.json> --out <file>
                         [--base-errors <f> --nested-errors <f> --out-errors <f>]
"""
import argparse
import json


def load(path):
    with open(path) as f:
        return json.load(f)


def top_level(attrs):
    """Everything that is not a child of a package set."""
    return {a: v for a, v in attrs.items() if "." not in a}


def nested(attrs):
    """Everything that is."""
    return {a: v for a, v in attrs.items() if "." in a}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="a full evaluation to carry across")
    ap.add_argument(
        "--nested", required=True, help="an evaluation of the listed sets alone"
    )
    ap.add_argument("--out", required=True)
    ap.add_argument("--base-errors")
    ap.add_argument("--nested-errors")
    ap.add_argument("--out-errors")
    a = ap.parse_args()

    base, add = load(a.base), load(a.nested)

    # Merging two revisions, or two systems, would produce a file that lies
    # about which build it describes — and the digests are per system, which is
    # the whole of issue #12. Refuse rather than trust the filenames.
    for field in ("rev", "system"):
        if base[field] != add[field]:
            raise SystemExit(
                f"merge-nested-eval: {field} differs — base {base[field]}, nested {add[field]}"
            )

    # A nested run that reported a bare name means it was handed something other
    # than a package set, and the merge would overwrite a real top-level row
    # with it.
    stray = sorted(top_level(add["attrs"]))
    if stray:
        raise SystemExit(
            f"merge-nested-eval: the nested evaluation reported {len(stray)} top-level "
            f"attribute(s), starting with {stray[0]}; it should report only <set>.<child>"
        )

    attrs = top_level(base["attrs"]) | nested(add["attrs"])

    errors = {}
    if a.base_errors and a.nested_errors:
        errors = top_level(load(a.base_errors)) | nested(load(a.nested_errors))

    doc = {
        "rev": base["rev"],
        "system": base["system"],
        "attrCount": len(attrs),
        "errorCount": len(errors) if a.out_errors else base["errorCount"],
        "attrs": dict(sorted(attrs.items())),
    }
    with open(a.out, "w") as f:
        json.dump(doc, f, separators=(",", ":"), sort_keys=True)
    if a.out_errors:
        with open(a.out_errors, "w") as f:
            json.dump(
                dict(sorted(errors.items())), f, separators=(",", ":"), sort_keys=True
            )

    print(
        f"{len(attrs)} attrs ({len(nested(attrs))} nested), {doc['errorCount']} errors"
    )


if __name__ == "__main__":
    main()

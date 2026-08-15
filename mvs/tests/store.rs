//! End-to-end tests for the store-path surface: `mvs path`, `size`, `deps`,
//! `rdeps` and `identify`.
//!
//! Unlike tests/cli.rs, these do not run against the real index — the flake's
//! database is built without store-path artifacts. Instead each test bakes a
//! small fixture with the real `build-db.py`, store artifacts included, so the
//! builder and the reader are tested against each other rather than against a
//! schema copied into the test. They need `python3` and skip without it.

use std::path::PathBuf;
use std::process::{Command, Output};

use serde_json::json;

/// The fixture's store digests: 32 characters each, drawn from Nix's base32
/// alphabet (digits are always in it). Each constant is one path in the story
/// the fixture tells, spelled out at its definition.
const DIGEST_LEN: usize = 32;

/// hello-2.12.1, the closed pair, found at offset 1.
const HELLO_OLD: char = '1';
/// hello-2.12.2, the pair current at the tip.
const HELLO_TIP: char = '2';
/// libfoo 1.0, current, whose derivation name differs: libfoo-unstable-1.0.
const LIBFOO: char = '3';
/// app 0.1, current; its references point at both hellos.
const APP: char = '4';
/// glibc-9.99, seen only as a reference — never an indexed pair.
const GLIBC: char = '5';
/// hello-2.12.2's `dev` sibling output.
const HELLO_DEV: char = '6';
/// A rebuild of hello-2.12.1 out of another revision: same store name,
/// different digest. What the name fallback exists to resolve.
const HELLO_OLD_REBUILD: char = '7';

fn digest(c: char) -> String {
    c.to_string().repeat(DIGEST_LEN)
}

fn basename(c: char, name: &str) -> String {
    format!("{}-{name}", digest(c))
}

fn store_path(c: char, name: &str) -> String {
    format!("/nix/store/{}", basename(c, name))
}

struct Mvs {
    db: PathBuf,
}

impl Mvs {
    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_mvs"))
            .arg("--db")
            .arg(&self.db)
            .args(args)
            .output()
            .expect("running mvs")
    }

    fn stdout(&self, args: &[&str]) -> String {
        let out = self.run(args);
        assert!(
            out.status.success(),
            "mvs {args:?} failed:\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).expect("utf-8 output")
    }

    fn json(&self, args: &[&str]) -> serde_json::Value {
        let mut argv = vec!["--json"];
        argv.extend(args);
        serde_json::from_str(&self.stdout(&argv)).expect("json output")
    }
}

/// Whether the store artifacts go into the fixture, so one helper builds both
/// the database under test and the one the graceful-refusal test needs.
#[derive(PartialEq)]
enum StoreData {
    Included,
    Omitted,
}

fn python_available() -> bool {
    Command::new("python3")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Bake a fixture database with `build-db.py`, in a directory of its own named
/// after the test so parallel tests never collide. `None` when there is no
/// python3 to run the builder with.
fn fixture(test: &str, store_data: StoreData) -> Option<Mvs> {
    if !python_available() {
        eprintln!("skipping: no python3 to run build-db.py with");
        return None;
    }

    let root = std::env::temp_dir().join(format!("mvs-store-{test}-{}", std::process::id()));
    // A stale directory from an interrupted run would feed the builder old
    // files alongside new ones.
    std::fs::remove_dir_all(&root).ok();
    std::fs::create_dir_all(root.join("index")).unwrap();
    std::fs::create_dir_all(root.join("data")).unwrap();

    let write = |rel: &str, value: serde_json::Value| {
        std::fs::write(root.join(rel), serde_json::to_vec(&value).unwrap()).unwrap();
    };

    // Three revisions; hello moves 2.12.1 -> 2.12.2 at the last one, libfoo
    // and app hold one version throughout.
    write(
        "revisions.json",
        json!([
            {"rev": "a".repeat(40), "date": "2024-01-01", "narHash": "sha256-aaa"},
            {"rev": "b".repeat(40), "date": "2024-02-01", "narHash": "sha256-bbb"},
            {"rev": "c".repeat(40), "date": "2024-03-01", "narHash": "sha256-ccc"},
        ]),
    );
    write("releases.json", json!({}));
    write(
        "index/history.json",
        json!({
            "revisionCount": 3,
            "attrs": {
                "hello": {"2.12.1": [0, 1], "2.12.2": [2, null]},
                "libfoo": {"1.0": [0, null]},
                "app": {"0.1": [1, null]},
            },
        }),
    );

    if store_data == StoreData::Included {
        // The closed pair carries its explicit drv name and found offset; the
        // tip pairs carry a name only where it differs from attr-version.
        write(
            "data/outpaths.json",
            json!({
                "revisionCount": 3,
                "attrs": {
                    "hello": {"2.12.1": [digest(HELLO_OLD), "hello-2.12.1", 1]},
                },
            }),
        );
        write(
            "data/tip-outpaths.json",
            json!({
                "revisionCount": 3,
                "attrs": {
                    "hello": {"2.12.2": [digest(HELLO_TIP)]},
                    "libfoo": {"1.0": [digest(LIBFOO), "libfoo-unstable-1.0"]},
                    "app": {"0.1": [digest(APP)]},
                },
            }),
        );

        // Two info shards, exercising the <stem>*.json merge the sharded
        // artifacts rely on.
        write(
            "data/info-indexed-a.json",
            json!({
                digest(HELLO_TIP): [1, 213432, 49368, "hello-2.12.2", "nar/h2.nar.xz"],
            }),
        );
        write(
            "data/info-indexed-b.json",
            json!({
                digest(HELLO_OLD): [0, 50, 20, "hello-2.12.1", "nar/h1.nar.xz"],
                digest(LIBFOO): [1, 1000, 500, "libfoo-unstable-1.0", "nar/l1.nar.xz"],
            }),
        );

        // hello's references resolve one of each way — libfoo by digest,
        // glibc not at all — and app's point at the exact hello-2.12.2 path
        // plus a same-named rebuild of hello-2.12.1.
        write(
            "data/refs-indexed.json",
            json!({
                digest(HELLO_TIP): [
                    basename(LIBFOO, "libfoo-unstable-1.0"),
                    basename(GLIBC, "glibc-9.99"),
                ],
                digest(APP): [
                    basename(HELLO_TIP, "hello-2.12.2"),
                    basename(HELLO_OLD_REBUILD, "hello-2.12.1"),
                ],
            }),
        );
        write(
            "data/closures.json",
            json!({ digest(HELLO_TIP): [50000000, 12, 0] }),
        );
        write(
            "data/outs-indexed.json",
            json!({
                "hello-2.12.2": [["dev", digest(HELLO_DEV), 4096, [digest(HELLO_TIP)]]],
            }),
        );
    }

    let builder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("build-db.py");
    let db = root.join("index.db");
    let mut argv = vec![
        builder.to_str().unwrap().to_string(),
        root.to_str().unwrap().to_string(),
        db.to_str().unwrap().to_string(),
    ];
    if store_data == StoreData::Included {
        argv.push("--data-dir".to_string());
        argv.push(root.join("data").to_str().unwrap().to_string());
    }

    let out = Command::new("python3")
        .args(&argv)
        .output()
        .expect("running build-db.py");
    assert!(
        out.status.success(),
        "build-db.py failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );

    Some(Mvs { db })
}

/// `mvs path`: the printed store path for an exact version, for a bare
/// attribute (tip wins over a newer spelling being absent), and for a pair
/// whose derivation name differs from attr-version. stdout is the bare path
/// alone, which is what command substitution feeds nix-store --realise.
#[test]
fn prints_store_paths() {
    let Some(mvs) = fixture("path", StoreData::Included) else {
        return;
    };

    assert_eq!(
        mvs.stdout(&["path", "hello@2.12.2"]).trim(),
        store_path(HELLO_TIP, "hello-2.12.2")
    );
    assert_eq!(
        mvs.stdout(&["path", "hello@2.12.1"]).trim(),
        store_path(HELLO_OLD, "hello-2.12.1")
    );

    // No version given: the tip pair wins over the older one.
    assert_eq!(
        mvs.stdout(&["path", "hello"]).trim(),
        store_path(HELLO_TIP, "hello-2.12.2")
    );

    // The derivation name, not attr-version, is what the path carries.
    assert_eq!(
        mvs.stdout(&["path", "libfoo@1.0"]).trim(),
        store_path(LIBFOO, "libfoo-unstable-1.0")
    );

    // A version no revision ever built is an error, not an empty answer.
    assert!(!mvs.run(&["path", "hello@9.9"]).status.success());
    assert!(!mvs
        .run(&["path", "definitely-not-a-package"])
        .status
        .success());
}

/// `mvs size`: narinfo, closure and sibling-output numbers coming back out of
/// the database exactly as the artifacts put them in. Checked through --json;
/// the human formatting is unit-tested where it lives.
#[test]
fn reports_sizes() {
    let Some(mvs) = fixture("size", StoreData::Included) else {
        return;
    };

    let size = mvs.json(&["size", "hello@2.12.2"]);
    assert_eq!(size["details"]["nar_size"], json!(213432));
    assert_eq!(size["details"]["file_size"], json!(49368));
    assert_eq!(size["details"]["closure_bytes"], json!(50000000));
    assert_eq!(size["details"]["closure_paths"], json!(12));
    assert_eq!(size["details"]["live"], json!(true));
    assert_eq!(size["tip"], json!(true));

    // The dev output rides along, with its own path and size.
    assert_eq!(size["outputs"][0]["suffix"], json!("dev"));
    assert_eq!(size["outputs"][0]["nar_size"], json!(4096));
    assert_eq!(size["outputs"][0]["digest"], json!(digest(HELLO_DEV)));

    // A pair with no narinfo and no closure row answers with nothing rather
    // than failing: app was never in the info artifacts.
    let bare = mvs.json(&["size", "app@0.1"]);
    assert_eq!(bare["details"], json!(null));
}

/// `mvs deps`: references resolved by digest where the exact path is a pair's,
/// by store name for a same-named rebuild, and left unresolved when neither
/// matches.
#[test]
fn resolves_deps() {
    let Some(mvs) = fixture("deps", StoreData::Included) else {
        return;
    };

    // hello's two references: libfoo is a pair's exact path, glibc is nobody's.
    let deps = mvs.json(&["deps", "hello@2.12.2"]);
    let refs = deps["refs"].as_array().unwrap();
    assert_eq!(refs.len(), 2);
    let libfoo = refs
        .iter()
        .find(|r| r["digest"] == json!(digest(LIBFOO)))
        .unwrap();
    assert_eq!(libfoo["packages"], json!(["libfoo@1.0"]));
    assert_eq!(libfoo["matched_by"], json!("digest"));
    let glibc = refs
        .iter()
        .find(|r| r["digest"] == json!(digest(GLIBC)))
        .unwrap();
    assert_eq!(glibc["packages"], json!([]));
    assert_eq!(glibc["matched_by"], json!(null));

    // app references the exact hello-2.12.2 path and a rebuild of
    // hello-2.12.1 under another digest: one digest match, one name match.
    let deps = mvs.json(&["deps", "app@0.1"]);
    let refs = deps["refs"].as_array().unwrap();
    let exact = refs
        .iter()
        .find(|r| r["digest"] == json!(digest(HELLO_TIP)))
        .unwrap();
    assert_eq!(exact["packages"], json!(["hello@2.12.2"]));
    assert_eq!(exact["matched_by"], json!("digest"));
    let rebuild = refs
        .iter()
        .find(|r| r["digest"] == json!(digest(HELLO_OLD_REBUILD)))
        .unwrap();
    assert_eq!(rebuild["packages"], json!(["hello@2.12.1"]));
    assert_eq!(rebuild["matched_by"], json!("name"));
}

/// `mvs rdeps`: the reverse edges, including a referrer that points at a
/// same-named rebuild rather than the pair's own digest, and the count of
/// referrers that are no pair — hello's dev output references hello itself.
#[test]
fn resolves_rdeps() {
    let Some(mvs) = fixture("rdeps", StoreData::Included) else {
        return;
    };

    // app references hello-2.12.2's exact path; the dev output does too but
    // is no indexed pair, so it is counted rather than listed.
    let rdeps = mvs.json(&["rdeps", "hello@2.12.2"]);
    let entries = rdeps["rdeps"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["attr"], json!("app"));
    assert_eq!(entries[0]["version"], json!("0.1"));
    assert_eq!(rdeps["unindexed_referrers"], json!(1));

    // app's reference to old hello names a rebuild digest, not the pair's own
    // path — found through the store name.
    let rdeps = mvs.json(&["rdeps", "hello@2.12.1"]);
    let entries = rdeps["rdeps"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["attr"], json!("app"));

    // libfoo is referenced by hello alone.
    let rdeps = mvs.json(&["rdeps", "libfoo@1.0"]);
    let entries = rdeps["rdeps"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["attr"], json!("hello"));
}

/// `mvs identify`: the three accepted spellings agree, a pair's path comes
/// back as its package, an output digest names its derivation and suffix, and
/// an unknown digest is an error.
#[test]
fn identifies_store_paths() {
    let Some(mvs) = fixture("identify", StoreData::Included) else {
        return;
    };

    let by_digest = mvs.json(&["identify", &digest(HELLO_TIP)]);
    let by_basename = mvs.json(&["identify", &basename(HELLO_TIP, "hello-2.12.2")]);
    let by_path = mvs.json(&["identify", &store_path(HELLO_TIP, "hello-2.12.2")]);
    assert_eq!(by_digest, by_basename);
    assert_eq!(by_digest, by_path);
    assert_eq!(by_digest["packages"][0]["attr"], json!("hello"));
    assert_eq!(by_digest["packages"][0]["version"], json!("2.12.2"));
    assert_eq!(by_digest["packages"][0]["tip"], json!(true));

    // A sibling output identifies as output of its derivation, not a package.
    let output = mvs.json(&["identify", &digest(HELLO_DEV)]);
    assert_eq!(output["packages"], json!([]));
    assert_eq!(output["outputs"][0]["drv_name"], json!("hello-2.12.2"));
    assert_eq!(output["outputs"][0]["suffix"], json!("dev"));

    // A digest the index never saw, and a string that is no digest at all.
    assert!(!mvs.run(&["identify", &digest('9')]).status.success());
    assert!(!mvs.run(&["identify", "not-a-digest"]).status.success());
}

/// A database built without --data-dir: the store subcommands refuse with the
/// one-sentence explanation, and the pre-existing surface still answers.
#[test]
fn refuses_gracefully_without_store_data() {
    let Some(mvs) = fixture("nodata", StoreData::Omitted) else {
        return;
    };

    for subcommand in ["path", "size", "deps", "rdeps"] {
        let out = mvs.run(&[subcommand, "hello@2.12.2"]);
        assert!(!out.status.success(), "mvs {subcommand} must refuse");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("without store-path data"), "{stderr}");
    }
    let out = mvs.run(&["identify", &digest(HELLO_TIP)]);
    assert!(!out.status.success());

    // The history surface is untouched by the missing artifacts.
    assert_eq!(
        mvs.stdout(&["query", "at", "2024-02-01", "hello"])
            .lines()
            .next()
            .unwrap(),
        "2.12.1"
    );
}

/// The store tables do not disturb the history surface: the same settled
/// question answers identically on a database with them.
#[test]
fn history_survives_store_tables() {
    let Some(mvs) = fixture("history", StoreData::Included) else {
        return;
    };

    assert_eq!(
        mvs.stdout(&["query", "at", "2024-02-01", "hello"])
            .lines()
            .next()
            .unwrap(),
        "2.12.1"
    );
    assert_eq!(
        mvs.stdout(&["query", "at", "tip", "hello"])
            .lines()
            .next()
            .unwrap(),
        "2.12.2"
    );
}

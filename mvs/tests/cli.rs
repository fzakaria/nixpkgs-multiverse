//! End-to-end tests: the built binary against the real index.
//!
//! These check the answers a user actually sees — including exit statuses,
//! which scripts branch on and which no unit test covers — against facts that
//! are settled and cannot change as the index grows. Nothing here asserts on
//! anything drawn from the newest revision.
//!
//! They need a database, which comes from `$MVS_DB` or from `nix build
//! .#index-db`, so they skip where there is neither.

mod common;

use std::path::PathBuf;
use std::process::{Command, Output};

/// A revision from well inside the index, and what it shipped. Fixed forever:
/// the tree at that commit does not change.
const SETTLED_DATE: &str = "2022-03-15";
const SETTLED_LABEL: &str = "2022-03-14-73ad5f9e147c";
const SETTLED_PYTHON: &str = "3.9.10";

/// A version old enough to be settled, and the commit that last shipped it.
const OLD_RIPGREP: &str = "13.0.0";
const OLD_RIPGREP_REV: &str = "7c6e3666e2040fb64d43b209b84f65898ea3095d";

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
}

/// `None` when there is no database to test against, which is what the build
/// sandbox looks like.
fn mvs() -> Option<Mvs> {
    if std::env::var_os("MVS_DB").is_none() && !common::nix_available() {
        eprintln!("skipping: no $MVS_DB and no nix to build one with");
        return None;
    }
    Some(Mvs {
        db: common::index_db(),
    })
}

/// The read-only surface, over facts that cannot move: what a 2022 revision
/// shipped, when a version that is long gone was present, and that a selector
/// resolves to the same revision by date, by label and by commit prefix.
#[test]
fn answers_settled_questions() {
    let Some(mvs) = mvs() else { return };

    assert_eq!(
        mvs.stdout(&["query", "at", SETTLED_DATE, "python3"])
            .lines()
            .next()
            .unwrap(),
        SETTLED_PYTHON
    );

    // A date resolves to the newest revision on or before it, so the three
    // spellings of that revision must agree.
    let by_date = mvs.stdout(&["--json", "query", "rev", SETTLED_DATE]);
    let by_label = mvs.stdout(&["--json", "query", "rev", SETTLED_LABEL]);
    let by_commit = mvs.stdout(&["--json", "query", "rev", "73ad5f9e147c"]);
    assert_eq!(by_date, by_label);
    assert_eq!(by_date, by_commit);

    // python2 left nixpkgs, which is the answer `gone` exists to give.
    let gone: serde_json::Value =
        serde_json::from_str(&mvs.stdout(&["--json", "query", "gone", "python2"])).unwrap();
    assert_eq!(gone["gone"], serde_json::json!(true));

    // An attribute that was never in the index is an error, not an empty
    // answer: "never existed" and "left" must not read the same.
    let out = mvs.run(&["query", "versions", "definitely-not-a-package"]);
    assert!(!out.status.success());
}

/// A release is refused wherever history is involved, since a release name is a
/// channel tip that moves and has no offset — the same refusal `multiverse.nix`
/// makes — but still resolves as a revision lookup.
#[test]
fn refuses_a_release_where_it_would_have_to_guess() {
    let Some(mvs) = mvs() else { return };

    let out = mvs.run(&["query", "at", "26.05", "python3"]);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("channel tip that moves"), "{stderr}");

    // `query rev` has no history to get wrong, so it answers.
    assert!(mvs
        .stdout(&["query", "rev", "26.05"])
        .contains("release 26.05"));
}

/// solve: a satisfiable pair, an impossible one, and the exit status each
/// gives, which is what a script branches on.
#[test]
fn solves_and_proves_unsatisfiable() {
    let Some(mvs) = mvs() else { return };

    let solved: serde_json::Value =
        serde_json::from_str(&mvs.stdout(&["--json", "solve", "python3@3.8", "nodejs@14"]))
            .unwrap();
    assert_eq!(solved["satisfiable"], serde_json::json!(true));
    assert!(solved["revisions"].as_i64().unwrap() > 0);

    let out = mvs.run(&["--json", "solve", "python3@3.6", "ripgrep@14"]);
    assert!(
        !out.status.success(),
        "an impossible solve must exit non-zero"
    );
    let answer: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(answer["satisfiable"], serde_json::json!(false));
    assert!(answer["disjoint"].is_array());

    // The component-wise prefix: 3.1 must not be satisfied by 3.10 through
    // 3.13, which a string prefix or a SQL GLOB would allow.
    assert!(!mvs.run(&["solve", "python3@3.1"]).status.success());
}

/// The lock file, end to end in a temporary directory: add, list, update a pin
/// that is already newest, and remove.
#[test]
fn locks_pins() {
    let Some(mvs) = mvs() else { return };

    let dir = std::env::temp_dir().join(format!("mvs-cli-lock-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("multiverse.lock");
    let file = file.to_str().unwrap();

    mvs.stdout(&[
        "lock",
        "--file",
        file,
        "add",
        &format!("ripgrep@{OLD_RIPGREP}"),
    ]);
    let lock: serde_json::Value =
        serde_json::from_str(&mvs.stdout(&["--json", "lock", "--file", file, "list"])).unwrap();
    assert_eq!(lock["pins"]["ripgrep"]["rev"], OLD_RIPGREP_REV);
    assert_eq!(lock["pins"]["ripgrep"]["version"], OLD_RIPGREP);
    // The constraint is stored, or update would walk this pin off 13.x.
    assert_eq!(lock["pins"]["ripgrep"]["constraint"], "13.0.0");

    // A pin already at the newest revision satisfying it does not move.
    let moved: serde_json::Value =
        serde_json::from_str(&mvs.stdout(&["--json", "lock", "--file", file, "update", "ripgrep"]))
            .unwrap();
    assert_eq!(moved["moved"].as_array().unwrap().len(), 0);

    let status: serde_json::Value =
        serde_json::from_str(&mvs.stdout(&["--json", "lock", "--file", file, "status"])).unwrap();
    assert_eq!(status["pins"][0]["versions_behind"], 0);

    mvs.stdout(&["lock", "--file", file, "rm", "ripgrep"]);
    let empty: serde_json::Value =
        serde_json::from_str(&mvs.stdout(&["--json", "lock", "--file", file, "list"])).unwrap();
    assert_eq!(empty["pins"], serde_json::json!({}));

    // Removing what is not pinned is an error rather than a silent no-op.
    assert!(!mvs
        .run(&["lock", "--file", file, "rm", "ripgrep"])
        .status
        .success());
    std::fs::remove_dir_all(&dir).ok();
}

/// `--eval` takes the evaluation road: `mvs run` resolves to the commit that
/// shipped the version and hands the rest to nix. Checked through --dry-run,
/// so the test does not fetch 378 MB.
#[test]
fn resolves_what_it_would_run() {
    let Some(mvs) = mvs() else { return };

    let line = mvs.stdout(&[
        "run",
        &format!("ripgrep@{OLD_RIPGREP}"),
        "--eval",
        "--dry-run",
        "--",
        "--version",
    ]);
    assert_eq!(
        line.trim(),
        format!("nix run github:NixOS/nixpkgs/{OLD_RIPGREP_REV}#ripgrep -- --version")
    );

    // A shell composes across revisions, so each installable carries its own
    // commit.
    let line = mvs.stdout(&[
        "shell",
        &format!("ripgrep@{OLD_RIPGREP}"),
        "python3@3.8",
        "--eval",
        "--dry-run",
    ]);
    assert!(line.contains(OLD_RIPGREP_REV), "{line}");
    assert_eq!(line.matches("github:NixOS/nixpkgs/").count(), 2, "{line}");
}

/// Without `--eval`, the same commands take the store-path road: one
/// substitution of an indexed path, no revision named at all. Skipped on a
/// database built without store data, where there is no fast road to take —
/// which `mvs path` failing is exactly the signal for.
#[test]
fn prefers_the_store_path_road() {
    let Some(mvs) = mvs() else { return };

    let spec = format!("ripgrep@{OLD_RIPGREP}");
    if !mvs.run(&["path", &spec]).status.success() {
        eprintln!("skipping: database has no store-path data");
        return;
    }

    let line = mvs.stdout(&["run", &spec, "--dry-run", "--", "--version"]);
    assert!(
        line.starts_with("nix-store --realise /nix/store/"),
        "{line}"
    );
    assert!(line.contains("ripgrep-"), "{line}");
    assert!(!line.contains("github:NixOS/nixpkgs/"), "{line}");

    // A shell mixes roads per package, so an indexed one contributes a store
    // path where an unindexed one would contribute a revision.
    let line = mvs.stdout(&["shell", &spec, "--dry-run"]);
    assert!(line.contains("/nix/store/"), "{line}");
}

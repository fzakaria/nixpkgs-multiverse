//! `mvs lock` — per-package pins.
//!
//! Each pin names one revision, and `mvs lock update <attr>` moves **only** that
//! entry. Every other pin stays exactly where it was, which is the whole point:
//! a single flake input moves everything at once, and that is why people end up
//! not updating at all.
//!
//! The two-step workflow this implies is honest rather than accidental. A pin
//! can never point past what the index knows, because materialising a revision
//! needs its narHash and `mvs` only has the ones in its baked database:
//!
//! ```console
//! $ nix flake update multiverse    # learn about newer revisions
//! $ mvs lock update helix           # move this one package
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use owo_colors::OwoColorize;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::date;
use crate::db::{Index, Run};
use crate::output::{self, Cell, Table};
use crate::query::Format;
use crate::solve::{self, block_for, newest_pinnable, spans_for, Constraint};

/// The lock file's name, and the one `multiverse.lib.readLock` expects.
pub const LOCK_FILE: &str = "multiverse.lock";

/// Schema version of the lock file. Bumped only for a change that an older
/// `mvs` could misread; a new optional field does not need one.
pub const LOCK_VERSION: u32 = 1;

#[derive(Serialize, Deserialize)]
pub struct Lock {
    pub version: u32,
    /// Sorted by attribute, so a pin added today produces a one-line diff
    /// wherever it lands alphabetically rather than a reordering.
    pub pins: BTreeMap<String, Pin>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Pin {
    pub rev: String,
    pub label: String,
    pub version: String,
    pub date: String,

    /// The version prefix the pin was added with, if any. `mvs lock update`
    /// stays inside it — a pin added as `python3@3.8` is a decision to be on
    /// 3.8, and update must not silently walk it to 3.14.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub constraint: Option<String>,
}

impl Lock {
    fn empty() -> Lock {
        Lock {
            version: LOCK_VERSION,
            pins: BTreeMap::new(),
        }
    }

    /// Read the lock file, or an empty lock if there is none yet.
    pub fn read(path: &Path) -> Result<Lock> {
        if !path.exists() {
            return Ok(Lock::empty());
        }

        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let lock: Lock =
            serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;

        if lock.version != LOCK_VERSION {
            return Err(anyhow!(
                "{} is version {}, and this mvs understands version {LOCK_VERSION}. \
                 Update multiverse.",
                path.display(),
                lock.version
            ));
        }
        Ok(lock)
    }

    /// Write the lock file. Pretty-printed with a trailing newline: it is a
    /// committed file that shows up in review.
    pub fn write(&self, path: &Path) -> Result<()> {
        let mut text = serde_json::to_string_pretty(self)?;
        text.push('\n');
        std::fs::write(path, text).with_context(|| format!("writing {}", path.display()))
    }
}

/// Where the lock file lives: `--file` if given, otherwise `multiverse.lock` in
/// the working directory. No search up the tree — a pin file that is picked up
/// from a parent directory is a pin file you did not know you were editing.
pub fn lock_path(explicit: Option<&Path>) -> PathBuf {
    explicit
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(LOCK_FILE))
}

/// Resolve a constraint to the revision a pin should name: the newest indexed
/// revision that satisfies it *and* can be materialised.
fn pin_for(index: &Index, constraint: &Constraint) -> Result<Pin> {
    let spans = spans_for(index, constraint)?;
    if spans.is_empty() {
        return Err(anyhow!("no revision ever had {}", constraint.describe()));
    }

    let off = newest_pinnable(index, &spans)?;
    let revision = index.revision(off)?;
    let version = index
        .runs_of(&constraint.attr)?
        .into_iter()
        .find(|r| r.first <= off && off <= r.last)
        .map(|r| r.version)
        .ok_or_else(|| anyhow!("{} is not in {}", constraint.attr, revision.label))?;

    Ok(Pin {
        rev: revision.rev,
        label: revision.label,
        version,
        date: revision.date,
        constraint: constraint.version.clone(),
    })
}

/// `mvs lock add <attr>[@ver]`
pub fn add(index: &Index, path: &Path, spec: &str, format: Format) -> Result<()> {
    let constraint = Constraint::parse(spec)?;
    let mut lock = Lock::read(path)?;
    let pin = pin_for(index, &constraint)?;
    let previous = lock.pins.insert(constraint.attr.clone(), pin.clone());
    lock.write(path)?;

    if format == Format::Json {
        return output::print_json(json!({ "attr": constraint.attr, "pin": pin }));
    }

    let verb = if previous.is_some() {
        "repinned"
    } else {
        "pinned"
    };
    anstream::println!(
        "{verb} {} {} at {}",
        constraint.attr,
        pin.version.style(output::current()),
        pin.label
    );
    Ok(())
}

/// `mvs lock rm <attr>`
pub fn remove(path: &Path, attr: &str, format: Format) -> Result<()> {
    let mut lock = Lock::read(path)?;
    let removed = lock
        .pins
        .remove(attr)
        .ok_or_else(|| anyhow!("{attr} is not pinned in {}", path.display()))?;
    lock.write(path)?;

    if format == Format::Json {
        return output::print_json(json!({ "attr": attr, "removed": removed }));
    }
    anstream::println!(
        "unpinned {attr} (was {} at {})",
        removed.version,
        removed.label
    );
    Ok(())
}

/// `mvs lock update [<attr>]` — move one pin, or every pin with `--all`.
///
/// Each entry is recomputed on its own, so an update to one package cannot
/// move another. That is the whole difference from a flake input.
pub fn update(
    index: &Index,
    path: &Path,
    attr: Option<&str>,
    all: bool,
    format: Format,
) -> Result<()> {
    let mut lock = Lock::read(path)?;
    if lock.pins.is_empty() {
        return Err(anyhow!("{} has no pins", path.display()));
    }

    let targets: Vec<String> = match (attr, all) {
        (Some(attr), _) => {
            if !lock.pins.contains_key(attr) {
                return Err(anyhow!("{attr} is not pinned in {}", path.display()));
            }
            vec![attr.to_string()]
        }
        (None, true) => lock.pins.keys().cloned().collect(),
        (None, false) => {
            return Err(anyhow!(
                "name a package to update, or pass --all to move every pin"
            ))
        }
    };

    let mut moved = Vec::new();
    for attr in targets {
        let old = lock.pins[&attr].clone();
        let constraint = Constraint {
            attr: attr.clone(),
            version: old.constraint.clone(),
        };
        let new = pin_for(index, &constraint)?;
        if new.rev != old.rev {
            moved.push(json!({
                "attr": attr,
                "from": { "version": old.version, "label": old.label },
                "to": { "version": new.version, "label": new.label },
            }));
            lock.pins.insert(attr, new);
        }
    }

    if !moved.is_empty() {
        lock.write(path)?;
    }

    if format == Format::Json {
        return output::print_json(json!({ "moved": moved }));
    }

    if moved.is_empty() {
        anstream::println!("every pin is already at the newest indexed revision");
        return Ok(());
    }
    for entry in &moved {
        anstream::println!(
            "{}: {} → {}  ({})",
            entry["attr"].as_str().unwrap(),
            entry["from"]["version"].as_str().unwrap(),
            entry["to"]["version"]
                .as_str()
                .unwrap()
                .style(output::current()),
            entry["to"]["label"].as_str().unwrap()
        );
    }
    Ok(())
}

/// `mvs lock minimize` — move the existing pins onto the fewest revisions.
///
/// Deliberately one-shot rather than a mode the lock remembers. `update`
/// promises to move exactly the pin it names, and a lock that re-minimised
/// itself on every update would quietly move revisions under pins nobody
/// asked about — the same versions, but different builds of them. Regrouping
/// is therefore something the caller asks for, and can see the whole of.
///
/// Versions never change here. Each pin keeps the exact version it holds and
/// only the revision serving it moves, which is why this can share a revision
/// between pins without the caller re-deciding anything.
pub fn minimize(index: &Index, path: &Path, check: bool, format: Format) -> Result<()> {
    let mut lock = Lock::read(path)?;
    if lock.pins.is_empty() {
        return Err(anyhow!("{} has no pins", path.display()));
    }

    // The pinned version, not the constraint it was added with: minimising is
    // allowed to change which revision serves a version and never which
    // version is served.
    let attrs: Vec<String> = lock.pins.keys().cloned().collect();
    let constraints: Vec<Constraint> = attrs
        .iter()
        .map(|attr| Constraint {
            attr: attr.clone(),
            version: Some(lock.pins[attr].version.clone()),
        })
        .collect();

    let blocks = constraints
        .iter()
        .map(|c| block_for(index, c))
        .collect::<Result<Vec<_>>>()?;
    let plan = solve::plan(&blocks);

    let before = lock
        .pins
        .values()
        .map(|pin| pin.rev.clone())
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    let after = plan.groups.len();
    let explanation = solve::why(&constraints, &plan.forced_by);

    // What each pin would become, and how much older that leaves it.
    let mut moves = Vec::new();
    for group in &plan.groups {
        let revision = index.revision(group.off)?;
        for &i in &group.pins {
            let old = &lock.pins[&attrs[i]];
            if old.rev == revision.rev {
                continue;
            }
            moves.push(json!({
                "attr": attrs[i],
                "version": old.version,
                "from": { "label": old.label, "date": old.date },
                "to": { "label": revision.label, "date": revision.date },
                "days": date::days_between(&revision.date, &old.date),
                "rev": revision.rev,
            }));
        }
    }

    // --check reports and refuses to write, so CI can fail on a lock that has
    // drifted without also rewriting it.
    if !check {
        for entry in &moves {
            let attr = entry["attr"].as_str().unwrap();
            let pin = lock.pins.get_mut(attr).expect("pin from this lock");
            pin.rev = entry["rev"].as_str().unwrap().to_string();
            pin.label = entry["to"]["label"].as_str().unwrap().to_string();
            pin.date = entry["to"]["date"].as_str().unwrap().to_string();
        }
        if !moves.is_empty() {
            lock.write(path)?;
        }
    }

    if format == Format::Json {
        output::print_json(json!({
            "pins": attrs.len(),
            "before": before,
            "after": after,
            "moved": moves,
            "certificate": plan.forced_by.iter().map(|&i| constraints[i].describe()).collect::<Vec<_>>(),
            "why": explanation,
        }))?;
        if check && after < before {
            std::process::exit(1);
        }
        return Ok(());
    }

    if after == before {
        anstream::println!(
            "{} already sit on {} · {}",
            output::plural(attrs.len(), "pin"),
            output::plural(after, "revision"),
            "minimal".style(output::current())
        );
        return Ok(());
    }

    anstream::println!(
        "{} · {before} revisions → {} · {}",
        output::plural(attrs.len(), "pin"),
        after.style(output::current()),
        "minimal".style(output::current())
    );

    let mut table = Table::new(&["ATTR", "VERSION", "REVISION", "DATE", "OLDER BY"]);
    for entry in &moves {
        table.row(vec![
            Cell::new(entry["attr"].as_str().unwrap(), output::plain()),
            Cell::new(entry["version"].as_str().unwrap(), output::plain()),
            Cell::new(&entry["rev"].as_str().unwrap()[..12], output::plain()),
            Cell::new(entry["to"]["date"].as_str().unwrap(), output::plain()),
            Cell::new(
                format!("{} days", entry["days"].as_i64().unwrap()),
                output::muted(),
            ),
        ]);
    }
    anstream::println!();
    table.print();
    anstream::println!(
        "\n{}",
        format!("  minimal: {explanation}").style(output::muted())
    );

    if check {
        anstream::println!(
            "{}",
            "  nothing written; run `mvs lock minimize` to apply".style(output::muted())
        );
        std::process::exit(1);
    }
    Ok(())
}

/// `mvs lock list`
pub fn list(path: &Path, format: Format) -> Result<()> {
    let lock = Lock::read(path)?;

    if format == Format::Json {
        return output::print_json(serde_json::to_value(&lock)?);
    }

    if lock.pins.is_empty() {
        anstream::println!("{} has no pins", path.display());
        return Ok(());
    }

    let mut table = Table::new(&["ATTR", "VERSION", "DATE", "REVISION"]);
    for (attr, pin) in &lock.pins {
        table.row(vec![
            Cell::new(attr, output::plain()),
            Cell::new(&pin.version, output::plain()),
            Cell::new(&pin.date, output::muted()),
            Cell::new(&pin.rev[..12], output::muted()),
        ]);
    }
    table.print();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_lock(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mvs-lock-test-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(LOCK_FILE)
    }

    /// The file format, which is a committed artifact and so has to survive a
    /// round trip byte for byte: reads back what it wrote, keeps pins sorted by
    /// attribute, and omits `constraint` entirely when there is none.
    #[test]
    fn round_trips_the_lock_file() {
        let path = temp_lock("round-trip");
        let mut lock = Lock::empty();
        lock.pins.insert(
            "ripgrep".to_string(),
            Pin {
                rev: "5a09cb4b393d58f9ed0d9ca1555016a8543c2ac8".to_string(),
                label: "2023-11-23-5a09cb4b393d".to_string(),
                version: "13.0.0".to_string(),
                date: "2023-11-23".to_string(),
                constraint: Some("13".to_string()),
            },
        );
        lock.pins.insert(
            "helix".to_string(),
            Pin {
                rev: "2fcb964de67fcf60b43471c55d5d99e61a9ccb5a".to_string(),
                label: "2026-08-10-2fcb964de67f".to_string(),
                version: "25.07.1".to_string(),
                date: "2026-08-10".to_string(),
                constraint: None,
            },
        );
        lock.write(&path).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.ends_with('\n'), "a committed file ends with a newline");
        assert!(!text.contains("\"constraint\": null"), "{text}");
        // helix was inserted second and must still come first on disk.
        assert!(text.find("helix") < text.find("ripgrep"));

        let read = Lock::read(&path).unwrap();
        assert_eq!(read.pins.len(), 2);
        assert_eq!(read.pins["ripgrep"].constraint.as_deref(), Some("13"));
        assert_eq!(read.pins["helix"].constraint, None);
        std::fs::remove_file(&path).ok();
    }

    /// Absent and unreadable lock files. A missing one is an empty lock, since
    /// `mvs lock add` has to work in a directory that has none; a future format
    /// version is an error rather than a guess.
    #[test]
    fn handles_missing_and_future_files() {
        let path = temp_lock("missing");
        assert!(Lock::read(&path).unwrap().pins.is_empty());

        std::fs::write(&path, r#"{"version": 99, "pins": {}}"#).unwrap();
        let err = match Lock::read(&path) {
            Err(err) => err.to_string(),
            Ok(_) => panic!("a future lock version was accepted"),
        };
        assert!(err.contains("version 99"), "{err}");
        std::fs::remove_file(&path).ok();
    }

    fn run(version: &str, first: i64, last: i64) -> Run {
        Run {
            version: version.to_string(),
            first,
            last,
        }
    }

    /// What `lock status` counts as behind: every version nixpkgs shipped after
    /// the pinned revision, by when it shipped. Checked on the llama-cpp shape,
    /// where a version comparison ranks the old build number above every newer
    /// 0.x release, and on a version that left and came back.
    #[test]
    fn counts_versions_shipped_since_the_pin() {
        // llama-cpp went from build numbers to 0.x semver. A pin on build 10408
        // is two versions behind, though "10408" outranks both as a string.
        let renumbered = vec![
            run("10273", 1525, 1530),
            run("10408", 1531, 1537),
            run("0.2.0", 1538, 1539),
            run("0.3.0", 1540, 1544),
        ];
        assert_eq!(
            shipped_since(&renumbered, 1537, "10408"),
            vec!["0.2.0", "0.3.0"]
        );
        assert!(shipped_since(&renumbered, 1544, "0.3.0").is_empty());

        // kubectl 1.19.3 and 1.19.4 alternated. A pin on 1.19.4 at 508 is
        // behind the 1.19.3 that came back after it, counted once, and the
        // pinned version's own later run is not a newer version.
        let reverted = vec![
            run("1.19.3", 501, 507),
            run("1.19.4", 508, 508),
            run("1.19.3", 509, 509),
            run("1.19.4", 510, 520),
        ];
        assert_eq!(shipped_since(&reverted, 508, "1.19.4"), vec!["1.19.3"]);
        assert!(shipped_since(&reverted, 520, "1.19.4").is_empty());
    }
}

/// The versions nixpkgs shipped after the revision at offset `pinned`, other
/// than `pinned_version`, in the order they first shipped after it. `runs` is
/// ordered by first revision, as `Index::runs_of` returns it.
///
/// Read off when each version shipped rather than off the version string.
/// llama-cpp's build number 10408 outranks every 0.x release that replaced it,
/// so a version comparison would call a pin on 10408 current. A version that
/// left and came back after the pin counts once, since nixpkgs moved to it
/// again.
fn shipped_since(runs: &[Run], pinned: i64, pinned_version: &str) -> Vec<String> {
    let mut since: Vec<String> = Vec::new();
    for run in runs {
        // A run that began at or before the pin is history the pin already
        // saw, and the pinned version's own later runs are not newer versions.
        if run.first <= pinned || run.version == pinned_version {
            continue;
        }
        if since.contains(&run.version) {
            continue;
        }
        since.push(run.version.clone());
    }
    since
}

/// `mvs lock status` — how far behind each pin has fallen.
///
/// This is where the history index earns its place: "3 versions and 47 days
/// behind" with nothing fetched and no clock consulted. Both numbers are
/// measured against the newest revision the index knows, not against today, so
/// the answer is reproducible and moves only when the index does.
pub fn status(index: &Index, path: &Path, format: Format) -> Result<()> {
    let lock = Lock::read(path)?;
    if lock.pins.is_empty() {
        if format == Format::Json {
            return output::print_json(json!({ "pins": [] }));
        }
        anstream::println!("{} has no pins", path.display());
        return Ok(());
    }

    let mut rows = Vec::new();
    for (attr, pin) in &lock.pins {
        let constraint = Constraint {
            attr: attr.clone(),
            version: pin.constraint.clone(),
        };
        let newest = pin_for(index, &constraint)?;

        // The revision the pin names, as the offset "behind" is measured from.
        let pinned = index
            .revision_by_prefix(&pin.rev)?
            .ok_or_else(|| {
                anyhow!(
                    "{attr} is pinned to {}, which the index does not have",
                    pin.label
                )
            })?
            .off;

        // Versions behind counts what is actually reachable under the pin's own
        // constraint: a pin held at python3@3.8 is not "6 versions behind" 3.14,
        // it is exactly where it was asked to be.
        let newer: Vec<String> = shipped_since(&index.runs_of(attr)?, pinned, &pin.version)
            .into_iter()
            .filter(|v| match &pin.constraint {
                Some(prefix) => crate::solve::matches(v, prefix),
                None => true,
            })
            .collect();

        rows.push(json!({
            "attr": attr,
            "version": pin.version,
            "date": pin.date,
            "latest": newest.version,
            "latest_label": newest.label,
            "versions_behind": newer.len(),
            "days_behind": date::days_between(&pin.date, &newest.date),
        }));
    }

    if format == Format::Json {
        return output::print_json(json!({ "pins": rows }));
    }

    let mut table = Table::new(&["ATTR", "PINNED", "LATEST", "BEHIND"]);
    for row in &rows {
        let behind = row["versions_behind"].as_u64().unwrap();
        let days = row["days_behind"].as_i64().unwrap();
        table.row(vec![
            Cell::new(row["attr"].as_str().unwrap(), output::plain()),
            Cell::new(row["version"].as_str().unwrap(), output::plain()),
            Cell::new(
                row["latest"].as_str().unwrap(),
                if behind == 0 {
                    output::current()
                } else {
                    output::ended()
                },
            ),
            Cell::new(
                if behind == 0 {
                    "current".to_string()
                } else {
                    format!(
                        "{}, {}",
                        output::plural(behind as usize, "version"),
                        output::plural(days.max(0) as usize, "day")
                    )
                },
                if behind == 0 {
                    output::current()
                } else {
                    output::muted()
                },
            ),
        ]);
    }
    table.print();
    Ok(())
}

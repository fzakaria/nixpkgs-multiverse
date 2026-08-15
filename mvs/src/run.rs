//! `mvs run` and `mvs shell` — two roads to the same program.
//!
//! The fast road is the default and needs no evaluation at all: the
//! store-path index already knows which `/nix/store` path the version built
//! to, so the path is substituted straight from the binary cache and executed.
//! Seconds, and not one byte of nixpkgs.
//!
//! The eval road is the fallback and the `--eval` opt-out: `mvs` resolves
//! `attr@version` to the commit that shipped it and hands the rest to Nix,
//! which fetches that revision (~378 MB) and evaluates it. That is the only
//! road for a version the store-path index never matched, and the honest one
//! when the caller wants a real derivation rather than a cached artefact.
//!
//! `mvs` itself stays offline on both roads: the index says which revision or
//! which path, and materialising it is Nix's job.
//!
//! Deliberately scoped to leaf tools. `mvs shell ripgrep@13.0.0 fd@8.7.0`
//! composes across revisions, which is right for standalone binaries and wrong
//! for a development environment: two revisions mean two libcs and two
//! opensslls in one closure. For an environment, `mvs solve` gives one coherent
//! revision instead.

use std::process::Command;

use anyhow::{anyhow, Result};
use owo_colors::OwoColorize;

use crate::db::Index;
use crate::output;
use crate::solve::{newest_pinnable, spans_for, Constraint};
use crate::store;

/// Where a revision is fetched from. The same source `multiverse.nix` uses, so
/// a revision materialised by one is already in the store for the other.
const NIXPKGS: &str = "github:NixOS/nixpkgs";

/// Whether to execute the resolved command or only show it.
#[derive(Clone, Copy, PartialEq)]
pub enum Execute {
    Yes,
    /// `--dry-run`: print the `nix` command line and stop. Useful for seeing
    /// which revision a constraint resolved to before fetching ~378 MB of it.
    No,
}

/// Which road to the program: the store-path index, or an evaluation of the
/// revision that shipped it.
#[derive(Clone, Copy, PartialEq)]
pub enum Speed {
    /// Substitute the indexed store path and execute it. The default, and
    /// silently degrades to `Eval` when the version has no indexed path.
    Fast,
    /// `--eval`: resolve a revision and hand it to `nix run`/`nix shell`.
    Eval,
}

/// The indexed store path for a spec, or None when the fast road is closed —
/// the database carries no store data, or this version never matched a cached
/// build. Neither is an error here: the eval road answers both.
fn fast_target(index: &Index, spec: &str, speed: Speed) -> Option<store::Target> {
    if speed == Speed::Eval || !index.has_store_data() {
        return None;
    }
    store::target(index, spec).ok()
}

/// Resolve `attr[@version]` to a flake installable naming the revision that
/// shipped it: `github:NixOS/nixpkgs/<rev>#<attr>`.
fn installable(index: &Index, spec: &str) -> Result<(String, String, String)> {
    let constraint = Constraint::parse(spec)?;
    let spans = spans_for(index, &constraint)?;
    if spans.is_empty() {
        return Err(anyhow!(
            "no revision ever had {}. `mvs query versions {}` lists what there is.",
            constraint.describe(),
            constraint.attr
        ));
    }

    let off = newest_pinnable(index, &spans)?;
    let revision = index.revision(off)?;
    let version = index
        .runs_of(&constraint.attr)?
        .into_iter()
        .find(|r| r.first <= off && off <= r.last)
        .map(|r| r.version)
        .ok_or_else(|| anyhow!("{} is not in {}", constraint.attr, revision.label))?;

    Ok((
        format!("{NIXPKGS}/{}#{}", revision.rev, constraint.attr),
        version,
        revision.label,
    ))
}

/// Report what each spec resolved to, on stderr so that `mvs run`'s own output
/// stays whatever the program printed.
fn report(attr: &str, version: &str, label: &str) {
    anstream::eprintln!(
        "{}",
        format!("{attr} {version} from {label}").style(output::muted())
    );
}

/// Report a fast-road resolution, in the same muted shape as the eval road.
fn report_fast(target: &store::Target) {
    let state = if target.tip { " (current)" } else { "" };
    anstream::eprintln!(
        "{}",
        format!(
            "{} {}{state} from the store-path index",
            target.attr, target.version
        )
        .style(output::muted())
    );
}

/// Substitute a store path, without evaluating anything to do it.
///
/// `nix-store --realise` takes a store path rather than an installable, which
/// is exactly the property the fast road is built on: the index already knows
/// the path, so nothing has to be evaluated to name it.
fn realise(store_path: &str) -> Result<()> {
    // Its progress goes to stderr, but it also echoes the realised path to
    // stdout, and `mvs run`'s stdout belongs to the program being run.
    let status = Command::new("nix-store")
        .args(["--realise", store_path])
        .stdout(std::process::Stdio::null())
        .status()
        .map_err(|e| {
            anyhow!(
                "could not run nix-store: {e}.\nThe fast path substitutes an indexed store \
                 path, so nix has to be on PATH. Use --eval for the evaluation path."
            )
        })?;

    if !status.success() {
        return Err(anyhow!(
            "{store_path} could not be substituted — the binary cache may have dropped it \
             since the last census. Retry with --eval to build it from its revision."
        ));
    }
    Ok(())
}

/// The executable to run out of a realised store path.
///
/// The index records no `meta.mainProgram`, so the name is recovered from the
/// realised path itself: the attribute, then the derivation's pname, then a
/// sole entry in `bin/`. That covers `hello`, `ripgrep` (whose binary is `rg`,
/// and its only one), and everything in between; a package with several
/// binaries and no obvious match is named rather than guessed at.
fn program_in(store_path: &str, target: &store::Target) -> Result<String> {
    let bin = format!("{store_path}/bin");
    let mut names: Vec<String> = std::fs::read_dir(&bin)
        .map_err(|_| {
            anyhow!(
                "{} {} has no bin/ directory, so there is nothing to run. \
                 `mvs shell {}` puts it on PATH instead.",
                target.attr,
                target.version,
                target.attr
            )
        })?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();

    for candidate in [Some(target.attr.as_str()), target.pname.as_deref()]
        .into_iter()
        .flatten()
    {
        if names.iter().any(|n| n == candidate) {
            return Ok(format!("{bin}/{candidate}"));
        }
    }

    if names.len() == 1 {
        return Ok(format!("{bin}/{}", names[0]));
    }

    Err(anyhow!(
        "{} {} ships several programs and none is named after it: {}.\nRun one with \
         `mvs shell {} -- <program>`.",
        target.attr,
        target.version,
        names.join(" "),
        target.attr
    ))
}

/// `mvs run <attr>[@ver] [-- args...]`
pub fn run(
    index: &Index,
    spec: &str,
    args: &[String],
    execute: Execute,
    speed: Speed,
) -> Result<()> {
    // The fast road: substitute the indexed path and exec it. No nixpkgs is
    // fetched and nothing is evaluated, so this is seconds rather than
    // minutes.
    if let Some(target) = fast_target(index, spec, speed) {
        report_fast(&target);
        if execute == Execute::No {
            println!("nix-store --realise {}", target.store_path);
            return Ok(());
        }

        realise(&target.store_path)?;
        let program = program_in(&target.store_path, &target)?;
        return exec_program(&program, args);
    }

    let (installable, version, label) = installable(index, spec)?;
    let attr = spec.split('@').next().unwrap_or(spec);

    let mut argv = vec!["run".to_string(), installable];
    if !args.is_empty() {
        argv.push("--".to_string());
        argv.extend(args.iter().cloned());
    }

    report(attr, &version, &label);
    exec(argv, execute)
}

/// `mvs shell <attr>[@ver]... [-- command args...]`
pub fn shell(
    index: &Index,
    specs: &[String],
    args: &[String],
    execute: Execute,
    speed: Speed,
) -> Result<()> {
    let mut argv = vec!["shell".to_string()];
    for spec in specs {
        // `nix shell` takes a store path as an installable, so a spec with an
        // indexed path skips its revision entirely. Specs mix freely: one
        // package can come from the index and the next from an evaluation.
        if let Some(target) = fast_target(index, spec, speed) {
            report_fast(&target);
            argv.push(target.store_path);
            continue;
        }

        let (installable, version, label) = installable(index, spec)?;
        report(spec.split('@').next().unwrap_or(spec), &version, &label);
        argv.push(installable);
    }

    if !args.is_empty() {
        // `--command` rather than a bare trailing argument: `nix shell` would
        // otherwise read the command as another installable.
        argv.push("--command".to_string());
        argv.extend(args.iter().cloned());
    }

    exec(argv, execute)
}

/// Hand over to a realised program on the fast road.
///
/// Replaces this process for the same reason `exec` below does: once the path
/// is substituted, `mvs` has no further part to play.
fn exec_program(program: &str, args: &[String]) -> Result<()> {
    use std::os::unix::process::CommandExt;
    let error = Command::new(program).args(args).exec();

    Err(anyhow!("could not execute {program}: {error}"))
}

/// Hand over to `nix`, or print the command line under `--dry-run`.
///
/// Replaces this process rather than waiting on a child, so signals, the exit
/// status and the terminal all belong to the program being run — `mvs run` is
/// meant to be invisible once it has resolved the revision.
fn exec(argv: Vec<String>, execute: Execute) -> Result<()> {
    if execute == Execute::No {
        println!("nix {}", argv.join(" "));
        return Ok(());
    }

    use std::os::unix::process::CommandExt;
    let error = Command::new("nix").args(&argv).exec();

    Err(anyhow!(
        "could not run nix: {error}.\n`mvs run` and `mvs shell` are wrappers around \
         `nix run` and `nix shell`, so nix has to be on PATH."
    ))
}

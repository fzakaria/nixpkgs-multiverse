//! `mvs` — read the multiverse index.
//!
//! Offline and read-only: every answer comes from the database baked into this
//! binary's own store path at build time. Growing the index is `tools/*.sh`'s
//! job, and a newer index arrives through `nix flake update multiverse`, which
//! rebuilds the database and rewraps the binary — so two people running the
//! same `nix run` get the same answers.

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};

use mvs::db::Index;
use mvs::lock;
use mvs::query::{self, Format};
use mvs::run::{self, Execute, Speed};
use mvs::solve;
use mvs::store;

#[derive(Parser)]
#[command(
    name = "mvs",
    about = "Read the nixpkgs multiverse index",
    long_about = "Read the nixpkgs multiverse index: versions, lifetimes, revision selection \
                  and constraint solving, offline and without materialising a revision.",
    version
)]
struct Cli {
    /// Index database to read. Defaults to $MVS_DB, which the Nix wrapper sets.
    #[arg(long, global = true, value_name = "PATH")]
    db: Option<PathBuf>,

    /// Machine-readable output.
    #[arg(long, global = true)]
    json: bool,

    /// Lock file to read and write. Defaults to ./multiverse.lock.
    #[arg(long, global = true, value_name = "PATH")]
    file: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Read-only questions about the index
    #[command(subcommand)]
    Query(Query),

    /// Find one revision satisfying every constraint at once
    ///
    /// Each constraint is `attr` or `attr@version`, where the version is a
    /// prefix matched component by component: `python3@3.8` accepts 3.8.9 and
    /// refuses 3.81.
    Solve {
        #[arg(value_name = "ATTR[@VERSION]", required = true)]
        constraints: Vec<String>,
    },

    /// Run a package, straight out of the binary cache where possible
    ///
    /// `mvs run ripgrep@13.0.0 -- --version`. The store-path index knows
    /// which /nix/store path the version built to, so the default path
    /// substitutes it and runs it — no nixpkgs fetch, no evaluation. A
    /// version the index never matched falls back to fetching and evaluating
    /// its revision, which --eval also forces.
    Run {
        #[arg(value_name = "ATTR[@VERSION]")]
        spec: String,

        /// Arguments for the program itself
        #[arg(last = true)]
        args: Vec<String>,

        /// Fetch and evaluate the revision instead of substituting the
        /// indexed store path
        #[arg(long)]
        eval: bool,

        /// Print the command line instead of running it
        #[arg(long)]
        dry_run: bool,
    },

    /// A shell with packages from the revisions that shipped them
    ///
    /// A wrapper around `nix shell`, taking indexed store paths where the
    /// index has them and evaluated revisions where it does not — the two mix
    /// freely within one shell. Composing across revisions is right for
    /// standalone tools and wrong for a development environment — for that,
    /// `mvs solve` gives one coherent revision.
    Shell {
        #[arg(value_name = "ATTR[@VERSION]", required = true)]
        specs: Vec<String>,

        /// Command to run in the shell, instead of an interactive one
        #[arg(last = true)]
        args: Vec<String>,

        /// Fetch and evaluate the revisions instead of substituting the
        /// indexed store paths
        #[arg(long)]
        eval: bool,

        /// Print the nix command line instead of running it
        #[arg(long)]
        dry_run: bool,
    },

    /// Print the /nix/store path of a version
    ///
    /// The digest comes straight out of the index, so nothing is evaluated or
    /// fetched: `nix-store --realise $(mvs path hello@2.12.2)` materialises
    /// the path from the binary cache with zero evaluation. When several
    /// versions match, the one current at the tip wins, then the newest.
    /// Needs a database built with store-path data (--data-dir).
    Path {
        #[arg(value_name = "ATTR[@VERSION]")]
        spec: String,
    },

    /// NAR, download and closure sizes of a version
    ///
    /// Also lists the sibling outputs of a multi-output package. Needs a
    /// database built with store-path data.
    Size {
        #[arg(value_name = "ATTR[@VERSION]")]
        spec: String,
    },

    /// Direct references of a version's store path
    ///
    /// Each reference is tied back to an indexed package where possible — by
    /// digest when the exact path is some pair's, by store name when the same
    /// package came out of another revision. Needs a database built with
    /// store-path data.
    Deps {
        #[arg(value_name = "ATTR[@VERSION]")]
        spec: String,
    },

    /// Indexed packages whose store paths reference this version
    ///
    /// The reverse of deps, matched by digest and by store name. Needs a
    /// database built with store-path data.
    Rdeps {
        #[arg(value_name = "ATTR[@VERSION]")]
        spec: String,
    },

    /// Which package a store path belongs to
    ///
    /// Accepts a full /nix/store path, a basename, or a bare 32-character
    /// digest. Needs a database built with store-path data.
    Identify {
        #[arg(value_name = "STORE-PATH|DIGEST")]
        target: String,
    },

    /// Per-package pins in multiverse.lock
    ///
    /// A pin can never point past what the index knows, so moving one is two
    /// steps: `nix flake update multiverse` to learn about newer revisions,
    /// then `mvs lock update <attr>` to move that one package.
    #[command(subcommand)]
    Lock(Lock),
}

#[derive(Subcommand)]
enum Lock {
    /// Pin a package to the newest indexed revision providing it
    Add {
        #[arg(value_name = "ATTR[@VERSION]")]
        spec: String,
    },

    /// Remove a pin
    Rm { attr: String },

    /// Move one pin — or every pin — to the newest indexed revision
    Update {
        attr: Option<String>,

        /// Move every pin
        #[arg(long)]
        all: bool,
    },

    /// Show the pins
    List,

    /// How far behind each pin has fallen
    Status,
}

/// A *selector* names a revision: `tip`, a release (`26.05`), a date
/// (`2022-03-15`), a commit prefix, or a revision label
/// (`2021-07-18-967d40bec14b`).
#[derive(Subcommand)]
enum Query {
    /// Every version of an attribute, oldest first, with its lifetime
    Versions { attr: String },

    /// When a version was present: first and last sighting, every run, gaps
    When { attr: String, version: String },

    /// The version a revision shipped
    At { selector: String, attr: String },

    /// When an attribute was last seen, or whether it is still current
    Gone { attr: String },

    /// Resolve a selector to commit, date and label
    Rev { selector: String },

    /// Search attribute names
    Search {
        /// Substring, or a glob if it contains `*`, `?` or `[`
        pattern: String,

        #[arg(long, default_value_t = query::SEARCH_LIMIT)]
        limit: usize,
    },

    /// What changed between two revisions
    Diff {
        a: String,
        b: String,

        /// Entries to print per section; 0 for all
        #[arg(long, default_value_t = query::DIFF_LIMIT)]
        limit: usize,
    },

    /// Headline numbers about the index
    Stats,
}

fn main() {
    // Errors are the tool's own diagnostics rather than a panic trace: every
    // one of them is a sentence about the index or the selector, and the
    // caller is a person at a terminal.
    if let Err(err) = run() {
        anstream::eprintln!("mvs: {err:#}");
        std::process::exit(1);
    }
}

/// `--dry-run` as the enum the wrappers take, so a call site reads as what it
/// means rather than as a bare boolean.
fn execute(dry_run: bool) -> Execute {
    if dry_run {
        Execute::No
    } else {
        Execute::Yes
    }
}

/// `--eval` as the enum the wrappers take, for the same reason.
fn speed(eval: bool) -> Speed {
    if eval {
        Speed::Eval
    } else {
        Speed::Fast
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let index = Index::open(cli.db.as_deref())?;
    let format = if cli.json {
        Format::Json
    } else {
        Format::Human
    };

    match &cli.command {
        Command::Query(q) => match q {
            Query::Versions { attr } => query::versions(&index, attr, format),
            Query::When { attr, version } => query::when(&index, attr, version, format),
            Query::At { selector, attr } => query::at(&index, selector, attr, format),
            Query::Gone { attr } => query::gone(&index, attr, format),
            Query::Rev { selector } => query::rev(&index, selector, format),
            Query::Search { pattern, limit } => query::search(&index, pattern, *limit, format),
            Query::Diff { a, b, limit } => query::diff(&index, a, b, *limit, format),
            Query::Stats => query::stats(&index, format),
        },
        Command::Solve { constraints } => solve::solve(&index, constraints, format),
        Command::Run {
            spec,
            args,
            eval,
            dry_run,
        } => run::run(&index, spec, args, execute(*dry_run), speed(*eval)),
        Command::Shell {
            specs,
            args,
            eval,
            dry_run,
        } => run::shell(&index, specs, args, execute(*dry_run), speed(*eval)),
        Command::Path { spec } => store::path(&index, spec, format),
        Command::Size { spec } => store::size(&index, spec, format),
        Command::Deps { spec } => store::deps(&index, spec, format),
        Command::Rdeps { spec } => store::rdeps(&index, spec, format),
        Command::Identify { target } => store::identify(&index, target, format),
        Command::Lock(l) => {
            let path = lock::lock_path(cli.file.as_deref());
            match l {
                Lock::Add { spec } => lock::add(&index, &path, spec, format),
                Lock::Rm { attr } => lock::remove(&path, attr, format),
                Lock::Update { attr, all } => {
                    lock::update(&index, &path, attr.as_deref(), *all, format)
                }
                Lock::List => lock::list(&path, format),
                Lock::Status => lock::status(&index, &path, format),
            }
        }
    }
}

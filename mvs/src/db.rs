//! The index, as `mvs` sees it: a SQLite database baked into the binary's own
//! store path at build time.
//!
//! Resolution is deliberately trivial — `--db` for development, otherwise
//! `$MVS_DB`, which the wrapper always sets. No cache directory, no fallback
//! chain, no network. The data version is the flake version.

use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use rusqlite::Connection;
use serde::Serialize;

/// The environment variable the Nix wrapper sets to the database's store path.
pub const DB_ENV: &str = "MVS_DB";

/// Where store paths live. Joined with `<digest>-<name>` to print a full path.
pub const STORE_DIR: &str = "/nix/store";

/// The meta key build-db.py writes when it was given `--data-dir`. Its absence
/// is how a database without the store tables says so, and the store
/// subcommands check it rather than probing for tables.
const STORE_META_KEY: &str = "store_paths";

/// How many values one `IN (…)` list carries. Well under SQLite's variable
/// limit, and each chunk is one scan of the table it filters.
const SQL_IN_CHUNK: usize = 900;

/// How many characters of a commit hash a revision label carries. The same 12
/// as `multiverse.nix`, so a label printed here feeds straight back into
/// `nix build .#<label>.<attr>`.
pub const LABEL_HASH_LEN: usize = 12;

/// One indexed revision of nixpkgs.
#[derive(Debug, Clone, Serialize)]
pub struct Revision {
    /// Offset into revisions.json — the join key for everything else, and the
    /// only ordering that matters, since revisions are date-ordered.
    pub off: i64,
    pub rev: String,
    pub date: String,
    /// The channel's own name for it, e.g. `nixos-26.05pre…`. Absent for
    /// release commits.
    pub name: Option<String>,
    pub narhash: Option<String>,
    /// `YYYY-MM-DD-<12 hex>`, the handle every other command accepts back.
    pub label: String,
}

/// A release channel's current tip, out of releases.json.
#[derive(Debug, Clone, Serialize)]
pub struct Release {
    pub name: String,
    pub rev: String,
    pub date: String,
    pub build: Option<i64>,
    pub channel_name: Option<String>,
}

/// An unbroken stretch of revisions over which an attribute held one version.
#[derive(Debug, Clone, Serialize)]
pub struct Run {
    pub version: String,
    pub first: i64,
    pub last: i64,
}

/// One interned store path: a digest, and the name after the dash when any
/// source of the data knew it.
#[derive(Debug, Clone, Serialize)]
pub struct StorePath {
    /// Row id, the integer every reference edge carries.
    #[serde(skip)]
    pub id: i64,
    pub digest: String,
    pub name: Option<String>,
}

impl StorePath {
    /// `<digest>-<name>`, or the bare digest for a path whose name was never
    /// seen.
    pub fn basename(&self) -> String {
        match &self.name {
            Some(name) => format!("{}-{name}", self.digest),
            None => self.digest.clone(),
        }
    }

    /// The full `/nix/store/…` path.
    pub fn store_path(&self) -> String {
        format!("{STORE_DIR}/{}", self.basename())
    }
}

/// An (attr, version) pair matched to the store path it built to.
#[derive(Debug, Clone, Serialize)]
pub struct PairPath {
    pub attr: String,
    pub version: String,
    #[serde(flatten)]
    pub path: StorePath,
    /// True when the pair is current at the index tip.
    pub tip: bool,
    /// Offset the digest was found at, when older than the pair's newest run.
    pub found_off: Option<i64>,
}

/// Cache facts about one store path. Every field is optional: the narinfo and
/// the closure walk are separate artifacts, and either can be missing.
#[derive(Debug, Clone, Serialize)]
pub struct PathDetails {
    /// True while the path is still downloadable from the binary cache.
    pub live: Option<bool>,
    /// Unpacked NAR bytes.
    pub nar_size: Option<i64>,
    /// Compressed download bytes.
    pub file_size: Option<i64>,
    pub closure_bytes: Option<i64>,
    pub closure_paths: Option<i64>,
    /// Closure members no longer in the cache.
    pub closure_dead: Option<i64>,
}

/// A sibling output of a multi-output package: cups-2.4.2's `dev`, `lib`, …
#[derive(Debug, Clone, Serialize)]
pub struct SiblingOutput {
    pub suffix: String,
    #[serde(flatten)]
    pub path: StorePath,
    pub nar_size: Option<i64>,
}

pub struct Index {
    conn: Connection,
    /// Number of revisions the history was built against. Runs index into this
    /// prefix, so it — not the length of revisions.json — is what "still
    /// current" is measured against.
    covered: i64,
}

impl Index {
    /// Open the database named by `--db`, or by `$MVS_DB` if that is unset.
    pub fn open(explicit: Option<&Path>) -> Result<Index> {
        let path: PathBuf = match explicit {
            Some(p) => p.to_path_buf(),
            None => std::env::var_os(DB_ENV).map(PathBuf::from).ok_or_else(|| {
                anyhow!(
                    "no index database: ${DB_ENV} is unset and --db was not given.\n\
                         The wrapper built by `nix build .#mvs` always sets it; running the \
                         binary directly needs `--db $(nix build --no-link --print-out-paths \
                         .#index-db)`."
                )
            })?,
        };

        if !path.exists() {
            return Err(anyhow!("index database {} does not exist", path.display()));
        }

        // Read-only, and not merely by convention: this is a store path, and
        // opening it read-write would try to create a -wal beside it.
        let conn = Connection::open_with_flags(
            &path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )
        .with_context(|| format!("opening index database {}", path.display()))?;

        let covered: i64 = conn
            .query_row(
                "SELECT value FROM meta WHERE key = 'revisionCount'",
                [],
                |r| r.get::<_, String>(0),
            )
            .context("reading revisionCount from the index database")?
            .parse()
            .context("revisionCount is not a number")?;

        Ok(Index { conn, covered })
    }

    /// The newest offset the history index covers. Runs never point past it,
    /// and a version whose run ends here is still current.
    pub fn covered_tip(&self) -> i64 {
        self.covered - 1
    }

    pub fn meta(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |r| r.get(0))
            .ok())
    }

    fn revision_from_row(row: &rusqlite::Row) -> rusqlite::Result<Revision> {
        let off: i64 = row.get(0)?;
        let rev: String = row.get(1)?;
        let date: String = row.get(2)?;
        let label = format!("{date}-{}", &rev[..LABEL_HASH_LEN]);
        Ok(Revision {
            off,
            rev,
            date,
            name: row.get(3)?,
            narhash: row.get(4)?,
            label,
        })
    }

    const REVISION_COLUMNS: &'static str = "off, rev, date, name, narhash";

    pub fn revision(&self, off: i64) -> Result<Revision> {
        let sql = format!(
            "SELECT {} FROM revisions WHERE off = ?1",
            Self::REVISION_COLUMNS
        );
        self.conn
            .query_row(&sql, [off], Self::revision_from_row)
            .with_context(|| format!("no revision at offset {off}"))
    }

    /// First revision whose commit hash starts with `prefix`.
    pub fn revision_by_prefix(&self, prefix: &str) -> Result<Option<Revision>> {
        let sql = format!(
            "SELECT {} FROM revisions WHERE rev >= ?1 AND rev < ?1 || 'g' ORDER BY off LIMIT 1",
            Self::REVISION_COLUMNS
        );
        Ok(self
            .conn
            .query_row(&sql, [prefix], Self::revision_from_row)
            .ok())
    }

    /// Newest revision dated on or before `date`, which is what a date selector
    /// means: the tree you would have got that day.
    pub fn revision_on_or_before(&self, date: &str) -> Result<Option<Revision>> {
        let sql = format!(
            "SELECT {} FROM revisions WHERE date <= ?1 ORDER BY off DESC LIMIT 1",
            Self::REVISION_COLUMNS
        );
        Ok(self
            .conn
            .query_row(&sql, [date], Self::revision_from_row)
            .ok())
    }

    /// What `tip` resolves to: the newest revision that can actually be
    /// materialised. A revision appended by fetch-unstable-revisions.sh has no
    /// narHash until build-index.sh reaches it, and nothing should land on one
    /// by walking off the end.
    pub fn tip(&self) -> Result<Revision> {
        let sql = format!(
            "SELECT {} FROM revisions WHERE narhash IS NOT NULL ORDER BY off DESC LIMIT 1",
            Self::REVISION_COLUMNS
        );
        self.conn
            .query_row(&sql, [], Self::revision_from_row)
            .context("no revision has a narHash; run tools/build-index.sh")
    }

    /// Newest offset in `first ..= last` that can actually be materialised.
    ///
    /// A revision appended by fetch-unstable-revisions.sh has no narHash until
    /// build-index.sh reaches it, and a pin naming one would resolve to a
    /// revision Nix cannot fetch.
    pub fn newest_materialisable_in(&self, first: i64, last: i64) -> Result<Option<i64>> {
        Ok(self.conn.query_row(
            "SELECT max(off) FROM revisions WHERE narhash IS NOT NULL AND off BETWEEN ?1 AND ?2",
            [first, last],
            |r| r.get::<_, Option<i64>>(0),
        )?)
    }

    pub fn release(&self, name: &str) -> Result<Option<Release>> {
        Ok(self
            .conn
            .query_row(
                "SELECT name, rev, date, build, channel_name FROM releases WHERE name = ?1",
                [name],
                |row| {
                    Ok(Release {
                        name: row.get(0)?,
                        rev: row.get(1)?,
                        date: row.get(2)?,
                        build: row.get(3)?,
                        channel_name: row.get(4)?,
                    })
                },
            )
            .ok())
    }

    /// Every run of every version of one attribute, oldest first.
    ///
    /// The primary key is (attr_id, version, first), so this is a range scan
    /// over one attribute's slice of the table.
    pub fn runs_of(&self, attr: &str) -> Result<Vec<Run>> {
        let mut stmt = self.conn.prepare(
            "SELECT runs.version, runs.first, runs.last
               FROM runs JOIN attrs ON attrs.id = runs.attr_id
              WHERE attrs.name = ?1
              ORDER BY runs.first",
        )?;
        let runs = stmt
            .query_map([attr], |row| {
                Ok(Run {
                    version: row.get(0)?,
                    first: row.get(1)?,
                    last: row.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(runs)
    }

    /// Whether the index has ever seen this attribute. Distinguishes "never in
    /// nixpkgs" from "in nixpkgs but gone", which are different answers.
    pub fn knows_attr(&self, attr: &str) -> Result<bool> {
        Ok(self
            .conn
            .query_row("SELECT 1 FROM attrs WHERE name = ?1", [attr], |_| Ok(()))
            .is_ok())
    }

    /// Every attribute and version present at one revision.
    ///
    /// A full scan of the runs table, on purpose: see the schema comment in
    /// build-db.py for why the index that would avoid it is not worth 5 MB.
    pub fn snapshot(&self, off: i64) -> Result<Vec<(String, String)>> {
        let mut stmt = self.conn.prepare(
            "SELECT attrs.name, runs.version
               FROM runs JOIN attrs ON attrs.id = runs.attr_id
              WHERE runs.first <= ?1 AND runs.last >= ?1",
        )?;
        let rows = stmt
            .query_map([off], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Attributes matching a GLOB pattern. A pattern without wildcards is
    /// treated as a substring search, which is what people mean by `mvs query
    /// search python`.
    pub fn search(&self, pattern: &str, limit: usize) -> Result<Vec<String>> {
        let glob = if pattern.contains(['*', '?', '[']) {
            pattern.to_string()
        } else {
            format!("*{pattern}*")
        };

        let mut stmt = self
            .conn
            .prepare("SELECT name FROM attrs WHERE name GLOB ?1 ORDER BY name LIMIT ?2")?;
        let names = stmt
            .query_map(rusqlite::params![glob, limit as i64], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(names)
    }

    /// Case-insensitive fallback for a search that found nothing: GLOB is
    /// case-sensitive, and half of nixpkgs is lowercase while the half people
    /// type is not.
    pub fn search_nocase(&self, pattern: &str, limit: usize) -> Result<Vec<String>> {
        let like = if pattern.contains(['%', '_']) {
            pattern.to_string()
        } else {
            format!("%{pattern}%")
        };

        let mut stmt = self
            .conn
            .prepare("SELECT name FROM attrs WHERE name LIKE ?1 ORDER BY name LIMIT ?2")?;
        let names = stmt
            .query_map(rusqlite::params![like, limit as i64], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(names)
    }

    // ------ store-path data, present only when the database was built with
    // ------ `build-db.py --data-dir` (see STORE_SCHEMA there)

    /// Whether the store-path tables exist in this database.
    pub fn has_store_data(&self) -> bool {
        matches!(self.meta(STORE_META_KEY), Ok(Some(_)))
    }

    /// The guard every store subcommand runs first, so a database built
    /// without the artifacts refuses with a sentence rather than a missing-
    /// table error.
    pub fn require_store_data(&self) -> Result<()> {
        if self.has_store_data() {
            return Ok(());
        }
        Err(anyhow!(
            "this database was built without store-path data, so `mvs path`, `size`, `deps`, \
             `rdeps` and `identify` have nothing to answer from.\nRebuild it with \
             `build-db.py <root> <out> --data-dir <dir>`, where the directory holds \
             outpaths.json, tip-outpaths.json and the *-indexed artifacts."
        ))
    }

    /// The columns every pair query selects, kept in one place like
    /// REVISION_COLUMNS above.
    const PAIR_COLUMNS: &'static str = "attrs.name, pairs.version, store_paths.id, \
         store_paths.digest, store_names.name, pairs.tip, pairs.found_off";

    const PAIR_JOINS: &'static str = "FROM pairs \
         JOIN attrs ON attrs.id = pairs.attr_id \
         JOIN store_paths ON store_paths.id = pairs.path_id \
         LEFT JOIN store_names ON store_names.id = store_paths.name_id";

    fn pair_from_row(row: &rusqlite::Row) -> rusqlite::Result<PairPath> {
        Ok(PairPath {
            attr: row.get(0)?,
            version: row.get(1)?,
            path: StorePath {
                id: row.get(2)?,
                digest: row.get(3)?,
                name: row.get(4)?,
            },
            tip: row.get::<_, i64>(5)? != 0,
            found_off: row.get(6)?,
        })
    }

    /// Every version of one attribute whose store path is known.
    pub fn store_pairs_of(&self, attr: &str) -> Result<Vec<PairPath>> {
        let sql = format!(
            "SELECT {} {} WHERE attrs.name = ?1",
            Self::PAIR_COLUMNS,
            Self::PAIR_JOINS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let pairs = stmt
            .query_map([attr], Self::pair_from_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(pairs)
    }

    /// The pairs built to any of these store paths — how a digest resolves
    /// back to (attr, version). Chunked so the id list stays under SQLite's
    /// variable limit; each chunk is a scan of the pairs table.
    pub fn pairs_by_path_ids(&self, ids: &[i64]) -> Result<Vec<PairPath>> {
        let mut pairs = Vec::new();
        for chunk in ids.chunks(SQL_IN_CHUNK) {
            let marks = vec!["?"; chunk.len()].join(",");
            let sql = format!(
                "SELECT {} {} WHERE pairs.path_id IN ({marks})",
                Self::PAIR_COLUMNS,
                Self::PAIR_JOINS
            );
            let mut stmt = self.conn.prepare(&sql)?;
            let found = stmt
                .query_map(rusqlite::params_from_iter(chunk), Self::pair_from_row)?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            pairs.extend(found);
        }
        Ok(pairs)
    }

    /// The store path with this digest, if the index has ever seen it.
    ///
    /// A scan: store_paths carries no digest index on purpose — it would cost
    /// 36 MB to serve this one lookup per `mvs identify`.
    pub fn store_path_by_digest(&self, digest: &str) -> Result<Option<StorePath>> {
        Ok(self
            .conn
            .query_row(
                "SELECT store_paths.id, store_paths.digest, store_names.name
                   FROM store_paths
                   LEFT JOIN store_names ON store_names.id = store_paths.name_id
                  WHERE store_paths.digest = ?1",
                [digest],
                |row| {
                    Ok(StorePath {
                        id: row.get(0)?,
                        digest: row.get(1)?,
                        name: row.get(2)?,
                    })
                },
            )
            .ok())
    }

    /// Ids of every store path with one of these names — the same package
    /// built by other revisions to other digests. One scan for the whole list.
    pub fn store_path_ids_named(&self, names: &[String]) -> Result<Vec<(i64, String)>> {
        let mut ids = Vec::new();
        for chunk in names.chunks(SQL_IN_CHUNK) {
            let marks = vec!["?"; chunk.len()].join(",");
            let sql = format!(
                "SELECT store_paths.id, store_names.name
                   FROM store_paths
                   JOIN store_names ON store_names.id = store_paths.name_id
                  WHERE store_names.name IN ({marks})"
            );
            let mut stmt = self.conn.prepare(&sql)?;
            let found = stmt
                .query_map(rusqlite::params_from_iter(chunk), |row| {
                    Ok((row.get(0)?, row.get(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            ids.extend(found);
        }
        Ok(ids)
    }

    /// Cache facts for one store path, or `None` when neither the narinfo nor
    /// the closure artifacts covered it.
    pub fn path_details(&self, path_id: i64) -> Result<Option<PathDetails>> {
        Ok(self
            .conn
            .query_row(
                "SELECT live, nar_size, file_size, closure_bytes, closure_paths, closure_dead
                   FROM path_info WHERE path_id = ?1",
                [path_id],
                |row| {
                    Ok(PathDetails {
                        live: row.get::<_, Option<i64>>(0)?.map(|v| v != 0),
                        nar_size: row.get(1)?,
                        file_size: row.get(2)?,
                        closure_bytes: row.get(3)?,
                        closure_paths: row.get(4)?,
                        closure_dead: row.get(5)?,
                    })
                },
            )
            .ok())
    }

    /// Direct references of one store path, name attached where known.
    pub fn refs_of_path(&self, path_id: i64) -> Result<Vec<StorePath>> {
        let mut stmt = self.conn.prepare(
            "SELECT store_paths.id, store_paths.digest, store_names.name
               FROM path_refs
               JOIN store_paths ON store_paths.id = path_refs.dst
               LEFT JOIN store_names ON store_names.id = store_paths.name_id
              WHERE path_refs.src = ?1",
        )?;
        let refs = stmt
            .query_map([path_id], |row| {
                Ok(StorePath {
                    id: row.get(0)?,
                    digest: row.get(1)?,
                    name: row.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(refs)
    }

    /// Ids of every store path whose references include one of `dst_ids`.
    ///
    /// One pass over the whole edge table, filtered here: path_refs carries no
    /// dst index on purpose, and a single scan beats one indexed probe per id
    /// once the id set grows.
    pub fn referrers_of(&self, dst_ids: &std::collections::HashSet<i64>) -> Result<Vec<i64>> {
        let mut stmt = self.conn.prepare("SELECT src, dst FROM path_refs")?;
        let mut srcs = std::collections::HashSet::new();
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let dst: i64 = row.get(1)?;
            if dst_ids.contains(&dst) {
                srcs.insert(row.get::<_, i64>(0)?);
            }
        }

        let mut out: Vec<i64> = srcs.into_iter().collect();
        out.sort();
        Ok(out)
    }

    /// The sibling outputs recorded for one derivation name, suffix order.
    pub fn outputs_of(&self, drv_name: &str) -> Result<Vec<SiblingOutput>> {
        let mut stmt = self.conn.prepare(
            "SELECT outputs.suffix, store_paths.id, store_paths.digest, path_names.name,
                    outputs.nar_size
               FROM outputs
               JOIN store_names AS drv ON drv.id = outputs.drv_name_id
               JOIN store_paths ON store_paths.id = outputs.path_id
               LEFT JOIN store_names AS path_names ON path_names.id = store_paths.name_id
              WHERE drv.name = ?1
              ORDER BY outputs.suffix",
        )?;
        let outputs = stmt
            .query_map([drv_name], |row| {
                Ok(SiblingOutput {
                    suffix: row.get(0)?,
                    path: StorePath {
                        id: row.get(1)?,
                        digest: row.get(2)?,
                        name: row.get(3)?,
                    },
                    nar_size: row.get(4)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(outputs)
    }

    /// Which derivation a store path is an output of: `(drv name, suffix)`
    /// rows, empty for a path that is no recorded sibling output.
    pub fn outputs_by_path_id(&self, path_id: i64) -> Result<Vec<(String, String)>> {
        let mut stmt = self.conn.prepare(
            "SELECT drv.name, outputs.suffix
               FROM outputs
               JOIN store_names AS drv ON drv.id = outputs.drv_name_id
              WHERE outputs.path_id = ?1",
        )?;
        let rows = stmt
            .query_map([path_id], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// The connection itself, for the queries that are built rather than
    /// written out — `solve` composes one EXISTS clause per constraint.
    pub fn connection(&self) -> &Connection {
        &self.conn
    }
}

/// Group a flat list of runs into one entry per version, oldest run first.
///
/// Two runs of the same version mean the version left and came back, which is
/// 8.4% of pairs in the index — hence runs at all rather than a newest offset.
pub fn group_by_version(runs: Vec<Run>) -> Vec<(String, Vec<Run>)> {
    let mut grouped: Vec<(String, Vec<Run>)> = Vec::new();
    for run in runs {
        match grouped.iter_mut().find(|(v, _)| *v == run.version) {
            Some((_, rs)) => rs.push(run),
            None => grouped.push((run.version.clone(), vec![run])),
        }
    }
    for (_, rs) in grouped.iter_mut() {
        rs.sort_by_key(|r| r.first);
    }
    grouped
}

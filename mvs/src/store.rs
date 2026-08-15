//! `mvs path`, `size`, `deps`, `rdeps` and `identify` — the store-path
//! surface of the index.
//!
//! These answer from the store tables build-db.py fills under `--data-dir`:
//! which `/nix/store` path an (attr, version) pair built to, how big it and
//! its closure are, what it references, and what references it. All of it
//! offline — the digest is in the database, so `nix-store --realise` on the
//! printed path fetches from the binary cache with no evaluation at all.
//!
//! A database built without the artifacts has none of these tables, and every
//! entry point here starts with [`Index::require_store_data`] so the refusal
//! is a sentence rather than a missing-table error.

use std::collections::{HashMap, HashSet};

use anyhow::{anyhow, Result};
use owo_colors::OwoColorize;
use serde_json::json;

use crate::db::{Index, PairPath};
use crate::output::{self, Cell, Table};
use crate::query::{self, Format};
use crate::solve::Constraint;
use crate::version;

/// The digest half of a store path basename: 32 characters of Nix base32.
const DIGEST_LEN: usize = 32;

/// Nix's base32 alphabet — 0-9 and lowercase letters minus e, o, u, t. A
/// candidate digest with any other character is a typo, not a digest.
const NIX32_ALPHABET: &str = "0123456789abcdfghijklmnpqrsvwxyz";

/// How a reference was tied back to an indexed package.
#[derive(Clone, Copy, PartialEq)]
enum MatchedBy {
    /// The reference is the exact store path an indexed pair built to.
    Digest,
    /// A path with the same store name is: the same package, built by some
    /// other revision to another digest.
    Name,
}

impl MatchedBy {
    fn label(self) -> &'static str {
        match self {
            MatchedBy::Digest => "digest",
            MatchedBy::Name => "name",
        }
    }
}

/// Resolve `attr[@version]` to the one pair the store commands act on.
///
/// The version is matched the way every other command matches it — exact
/// first, then as a component-wise prefix — and when several versions
/// qualify, the pair current at the index tip wins, then the newest version.
pub fn resolve_pair(index: &Index, spec: &str) -> Result<PairPath> {
    let constraint = Constraint::parse(spec)?;
    let pairs = index.store_pairs_of(&constraint.attr)?;

    // No pair at all: distinguish an attribute the index never saw from one
    // it knows but has no store path for.
    if pairs.is_empty() {
        if index.runs_of(&constraint.attr)?.is_empty() {
            return Err(query::unknown_attr(index, &constraint.attr)?);
        }
        return Err(anyhow!(
            "the index knows {} but no store path was recorded for it — its versions never \
             matched a cached build.",
            constraint.attr
        ));
    }

    let candidates = matching_pairs(pairs, constraint.version.as_deref());
    if candidates.is_empty() {
        let mut known: Vec<String> = index
            .store_pairs_of(&constraint.attr)?
            .into_iter()
            .map(|p| p.version)
            .collect();
        version::sort(&mut known);
        return Err(anyhow!(
            "no store path is indexed for {}.\nVersions with one: {}",
            constraint.describe(),
            known.join(" ")
        ));
    }

    Ok(choose_pair(candidates))
}

/// The pairs a version spec selects: exact matches when there are any,
/// otherwise component-wise prefix matches, everything when no version was
/// given.
fn matching_pairs(pairs: Vec<PairPath>, wanted: Option<&str>) -> Vec<PairPath> {
    let Some(wanted) = wanted else {
        return pairs;
    };

    let exact: Vec<PairPath> = pairs
        .iter()
        .filter(|p| p.version == wanted)
        .cloned()
        .collect();
    if !exact.is_empty() {
        return exact;
    }

    pairs
        .into_iter()
        .filter(|p| crate::solve::matches(&p.version, wanted))
        .collect()
}

/// One pair out of several candidates: the tip pair if any, else the newest
/// version — the same "newest that satisfies" rule `mvs run` resolves by.
fn choose_pair(mut candidates: Vec<PairPath>) -> PairPath {
    candidates.sort_by(|a, b| {
        a.tip
            .cmp(&b.tip)
            .then(version::compare(&a.version, &b.version))
    });
    candidates
        .pop()
        .expect("choose_pair takes a non-empty list")
}

/// What a pair resolved to, on stderr so stdout stays the answer alone —
/// `mvs path` output feeds command substitution.
fn report(pair: &PairPath) {
    let state = if pair.tip { " (current)" } else { "" };
    anstream::eprintln!(
        "{}",
        format!("{} {}{state}", pair.attr, pair.version).style(output::muted())
    );
}

/// The pname half of a derivation name: everything before the first dash that
/// is followed by a digit, which is how Nix itself splits one.
fn pname_of(name: &str) -> &str {
    let bytes = name.as_bytes();
    for (i, w) in bytes.windows(2).enumerate() {
        if w[0] == b'-' && w[1].is_ascii_digit() {
            return &name[..i];
        }
    }
    name
}

/// What `mvs run` and `mvs shell` need to take the fast road: the store path
/// to substitute, and the names to report and to look for under `bin/`.
pub struct Target {
    pub attr: String,
    pub version: String,
    pub store_path: String,
    /// The derivation's pname, which is the other plausible spelling of the
    /// program when it differs from the attribute (`ripgrep` builds `rg`, but
    /// `python3` builds `python3`).
    pub pname: Option<String>,
    pub tip: bool,
}

/// Resolve a spec to its indexed store path, for callers that execute rather
/// than print. Errors exactly as the store subcommands do.
pub fn target(index: &Index, spec: &str) -> Result<Target> {
    let pair = resolve_pair(index, spec)?;
    let pname = pair.path.name.as_deref().map(pname_of).map(str::to_string);

    Ok(Target {
        attr: pair.attr,
        version: pair.version,
        store_path: pair.path.store_path(),
        pname,
        tip: pair.tip,
    })
}

/// `mvs path <attr>[@version]` — the bare `/nix/store` path.
pub fn path(index: &Index, spec: &str, format: Format) -> Result<()> {
    index.require_store_data()?;
    let pair = resolve_pair(index, spec)?;

    if format == Format::Json {
        return output::print_json(json!({
            "attr": pair.attr,
            "version": pair.version,
            "digest": pair.path.digest,
            "name": pair.path.name,
            "store_path": pair.path.store_path(),
            "tip": pair.tip,
        }));
    }

    report(&pair);
    println!("{}", pair.path.store_path());
    Ok(())
}

/// `mvs size <attr>[@version]` — NAR, download and closure sizes.
pub fn size(index: &Index, spec: &str, format: Format) -> Result<()> {
    index.require_store_data()?;
    let pair = resolve_pair(index, spec)?;
    let details = index.path_details(pair.path.id)?;

    // Sibling outputs hang off the derivation name, which is the store name
    // of the pair's own path.
    let outputs = match &pair.path.name {
        Some(name) => index.outputs_of(name)?,
        None => Vec::new(),
    };

    if format == Format::Json {
        return output::print_json(json!({
            "attr": pair.attr,
            "version": pair.version,
            "store_path": pair.path.store_path(),
            "tip": pair.tip,
            "details": details,
            "outputs": outputs,
        }));
    }

    anstream::println!(
        "{} {} · {}",
        pair.attr,
        pair.version,
        pair.path.store_path()
    );

    let Some(details) = details else {
        anstream::println!(
            "{}",
            "  no cache data recorded for this path".style(output::muted())
        );
        return Ok(());
    };

    // One line per fact, "unknown" where the artifact had nothing — absence
    // is an answer here, not something to hide.
    let unknown = || "unknown".to_string();
    anstream::println!(
        "  nar (unpacked)  {}",
        details.nar_size.map(output::bytes).unwrap_or_else(unknown)
    );
    anstream::println!(
        "  download        {}",
        details.file_size.map(output::bytes).unwrap_or_else(unknown)
    );

    match (details.closure_bytes, details.closure_paths) {
        (Some(bytes), Some(paths)) => {
            let mut line = format!(
                "  closure         {} · {}",
                output::bytes(bytes),
                output::plural(paths as usize, "path")
            );
            if let Some(dead) = details.closure_dead.filter(|d| *d > 0) {
                line.push_str(&format!(" ({dead} no longer cached)"));
            }
            anstream::println!("{line}");
        }
        _ => anstream::println!("  closure         {}", unknown()),
    }

    match details.live {
        Some(true) => anstream::println!("  cache           {}", "live".style(output::current())),
        Some(false) => anstream::println!(
            "  cache           {}",
            "no longer downloadable".style(output::ended())
        ),
        None => anstream::println!("  cache           {}", unknown()),
    }

    if !outputs.is_empty() {
        anstream::println!("\n{}", "outputs".style(output::header_style()));
        let mut table = Table::new(&["SUFFIX", "NAR", "STORE PATH"]);
        for out in &outputs {
            table.row(vec![
                Cell::new(&out.suffix, output::plain()),
                Cell::new(
                    out.nar_size.map(output::bytes).unwrap_or_else(unknown),
                    output::muted(),
                ),
                Cell::new(out.path.store_path(), output::muted()),
            ]);
        }
        table.print();
    }
    Ok(())
}

/// Resolve a set of references back to indexed pairs: by digest where the
/// exact path is indexed, then by store name for the same package out of
/// another revision. Returns `path id -> (pairs, how)`.
fn resolve_refs(
    index: &Index,
    refs: &[crate::db::StorePath],
) -> Result<HashMap<i64, (Vec<PairPath>, MatchedBy)>> {
    let mut resolved: HashMap<i64, (Vec<PairPath>, MatchedBy)> = HashMap::new();

    // Digest matches first: the ref's path id is itself some pair's path id.
    let ids: Vec<i64> = refs.iter().map(|r| r.id).collect();
    for pair in index.pairs_by_path_ids(&ids)? {
        resolved
            .entry(pair.path.id)
            .or_insert_with(|| (Vec::new(), MatchedBy::Digest))
            .0
            .push(pair);
    }

    // Name fallback for the rest: gather every unresolved name, find all
    // paths carrying it, and map those back to pairs in one round trip.
    let unresolved: Vec<&crate::db::StorePath> = refs
        .iter()
        .filter(|r| !resolved.contains_key(&r.id) && r.name.is_some())
        .collect();
    let names: Vec<String> = unresolved
        .iter()
        .filter_map(|r| r.name.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();

    let named_ids = index.store_path_ids_named(&names)?;
    let name_of_id: HashMap<i64, String> = named_ids.iter().cloned().collect();
    let ids: Vec<i64> = named_ids.iter().map(|(id, _)| *id).collect();

    let mut pairs_of_name: HashMap<String, Vec<PairPath>> = HashMap::new();
    for pair in index.pairs_by_path_ids(&ids)? {
        if let Some(name) = name_of_id.get(&pair.path.id) {
            pairs_of_name.entry(name.clone()).or_default().push(pair);
        }
    }

    for reference in unresolved {
        let name = reference.name.as_ref().unwrap();
        if let Some(pairs) = pairs_of_name.get(name) {
            resolved.insert(reference.id, (pairs.clone(), MatchedBy::Name));
        }
    }
    Ok(resolved)
}

/// Unique `attr@version` strings for one resolved reference, attr order.
fn pair_labels(pairs: &[PairPath]) -> Vec<String> {
    let mut labels: Vec<String> = pairs
        .iter()
        .map(|p| format!("{}@{}", p.attr, p.version))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    labels.sort();
    labels
}

/// `mvs deps <attr>[@version]` — direct references, tied back to packages.
pub fn deps(index: &Index, spec: &str, format: Format) -> Result<()> {
    index.require_store_data()?;
    let pair = resolve_pair(index, spec)?;

    let mut refs = index.refs_of_path(pair.path.id)?;
    refs.sort_by(|a, b| a.basename().cmp(&b.basename()));
    let resolved = resolve_refs(index, &refs)?;

    if format == Format::Json {
        let entries: Vec<serde_json::Value> = refs
            .iter()
            .map(|r| {
                let matched = resolved.get(&r.id);
                json!({
                    "digest": r.digest,
                    "name": r.name,
                    "store_path": r.store_path(),
                    "packages": matched.map(|(pairs, _)| pair_labels(pairs)).unwrap_or_default(),
                    "matched_by": matched.map(|(_, how)| how.label()),
                })
            })
            .collect();
        return output::print_json(json!({
            "attr": pair.attr,
            "version": pair.version,
            "store_path": pair.path.store_path(),
            "refs": entries,
        }));
    }

    anstream::println!(
        "{} {} · {}",
        pair.attr,
        pair.version,
        output::plural(refs.len(), "direct reference")
    );

    let mut table = Table::new(&["REFERENCE", "PACKAGE", "VIA"]);
    for reference in &refs {
        let (package, via, style) = match resolved.get(&reference.id) {
            Some((pairs, how)) => (pair_labels(pairs).join(", "), how.label(), output::plain()),
            None => ("(not indexed)".to_string(), "", output::muted()),
        };
        table.row(vec![
            Cell::new(reference.basename(), output::plain()),
            Cell::new(package, style),
            Cell::new(via, output::muted()),
        ]);
    }
    table.print();
    Ok(())
}

/// `mvs rdeps <attr>[@version]` — indexed pairs whose references include this
/// pair's store path, or a same-named path from another revision.
pub fn rdeps(index: &Index, spec: &str, format: Format) -> Result<()> {
    index.require_store_data()?;
    let pair = resolve_pair(index, spec)?;

    // The targets: this pair's own path, plus every path sharing its store
    // name — a referrer out of another revision points at that revision's
    // digest of the same package.
    let mut targets: HashSet<i64> = HashSet::from([pair.path.id]);
    if let Some(name) = &pair.path.name {
        for (id, _) in index.store_path_ids_named(std::slice::from_ref(name))? {
            targets.insert(id);
        }
    }

    let referrers = index.referrers_of(&targets)?;
    let mut pairs = index.pairs_by_path_ids(&referrers)?;
    pairs.sort_by(|a, b| {
        a.attr
            .cmp(&b.attr)
            .then(version::compare(&a.version, &b.version))
    });

    // Referrers that are no pair's path — sibling outputs, plain dependency
    // paths — are counted rather than dropped silently.
    let pair_ids: HashSet<i64> = pairs.iter().map(|p| p.path.id).collect();
    let unindexed = referrers.iter().filter(|id| !pair_ids.contains(id)).count();

    if format == Format::Json {
        let entries: Vec<serde_json::Value> = pairs
            .iter()
            .map(|p| {
                json!({
                    "attr": p.attr,
                    "version": p.version,
                    "store_path": p.path.store_path(),
                    "tip": p.tip,
                })
            })
            .collect();
        return output::print_json(json!({
            "attr": pair.attr,
            "version": pair.version,
            "store_path": pair.path.store_path(),
            "rdeps": entries,
            "unindexed_referrers": unindexed,
        }));
    }

    anstream::println!(
        "{} {} · referenced by {}",
        pair.attr,
        pair.version,
        output::plural(pairs.len(), "indexed package")
    );

    let mut table = Table::new(&["ATTR", "VERSION", "STATUS"]);
    for p in &pairs {
        table.row(vec![
            Cell::new(&p.attr, output::plain()),
            Cell::new(&p.version, output::plain()),
            Cell::new(
                if p.tip { "current" } else { "" },
                if p.tip {
                    output::current()
                } else {
                    output::plain()
                },
            ),
        ]);
    }
    table.print();

    if unindexed > 0 {
        anstream::println!(
            "{}",
            format!(
                "  and {} not indexed as packages (outputs, dependencies)",
                output::plural(unindexed, "store path")
            )
            .style(output::muted())
        );
    }
    Ok(())
}

/// The digest inside a store path spelled any accepted way: a full
/// `/nix/store/…` path, a basename, or a bare 32-character digest.
pub fn digest_of(target: &str) -> Result<String> {
    // The basename is everything after the last slash, so a full path and a
    // basename collapse to the same case.
    let basename = target.rsplit('/').next().unwrap_or(target);
    let digest = basename.split('-').next().unwrap_or(basename);

    if digest.len() != DIGEST_LEN || !digest.chars().all(|c| NIX32_ALPHABET.contains(c)) {
        return Err(anyhow!(
            "{target} does not name a store path. Give a full /nix/store path, a basename \
             like <digest>-hello-2.12.2, or the bare {DIGEST_LEN}-character digest."
        ));
    }
    Ok(digest.to_string())
}

/// `mvs identify <store-path-or-digest>` — digest back to (attr, version).
pub fn identify(index: &Index, target: &str, format: Format) -> Result<()> {
    index.require_store_data()?;
    let digest = digest_of(target)?;

    let Some(path) = index.store_path_by_digest(&digest)? else {
        return Err(anyhow!(
            "the index has never seen a store path with digest {digest}. It only knows paths \
             reachable from indexed packages — one out of an unindexed revision is expected \
             to miss."
        ));
    };

    // Three answers, tried in order of usefulness: the pairs that built to
    // this exact path, the derivation it is a sibling output of, and — for a
    // path only ever seen as a reference — its name alone.
    let mut pairs = index.pairs_by_path_ids(&[path.id])?;
    pairs.sort_by(|a, b| a.attr.cmp(&b.attr));
    let outputs = index.outputs_by_path_id(path.id)?;

    if format == Format::Json {
        let packages: Vec<serde_json::Value> = pairs
            .iter()
            .map(|p| json!({ "attr": p.attr, "version": p.version, "tip": p.tip }))
            .collect();
        let output_entries: Vec<serde_json::Value> = outputs
            .iter()
            .map(|(drv, suffix)| json!({ "drv_name": drv, "suffix": suffix }))
            .collect();
        return output::print_json(json!({
            "digest": path.digest,
            "name": path.name,
            "store_path": path.store_path(),
            "packages": packages,
            "outputs": output_entries,
        }));
    }

    anstream::println!("{}", path.store_path());
    for p in &pairs {
        let state = if p.tip { " (current)" } else { "" };
        anstream::println!(
            "  package  {} {}{}",
            p.attr,
            p.version.clone().style(output::current()),
            state
        );
    }
    for (drv, suffix) in &outputs {
        anstream::println!("  output   {suffix} of {drv}");
    }
    if pairs.is_empty() && outputs.is_empty() {
        anstream::println!(
            "{}",
            "  a dependency path — nothing in the index builds to it directly"
                .style(output::muted())
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::StorePath;

    /// A pair for the pure-function tests below; only version and tip matter
    /// to the choosing logic.
    fn pair(version: &str, tip: bool) -> PairPath {
        PairPath {
            attr: "hello".to_string(),
            version: version.to_string(),
            path: StorePath {
                id: 1,
                digest: "0".repeat(DIGEST_LEN),
                name: None,
            },
            tip,
            found_off: None,
        }
    }

    /// Version selection: an exact match beats prefix matches, a prefix
    /// selects component-wise, and no version selects everything.
    #[test]
    fn selects_matching_versions() {
        let pairs = vec![
            pair("3.8", false),
            pair("3.8.9", false),
            pair("3.10.2", true),
        ];

        // "3.8" is both an exact version and a prefix of 3.8.9; exactness wins.
        let exact = matching_pairs(pairs.clone(), Some("3.8"));
        assert_eq!(exact.len(), 1);
        assert_eq!(exact[0].version, "3.8");

        // "3.1" is a component prefix of nothing here — not of 3.10.2.
        assert!(matching_pairs(pairs.clone(), Some("3.1")).is_empty());

        let prefix = matching_pairs(pairs.clone(), Some("3.10"));
        assert_eq!(prefix.len(), 1);
        assert_eq!(prefix[0].version, "3.10.2");

        assert_eq!(matching_pairs(pairs, None).len(), 3);
    }

    /// Choosing among candidates: the tip pair wins over a newer non-tip
    /// version, and without a tip the newest version wins.
    #[test]
    fn chooses_tip_then_newest() {
        let chosen = choose_pair(vec![pair("2.0", false), pair("1.0", true)]);
        assert_eq!(chosen.version, "1.0");

        let chosen = choose_pair(vec![pair("1.9", false), pair("1.10", false)]);
        assert_eq!(chosen.version, "1.10");
    }

    /// Digest extraction from every accepted spelling, and the rejections: a
    /// wrong length, and a character outside Nix's base32 alphabet.
    #[test]
    fn extracts_digests() {
        let digest = "8qi947kixhz1nw83dkwxm6d0wndprqkj";
        assert_eq!(digest_of(digest).unwrap(), digest);
        assert_eq!(
            digest_of(&format!("{digest}-hello-2.12.2")).unwrap(),
            digest
        );
        assert_eq!(
            digest_of(&format!("/nix/store/{digest}-hello-2.12.2")).unwrap(),
            digest
        );

        assert!(digest_of("too-short").is_err());
        // 'e' is not in Nix's base32 alphabet, so this 32-character string is
        // not a digest however plausible it looks.
        assert!(digest_of(&"e".repeat(DIGEST_LEN)).is_err());
        assert!(digest_of("").is_err());
    }

    /// Tests that a derivation name splits into the pname `mvs run` looks for
    /// under bin/, by feeding it the shapes the index actually holds: a
    /// dashed name, a name whose pname itself ends in a digit, one with no
    /// version at all, and one whose version is not the first dashed part.
    #[test]
    fn splits_pnames() {
        assert_eq!(pname_of("hello-2.12.2"), "hello");
        assert_eq!(pname_of("python3-3.8.9"), "python3");
        assert_eq!(pname_of("ripgrep-15.2.0"), "ripgrep");
        assert_eq!(pname_of("nix-info"), "nix-info");
        assert_eq!(pname_of("gcc-wrapper-13.2.0"), "gcc-wrapper");
    }
}

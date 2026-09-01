//! `mvs query` — everything read-only.
//!
//! Each subcommand answers one question the index can answer without
//! materialising a revision. `query at` is the sharpest example: it says what
//! version nixpkgs shipped on a given date, where reading it off the package
//! set costs a ~378 MB fetch of the whole tree to look at one `.version`.

use anyhow::{anyhow, Result};
use owo_colors::OwoColorize;
use serde::Serialize;
use serde_json::json;

use crate::db::{group_by_version, Index, Revision, Run};
use crate::output::{self, Cell, Table};
use crate::select::{self, Releases, Target};
use crate::version;

/// How many matches `query search` prints before summarising the rest.
pub const SEARCH_LIMIT: usize = 50;

/// How many entries each section of `query diff` prints by default. A busy
/// year adds two thousand attributes, and a screen of them is a listing rather
/// than an answer.
pub const DIFF_LIMIT: usize = 25;

/// Whether output is JSON or a table for a human.
#[derive(Clone, Copy, PartialEq)]
pub enum Format {
    Json,
    Human,
}

/// One version's lifetime: its runs, and the ends of them.
#[derive(Serialize)]
struct Lifetime {
    version: String,
    first: String,
    first_label: String,
    last: String,
    last_label: String,
    /// Number of revisions the version was present in, summed over its runs.
    revisions: i64,
    /// True when the version is still there at the newest covered revision.
    current: bool,
    runs: Vec<Span>,
}

/// One unbroken run, in the terms a reader can act on.
#[derive(Serialize)]
struct Span {
    first: String,
    first_label: String,
    last: String,
    last_label: String,
    revisions: i64,
}

fn span(index: &Index, run: &Run) -> Result<Span> {
    let first = index.revision(run.first)?;
    let last = index.revision(run.last)?;
    Ok(Span {
        first: first.date,
        first_label: first.label,
        last: last.date,
        last_label: last.label,
        revisions: run.last - run.first + 1,
    })
}

fn lifetime(index: &Index, version: String, runs: &[Run]) -> Result<Lifetime> {
    let spans = runs
        .iter()
        .map(|r| span(index, r))
        .collect::<Result<Vec<_>>>()?;
    let first = spans
        .first()
        .ok_or_else(|| anyhow!("a version with no runs"))?;
    let last = spans.last().unwrap();

    Ok(Lifetime {
        version,
        first: first.first.clone(),
        first_label: first.first_label.clone(),
        last: last.last.clone(),
        last_label: last.last_label.clone(),
        revisions: spans.iter().map(|s| s.revisions).sum(),
        current: runs.last().unwrap().last >= index.covered_tip(),
        runs: spans,
    })
}

/// The error for an attribute the index has never seen, which is a different
/// answer from an attribute that has left nixpkgs. Shared with the store
/// subcommands, which hit the same case first.
pub fn unknown_attr(index: &Index, attr: &str) -> Result<anyhow::Error> {
    let near = index.search(attr, 5)?;
    let suggestion = if near.is_empty() {
        String::new()
    } else {
        format!("\nDid you mean: {}", near.join(", "))
    };

    Ok(anyhow!(
        "{attr} is not in the index. Only attributes with a `.version` are indexed — package \
         sets such as `gnome3` never are. Nested attributes are indexed by path, but only \
         for the sets nix/nested-sets.nix lists: `jetbrains.idea` is there, \
         `python3Packages.requests` is not.{suggestion}"
    ))
}

/// `mvs query versions <attr>` — every version, oldest first, with its lifetime.
pub fn versions(index: &Index, attr: &str, format: Format) -> Result<()> {
    let runs = index.runs_of(attr)?;
    if runs.is_empty() {
        return Err(unknown_attr(index, attr)?);
    }

    let mut grouped = group_by_version(runs);
    // SQLite cannot sort by Nix version ordering, so this is the one place the
    // ordering has to be applied after the query rather than in it.
    grouped.sort_by(|(a, _), (b, _)| version::compare(a, b));

    let lifetimes = grouped
        .into_iter()
        .map(|(v, runs)| lifetime(index, v, &runs))
        .collect::<Result<Vec<_>>>()?;

    if format == Format::Json {
        return output::print_json(json!({ "attr": attr, "versions": lifetimes }));
    }

    let oldest = &lifetimes[0];
    let newest = lifetimes.last().unwrap();
    anstream::println!(
        "{attr} · {} · {} .. {}",
        output::plural(lifetimes.len(), "version"),
        oldest.first,
        newest.last
    );

    let mut table = Table::new(&["VERSION", "FIRST", "LAST", "REVS", ""]);
    for life in &lifetimes {
        let style = if life.current {
            output::current()
        } else {
            output::plain()
        };
        // A version with more than one run left nixpkgs and came back, which is
        // worth saying out loud: its span is not a range it held throughout.
        let note = if life.runs.len() > 1 {
            output::plural(life.runs.len(), "run")
        } else {
            String::new()
        };

        table.row(vec![
            Cell::new(&life.version, style),
            Cell::new(&life.first, output::plain()),
            Cell::new(
                if life.current { "current" } else { &life.last },
                if life.current {
                    output::current()
                } else {
                    output::plain()
                },
            ),
            Cell::new(life.revisions.to_string(), output::muted()),
            Cell::new(note, output::muted()),
        ]);
    }
    table.print();
    Ok(())
}

/// `mvs query when <attr> <ver>` — first and last sighting, every run, and the
/// gaps between them.
pub fn when(index: &Index, attr: &str, ver: &str, format: Format) -> Result<()> {
    let runs = index.runs_of(attr)?;
    if runs.is_empty() {
        return Err(unknown_attr(index, attr)?);
    }

    let mine: Vec<Run> = runs.into_iter().filter(|r| r.version == ver).collect();
    if mine.is_empty() {
        let mut known: Vec<String> = index
            .runs_of(attr)?
            .into_iter()
            .map(|r| r.version)
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        version::sort(&mut known);
        return Err(anyhow!(
            "no revision ever had {attr} {ver}.\nKnown versions: {}",
            known.join(" ")
        ));
    }

    let life = lifetime(index, ver.to_string(), &mine)?;

    // A gap is the stretch between two runs: revisions in which the attribute
    // had some *other* version, or was absent entirely.
    let mut gaps = Vec::new();
    for pair in mine.windows(2) {
        let after = index.revision(pair[0].last + 1)?;
        let before = index.revision(pair[1].first - 1)?;
        gaps.push(json!({
            "first": after.date,
            "first_label": after.label,
            "last": before.date,
            "last_label": before.label,
            "revisions": pair[1].first - pair[0].last - 1,
        }));
    }

    if format == Format::Json {
        return output::print_json(json!({
            "attr": attr,
            "version": ver,
            "lifetime": life,
            "gaps": gaps,
        }));
    }

    anstream::println!(
        "{attr} {ver} · {} · {} .. {}",
        output::plural(life.revisions as usize, "revision"),
        life.first,
        if life.current { "current" } else { &life.last }
    );

    let mut table = Table::new(&["RUN", "FIRST", "LAST", "REVS"]);
    for (i, run) in life.runs.iter().enumerate() {
        table.row(vec![
            Cell::new((i + 1).to_string(), output::muted()),
            Cell::new(&run.first_label, output::plain()),
            Cell::new(&run.last_label, output::plain()),
            Cell::new(run.revisions.to_string(), output::muted()),
        ]);
    }
    table.print();

    for gap in &gaps {
        anstream::println!(
            "{}",
            format!(
                "  gap: {} between {} and {}",
                output::plural(gap["revisions"].as_i64().unwrap() as usize, "revision"),
                gap["first"].as_str().unwrap(),
                gap["last"].as_str().unwrap()
            )
        );
    }
    Ok(())
}

/// `mvs query at <sel> <attr>` — the version that revision shipped.
pub fn at(index: &Index, selector: &str, attr: &str, format: Format) -> Result<()> {
    let revision = select::resolve_revision(index, selector)?;
    let runs = index.runs_of(attr)?;
    if runs.is_empty() {
        return Err(unknown_attr(index, attr)?);
    }

    let found = runs
        .iter()
        .find(|r| r.first <= revision.off && revision.off <= r.last)
        .map(|r| r.version.clone());

    if format == Format::Json {
        return output::print_json(json!({
            "attr": attr,
            "version": found,
            "revision": revision,
        }));
    }

    match found {
        Some(v) => anstream::println!("{}", v),
        None => anstream::println!(
            "{}",
            format!("{attr} was not in nixpkgs at {}", revision.label)
        ),
    }
    anstream::println!("{}", format!("  {} ({})", revision.label, revision.date));
    Ok(())
}

/// `mvs query gone <attr>` — last sighting, or still current.
pub fn gone(index: &Index, attr: &str, format: Format) -> Result<()> {
    let runs = index.runs_of(attr)?;
    if runs.is_empty() {
        return Err(unknown_attr(index, attr)?);
    }

    // The newest run is the last sighting, whatever version it held.
    let newest = runs.iter().max_by_key(|r| r.last).unwrap();
    let revision = index.revision(newest.last)?;
    let is_gone = newest.last < index.covered_tip();

    if format == Format::Json {
        return output::print_json(json!({
            "attr": attr,
            "gone": is_gone,
            "version": newest.version,
            "date": revision.date,
            "label": revision.label,
        }));
    }

    if is_gone {
        anstream::println!(
            "{}",
            format!("{attr} was last seen at {}", revision.date).style(output::ended())
        );
        anstream::println!(
            "  {} {}\n  {}",
            attr,
            newest.version,
            format!("nix build .#{}.{attr}", revision.label)
        );
    } else {
        anstream::println!(
            "{}",
            format!("{attr} {} is current", newest.version).style(output::current())
        );
        anstream::println!("  {} ({})", revision.label, revision.date);
    }
    Ok(())
}

/// `mvs query rev <sel>` — resolve any selector to commit, date and label.
pub fn rev(index: &Index, selector: &str, format: Format) -> Result<()> {
    match select::resolve(index, selector, Releases::Allowed)? {
        Target::Revision(r) => {
            if format == Format::Json {
                return output::print_json(serde_json::to_value(&r)?);
            }
            anstream::println!("{}", r.rev);
            anstream::println!("  date    {}", r.date);
            anstream::println!("  label   {}", r.label);
            anstream::println!("  offset  {}", r.off);
            anstream::println!("  channel {}", r.name);
            match &r.narhash {
                Some(h) => anstream::println!("  narHash {h}"),
                // Without a narHash the revision is indexed but cannot be
                // materialised, which is a real difference to the caller.
                None => anstream::println!(
                    "{}",
                    "  narHash (none yet — run tools/add-narhashes.sh)".style(output::ended())
                ),
            }
            Ok(())
        }
        Target::Release(release) => {
            if format == Format::Json {
                return output::print_json(serde_json::to_value(&release)?);
            }
            anstream::println!("{}", release.rev);
            anstream::println!("  date    {}", release.date);
            anstream::println!("  release {}", release.name);
            if let Some(name) = &release.channel_name {
                anstream::println!("  channel {name}");
            }
            anstream::println!(
                "{}",
                "  (a release is a channel tip that moves; it has no index offset)"
                    .style(output::muted())
            );
            Ok(())
        }
    }
}

/// `mvs query search <pattern>` — attribute search, with each hit's state.
pub fn search(index: &Index, pattern: &str, limit: usize, format: Format) -> Result<()> {
    // One over the limit, so "there are more" can be said without counting the
    // whole table.
    let mut names = index.search(pattern, limit + 1)?;
    if names.is_empty() {
        names = index.search_nocase(pattern, limit + 1)?;
    }
    let truncated = names.len() > limit;
    names.truncate(limit);

    let mut hits = Vec::new();
    for name in &names {
        let runs = index.runs_of(name)?;
        let newest = runs.iter().max_by_key(|r| r.last).unwrap();
        let revision = index.revision(newest.last)?;
        hits.push(json!({
            "attr": name,
            "version": newest.version,
            "gone": newest.last < index.covered_tip(),
            "date": revision.date,
            "label": revision.label,
        }));
    }

    if format == Format::Json {
        return output::print_json(
            json!({ "pattern": pattern, "matches": hits, "truncated": truncated }),
        );
    }

    if hits.is_empty() {
        anstream::println!("no attribute matches {pattern}");
        return Ok(());
    }

    let mut table = Table::new(&["ATTR", "VERSION", "STATUS"]);
    for hit in &hits {
        let is_gone = hit["gone"].as_bool().unwrap();
        table.row(vec![
            Cell::new(hit["attr"].as_str().unwrap(), output::plain()),
            Cell::new(hit["version"].as_str().unwrap(), output::plain()),
            Cell::new(
                if is_gone {
                    format!("gone since {}", hit["date"].as_str().unwrap())
                } else {
                    "current".to_string()
                },
                if is_gone {
                    output::ended()
                } else {
                    output::current()
                },
            ),
        ]);
    }
    table.print();

    if truncated {
        anstream::println!(
            "{}",
            format!("… more matches; raise --limit (currently {limit})").style(output::muted())
        );
    }
    Ok(())
}

/// `mvs query diff <a> <b>` — what changed between two revisions.
pub fn diff(index: &Index, a: &str, b: &str, limit: usize, format: Format) -> Result<()> {
    let (from, to) = (
        select::resolve_revision(index, a)?,
        select::resolve_revision(index, b)?,
    );

    let before: std::collections::HashMap<String, String> =
        index.snapshot(from.off)?.into_iter().collect();
    let after: std::collections::HashMap<String, String> =
        index.snapshot(to.off)?.into_iter().collect();

    let (mut added, mut removed) = (Vec::new(), Vec::new());
    let (mut upgraded, mut downgraded) = (Vec::new(), Vec::new());

    for (attr, new) in &after {
        match before.get(attr) {
            None => added.push(json!({ "attr": attr, "version": new })),
            Some(old) if old == new => {}
            Some(old) => {
                let change = json!({ "attr": attr, "from": old, "to": new });
                match version::compare(old, new) {
                    std::cmp::Ordering::Less => upgraded.push(change),
                    // Equal versions are filtered above, so this is a genuine
                    // move backwards: a reverted bump, or a default that swung
                    // to an older branch.
                    _ => downgraded.push(change),
                }
            }
        }
    }
    for (attr, old) in &before {
        if !after.contains_key(attr) {
            removed.push(json!({ "attr": attr, "version": old }));
        }
    }

    for list in [&mut added, &mut removed, &mut upgraded, &mut downgraded] {
        list.sort_by(|x, y| x["attr"].as_str().cmp(&y["attr"].as_str()));
    }

    if format == Format::Json {
        return output::print_json(json!({
            "from": from,
            "to": to,
            "added": added,
            "removed": removed,
            "upgraded": upgraded,
            "downgraded": downgraded,
        }));
    }

    anstream::println!(
        "{} ({}) → {} ({})",
        from.label,
        from.date,
        to.label,
        to.date
    );
    anstream::println!(
        "{} added · {} removed · {} upgraded · {} downgraded",
        added.len(),
        removed.len(),
        upgraded.len(),
        downgraded.len()
    );

    section("added", &added, limit, |v| {
        (
            v["attr"].as_str().unwrap().to_string(),
            v["version"].as_str().unwrap().to_string(),
        )
    });
    section("removed", &removed, limit, |v| {
        (
            v["attr"].as_str().unwrap().to_string(),
            v["version"].as_str().unwrap().to_string(),
        )
    });
    section("upgraded", &upgraded, limit, |v| {
        (
            v["attr"].as_str().unwrap().to_string(),
            format!(
                "{} → {}",
                v["from"].as_str().unwrap(),
                v["to"].as_str().unwrap()
            ),
        )
    });
    section("downgraded", &downgraded, limit, |v| {
        (
            v["attr"].as_str().unwrap().to_string(),
            format!(
                "{} → {}",
                v["from"].as_str().unwrap(),
                v["to"].as_str().unwrap()
            ),
        )
    });
    Ok(())
}

/// Print one section of a diff, truncated to `limit` with the remainder
/// counted rather than dropped silently.
fn section(
    title: &str,
    entries: &[serde_json::Value],
    limit: usize,
    describe: impl Fn(&serde_json::Value) -> (String, String),
) {
    if entries.is_empty() {
        return;
    }

    anstream::println!("\n{}", title.style(output::header_style()));
    let shown = if limit == 0 {
        entries.len()
    } else {
        limit.min(entries.len())
    };

    let mut table = Table::new(&["ATTR", "VERSION"]);
    for entry in &entries[..shown] {
        let (attr, version) = describe(entry);
        table.row(vec![
            Cell::new(attr, output::plain()),
            Cell::new(version, output::muted()),
        ]);
    }
    table.print();

    if shown < entries.len() {
        anstream::println!(
            "{}",
            format!("… and {} more (--limit 0 for all)", entries.len() - shown)
                .style(output::muted())
        );
    }
}

/// `mvs query stats` — headline numbers, straight out of the database.
pub fn stats(index: &Index, format: Format) -> Result<()> {
    let conn = index.connection();
    let tip: Revision = index.tip()?;
    let first: Revision = index.revision(0)?;

    let revisions: i64 = conn.query_row("SELECT count(*) FROM revisions", [], |r| r.get(0))?;
    let attrs: i64 = conn.query_row("SELECT count(*) FROM attrs", [], |r| r.get(0))?;
    let runs: i64 = conn.query_row("SELECT count(*) FROM runs", [], |r| r.get(0))?;
    let pairs: i64 = conn.query_row(
        "SELECT count(*) FROM (SELECT DISTINCT attr_id, version FROM runs)",
        [],
        |r| r.get(0),
    )?;
    let current: i64 = conn.query_row(
        "SELECT count(DISTINCT attr_id) FROM runs WHERE last >= ?1",
        [index.covered_tip()],
        |r| r.get(0),
    )?;

    // (attr, version) pairs that are non-contiguous — versions that left
    // nixpkgs and came back. This is the number that decides the schema:
    // collapse those into a newest offset and `at`, `solve` and `diff` all
    // start lying.
    let returned: i64 = conn.query_row(
        "SELECT count(*) FROM (SELECT attr_id FROM runs GROUP BY attr_id, version HAVING count(*) > 1)",
        [],
        |r| r.get(0),
    )?;

    if format == Format::Json {
        return output::print_json(json!({
            "revisions": revisions,
            "first": first.date,
            "last": tip.date,
            "attrs_ever_seen": attrs,
            "attrs_current": current,
            "versions": pairs,
            "runs": runs,
            "returned": returned,
            "built_from": index.meta("built_from")?,
        }));
    }

    let percent = 100.0 * returned as f64 / pairs as f64;
    anstream::println!("{}", "nixpkgs multiverse".style(output::header_style()));
    anstream::println!(
        "  revisions       {revisions}  ({} .. {})",
        first.date,
        tip.date
    );
    anstream::println!("  attrs ever seen {attrs}");
    anstream::println!("  attrs current   {current}");
    anstream::println!("  versions        {pairs}");
    anstream::println!(
        "  runs            {runs}  ({returned} versions left and came back, {percent:.1}%)"
    );
    if let Some(built) = index.meta("built_from")? {
        anstream::println!(
            "{}",
            format!("  built from      {built}").style(output::muted())
        );
    }
    Ok(())
}

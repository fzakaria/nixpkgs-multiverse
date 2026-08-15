//! Human-readable output: a small table writer and the shared styles.
//!
//! Hand-rolled rather than pulled from a crate. Every table here is a handful
//! of left-aligned columns with a styled header, and the only part that is
//! easy to get wrong — padding computed on the text while the colour goes on
//! afterwards — is the part a table crate would not do for us anyway, since
//! the cells carry their own styles.

use anyhow::Result;
use owo_colors::{OwoColorize, Style};

/// Emit a `--json` answer. Pretty-printed: the caller who wanted machine
/// output usually reads it first, and `jq` does not care either way.
pub fn print_json(value: serde_json::Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

/// The gap between columns. Two spaces reads as a column boundary without a
/// separator character, which keeps output pasteable.
const GUTTER: &str = "  ";

pub fn header_style() -> Style {
    Style::new().bold()
}

/// Anything the index states as fact: dates, revisions, counts.
pub fn plain() -> Style {
    Style::new()
}

/// Something still true at the newest revision — a current version, a package
/// that has not left nixpkgs.
pub fn current() -> Style {
    Style::new().green()
}

/// Something that has ended: a version that was superseded, a package that is
/// gone.
pub fn ended() -> Style {
    Style::new().red()
}

/// Supporting detail — labels, counts, the parts of a line that qualify the
/// answer rather than being it.
pub fn muted() -> Style {
    Style::new().dimmed()
}

pub struct Cell {
    text: String,
    style: Style,
}

impl Cell {
    pub fn new(text: impl Into<String>, style: Style) -> Cell {
        Cell {
            text: text.into(),
            style,
        }
    }
}

/// A left-aligned table whose column widths come from its contents.
pub struct Table {
    headers: Vec<String>,
    rows: Vec<Vec<Cell>>,
}

impl Table {
    pub fn new(headers: &[&str]) -> Table {
        Table {
            headers: headers.iter().map(|h| h.to_string()).collect(),
            rows: Vec::new(),
        }
    }

    pub fn row(&mut self, cells: Vec<Cell>) {
        debug_assert_eq!(cells.len(), self.headers.len(), "row width matches header");
        self.rows.push(cells);
    }

    /// Print the table, or nothing at all when there are no rows — a bare
    /// header row claims a shape the caller has no data for.
    pub fn print(&self) {
        if self.rows.is_empty() {
            return;
        }

        // Widths come from the plain text: the styles are wrapped around a cell
        // after it has been padded, so escape sequences never enter the count.
        let widths: Vec<usize> = (0..self.headers.len())
            .map(|i| {
                let cells = self.rows.iter().map(|r| r[i].text.chars().count());
                cells
                    .chain([self.headers[i].chars().count()])
                    .max()
                    .unwrap()
            })
            .collect();

        let mut line = String::new();
        for (i, header) in self.headers.iter().enumerate() {
            line.push_str(&pad(header, widths[i], i == self.headers.len() - 1));
            if i + 1 < self.headers.len() {
                line.push_str(GUTTER);
            }
        }
        anstream::println!("{}", line.trim_end().style(header_style()));

        for row in &self.rows {
            let mut line = String::new();
            for (i, cell) in row.iter().enumerate() {
                // Padding belongs outside the styled span, so a coloured cell
                // does not paint the gutter after it. An empty cell is left
                // unstyled outright: its escape sequences would otherwise sit
                // at the end of the line and defeat the trim below.
                let padded = pad(&cell.text, widths[i], i == row.len() - 1);
                let (text, spaces) = padded.split_at(cell.text.len());
                if !text.is_empty() {
                    line.push_str(&format!("{}", text.style(cell.style)));
                }
                line.push_str(spaces);
                if i + 1 < row.len() {
                    line.push_str(GUTTER);
                }
            }
            anstream::println!("{}", line.trim_end());
        }
    }
}

/// Pad `text` to `width`, except in the last column where trailing spaces are
/// only something for a reader to select by accident.
fn pad(text: &str, width: usize, last: bool) -> String {
    if last {
        return text.to_string();
    }
    let mut s = text.to_string();
    for _ in text.chars().count()..width {
        s.push(' ');
    }
    s
}

/// `n` of something, pluralised: "1 revision", "3 revisions".
pub fn plural(n: usize, singular: &str) -> String {
    if n == 1 {
        format!("{n} {singular}")
    } else {
        format!("{n} {singular}s")
    }
}

/// Binary units for byte counts. Sizes here come from NARs and closures, which
/// Nix itself reports in KiB/MiB/GiB.
const BYTE_UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
const BYTES_PER_UNIT: f64 = 1024.0;

/// A byte count for a human: "532 B", "48.2 KiB", "1.5 GiB".
pub fn bytes(n: i64) -> String {
    let mut value = n as f64;
    for unit in BYTE_UNITS {
        if value < BYTES_PER_UNIT {
            // Whole bytes are exact and printed as such; anything scaled is an
            // approximation and gets one decimal.
            if unit == BYTE_UNITS[0] {
                return format!("{n} {unit}");
            }
            return format!("{value:.1} {unit}");
        }
        value /= BYTES_PER_UNIT;
    }
    format!("{value:.1} {}", BYTE_UNITS[BYTE_UNITS.len() - 1])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The byte formatter: exact below 1 KiB, one decimal above, and each unit
    /// boundary landing on the right unit.
    #[test]
    fn formats_bytes() {
        assert_eq!(bytes(0), "0 B");
        assert_eq!(bytes(532), "532 B");
        assert_eq!(bytes(1023), "1023 B");
        assert_eq!(bytes(1024), "1.0 KiB");
        assert_eq!(bytes(49368), "48.2 KiB");
        assert_eq!(bytes(50_000_000), "47.7 MiB");
        assert_eq!(bytes(3_000_000_000), "2.8 GiB");
        assert_eq!(bytes(2_000_000_000_000), "1.8 TiB");
    }
}

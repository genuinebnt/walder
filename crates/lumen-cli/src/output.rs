//! Printing.
//!
//! Every command prints a table for a person or JSON for a script; `--json` is
//! the switch. Nothing is written to stdout except the result, so piping into
//! `jq` works — progress and errors go to stderr.

use lumen_core::*;
use serde::Serialize;

/// A line of table output, padded so columns line up without a table crate.
pub fn wallpaper_row(w: &Wallpaper) -> String {
    format!(
        "{:<8}  {:>9}  {:<7}  {:<7}  {:>7}  {:>6}  {}",
        w.id,
        format!("{}x{}", w.resolution.width, w.resolution.height),
        w.category.to_string(),
        w.purity.to_string(),
        human_bytes(w.file_size),
        w.favorites,
        w.tags
            .iter()
            .take(4)
            .map(|t| t.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    )
}

pub fn wallpaper_header() -> String {
    format!(
        "{:<8}  {:>9}  {:<7}  {:<7}  {:>7}  {:>6}  {}",
        "ID", "SIZE", "CATEGORY", "PURITY", "BYTES", "FAVS", "TAGS"
    )
}

pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    if bytes == 0 {
        return "0 B".into();
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// Prints a value as JSON, for `--json`.
pub fn json<T: Serialize>(value: &T) -> anyhow::Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

/// Progress and status, kept off stdout so output stays pipeable.
pub fn note(message: impl std::fmt::Display) {
    eprintln!("{message}");
}

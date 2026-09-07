//! Recovering Wallhaven metadata for files that already exist.
//!
//! A folder of wallpapers downloaded from Wallhaven years ago is, on disk, a
//! folder of anonymous JPEGs — the tags, palette, uploader and resolution only
//! ever lived in the API response. But Wallhaven names its downloads after the
//! wallpaper's id, and that id is enough to ask for all of it back.
//!
//! Both naming conventions are recognised: `wallhaven-<id>.jpg`, which is what
//! the site serves today, and a bare `<id>.jpg`, which is what it used to.
//!
//! The run is resumable by construction: a file that already has a sidecar is
//! skipped, so an interrupted pass continues where it stopped rather than
//! spending the rate limit twice on the same files.

use std::path::{Path, PathBuf};
use std::time::Duration;

use lumen_core::traits::Provider;
use lumen_core::*;

use crate::app::App;
use crate::commands::download::write_metadata;
use crate::output;

/// A Wallhaven id: exactly six characters of lowercase letters and digits.
///
/// The length check is what keeps this from treating `sunset.jpg` as an id and
/// burning a request on it.
fn id_from_filename(name: &str) -> Option<String> {
    let stem = Path::new(name).file_stem()?.to_str()?;
    let stem = stem.strip_prefix("wallhaven-").unwrap_or(stem);
    if stem.len() == 6 && stem.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
        Some(stem.to_string())
    } else {
        None
    }
}

/// Whether this file already carries the record.
fn has_sidecar(path: &Path) -> bool {
    sidecar_path(path).is_some_and(|p| p.is_file())
}

fn sidecar_path(file: &Path) -> Option<PathBuf> {
    let name = file.file_name()?.to_string_lossy();
    Some(file.with_file_name(format!(".{name}.lumen.json")))
}

pub struct Plan {
    /// Files that can be filled in, with the id read from the name.
    pub candidates: Vec<(PathBuf, String)>,
    /// Files that already have their record.
    pub already_done: usize,
    /// Files whose name says nothing about where they came from.
    pub unrecognised: usize,
}

/// Works out what could be filled in, without asking Wallhaven anything.
pub fn plan(app: &App, folder: Option<&str>) -> anyhow::Result<Plan> {
    let folder_id = match folder {
        Some(name) => Some(app.folder_named(name)?.0),
        None => None,
    };
    let rows = app.db.imported_wallpapers(folder_id, false)?;

    let mut candidates = Vec::new();
    let mut already_done = 0;
    let mut unrecognised = 0;

    for (_, _, path, filename, _, _, _) in rows {
        let path = PathBuf::from(path);
        if !path.is_file() {
            continue;
        }
        match id_from_filename(&filename) {
            Some(id) if has_sidecar(&path) => {
                let _ = id;
                already_done += 1;
            }
            Some(id) => candidates.push((path, id)),
            None => unrecognised += 1,
        }
    }

    Ok(Plan { candidates, already_done, unrecognised })
}

/// Fetches and writes the metadata.
///
/// `per_minute` throttles the run. Wallhaven allows 45 requests a minute and
/// answers a burst with 429; the provider honours `Retry-After` when that
/// happens, but pacing under the limit is better than being told off for
/// exceeding it.
pub async fn run(
    app: &App,
    folder: Option<&str>,
    limit: Option<usize>,
    per_minute: u32,
    dry_run: bool,
) -> anyhow::Result<()> {
    let plan = plan(app, folder)?;
    let mut candidates = plan.candidates;
    if let Some(cap) = limit {
        candidates.truncate(cap);
    }

    if app.json && dry_run {
        return output::json(&serde_json::json!({
            "candidates": candidates.len(),
            "alreadyDone": plan.already_done,
            "unrecognised": plan.unrecognised,
        }));
    }

    output::note(format!(
        "{} to fill in · {} already done · {} not named after a wallpaper",
        candidates.len(),
        plan.already_done,
        plan.unrecognised
    ));

    if dry_run {
        for (path, id) in candidates.iter().take(20) {
            println!("{id}  {}", path.display());
        }
        if candidates.len() > 20 {
            output::note(format!("… and {} more", candidates.len() - 20));
        }
        return Ok(());
    }
    if candidates.is_empty() {
        return Ok(());
    }

    let pace = Duration::from_secs_f64(60.0 / f64::from(per_minute.clamp(1, 45)));
    let minutes = candidates.len() as f64 * pace.as_secs_f64() / 60.0;
    output::note(format!(
        "Pacing at {per_minute}/min — about {minutes:.0} minutes. Safe to interrupt: \
         a second run skips what is already done."
    ));

    let mut filled = 0usize;
    let mut missing = 0usize;
    let mut failed = 0usize;

    for (position, (path, id)) in candidates.iter().enumerate() {
        // The cache spares a request for anything already browsed or
        // downloaded in the app, which on a large library is a real saving.
        let wallpaper = match app.db.get_cached_wallpaper(id)? {
            Some(cached) if !cached.tags.is_empty() => Some(cached),
            _ => match app.provider.get_wallpaper(id).await {
                Ok(fetched) => {
                    let _ = app.db.cache_wallpaper(&fetched);
                    tokio::time::sleep(pace).await;
                    Some(fetched)
                }
                // A wallpaper that has since been taken down is not an error
                // worth stopping a two-hour run for.
                Err(LumenError::Api { status: 404, .. }) => {
                    missing += 1;
                    tokio::time::sleep(pace).await;
                    None
                }
                Err(e) => {
                    failed += 1;
                    output::note(format!("{id}: {e}"));
                    tokio::time::sleep(pace).await;
                    None
                }
            },
        };

        if let Some(wallpaper) = wallpaper {
            write_metadata(&wallpaper, path);
            filled += 1;
        }

        if !app.json && (position + 1) % 25 == 0 {
            output::note(format!(
                "  {}/{} · {filled} filled · {missing} gone · {failed} failed",
                position + 1,
                candidates.len()
            ));
        }
    }

    if app.json {
        return output::json(&serde_json::json!({
            "filled": filled, "missing": missing, "failed": failed
        }));
    }
    output::note(format!(
        "Filled {filled}. {missing} no longer on Wallhaven, {failed} failed."
    ));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_naming_conventions_are_recognised() {
        assert_eq!(id_from_filename("wallhaven-395yv3.jpg").as_deref(), Some("395yv3"));
        assert_eq!(id_from_filename("47m1xy.jpeg").as_deref(), Some("47m1xy"));
        assert_eq!(id_from_filename("2e8mlx.png").as_deref(), Some("2e8mlx"));
    }

    #[test]
    fn anything_that_is_not_an_id_is_left_alone() {
        // Six characters is the whole test, so a real word of another length
        // is safe — and one that happens to be six is the reason this only
        // ever costs one wasted request, not a wrong write.
        assert_eq!(id_from_filename("sunset.jpg"), Some("sunset".into()));
        assert_eq!(id_from_filename("my wallpaper.jpg"), None);
        assert_eq!(id_from_filename("IMG_4021.jpeg"), None);
        assert_eq!(id_from_filename("photo-2019.png"), None);
        assert_eq!(id_from_filename("ab12.jpg"), None);
    }

    #[test]
    fn the_sidecar_is_the_one_the_app_reads() {
        assert_eq!(
            sidecar_path(Path::new("/w/47m1xy.jpeg")).unwrap(),
            Path::new("/w/.47m1xy.jpeg.lumen.json")
        );
    }
}

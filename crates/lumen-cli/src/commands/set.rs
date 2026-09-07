//! Putting a wallpaper on the desktop.

use std::path::{Path, PathBuf};

use lumen_core::traits::{Provider, WallpaperSetter};
use lumen_core::*;

use crate::app::App;
use crate::output;

/// Finds the file for a target that may be a path, an id, or neither yet.
///
/// A downloaded copy is always preferred to fetching again — the app and the
/// CLI download into the same directory under the same name, so either one's
/// downloads satisfy the other. Anything else is staged in the cache
/// directory, which is what the app does too.
pub async fn resolve(app: &App, target: &str) -> anyhow::Result<(PathBuf, Option<Wallpaper>)> {
    let as_path = PathBuf::from(shellexpand(target));
    if as_path.is_file() {
        return Ok((as_path, None));
    }
    if as_path.exists() {
        anyhow::bail!("{} is not a file", as_path.display());
    }
    // A bare path that does not exist is a mistake, not an id — ids have no
    // separators and no extension.
    if target.contains('/') || target.contains('.') {
        anyhow::bail!("no such file: {target}");
    }

    let id = target.trim_start_matches("wallhaven-");
    let wallpaper = match app.db.get_cached_wallpaper(id)? {
        Some(cached) if !cached.full_url.is_empty() => cached,
        _ => app.provider.get_wallpaper(id).await?,
    };
    let _ = app.db.cache_wallpaper(&wallpaper);
    let filename = App::filename_for(&wallpaper);

    // In the download directory, from either front end.
    let downloaded = app.download_dir.join(&filename);
    if downloaded.is_file() {
        return Ok((downloaded, Some(wallpaper)));
    }
    // Recorded elsewhere — the download directory may have moved since.
    if let Some(record) = app
        .db
        .get_download_records(500)?
        .into_iter()
        .find(|r| r.wallpaper_id == id)
    {
        let path = PathBuf::from(&record.local_path);
        if path.is_file() {
            return Ok((path, Some(wallpaper)));
        }
    }
    // Already staged by a previous set.
    let staged = app.cache_dir()?.join(&filename);
    if staged.is_file() {
        return Ok((staged, Some(wallpaper)));
    }

    output::note(format!("Fetching {id}…"));
    let bytes = reqwest::get(&wallpaper.full_url)
        .await
        .map_err(|e| anyhow::anyhow!("could not fetch {}: {e}", wallpaper.full_url))?
        .error_for_status()?
        .bytes()
        .await?;

    // Written to a unique name and renamed, so a reader never sees a
    // half-written image and two concurrent sets cannot interleave.
    let staging = app
        .cache_dir()?
        .join(format!(".{}.part", uuid::Uuid::new_v4()));
    std::fs::write(&staging, &bytes)?;
    if let Err(e) = std::fs::rename(&staging, &staged) {
        let _ = std::fs::remove_file(&staging);
        return Err(e.into());
    }
    Ok((staged, Some(wallpaper)))
}

/// Sets the wallpaper and writes it into the history, which is what makes
/// `history undo` able to walk back.
pub fn apply(app: &App, path: &Path, wallpaper: Option<&Wallpaper>) -> anyhow::Result<()> {
    app.setter.set_wallpaper(path)?;

    let label = wallpaper
        .map(|w| format!("wallhaven-{}", w.id))
        .or_else(|| path.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| path.to_string_lossy().into_owned());
    let _ = app.db.record_wallpaper(
        wallpaper.map(|w| w.id.as_str()),
        &path.to_string_lossy(),
        &label,
    );
    Ok(())
}

pub async fn run(app: &App, target: &str) -> anyhow::Result<()> {
    let (path, wallpaper) = resolve(app, target).await?;
    apply(app, &path, wallpaper.as_ref())?;

    if app.json {
        return output::json(&serde_json::json!({
            "set": path.to_string_lossy(),
            "wallpaperId": wallpaper.as_ref().map(|w| w.id.clone()),
        }));
    }
    println!("{}", path.display());
    Ok(())
}

/// What the desktop is showing now.
pub fn current(app: &App) -> anyhow::Result<()> {
    let path = app.setter.get_current_wallpaper()?;
    if app.json {
        return output::json(&serde_json::json!({ "current": path }));
    }
    match path {
        Some(path) => println!("{path}"),
        None => output::note("macOS did not report a current wallpaper."),
    }
    Ok(())
}

/// Expands a leading `~/`, which a shell would have done for an unquoted path.
fn shellexpand(value: &str) -> String {
    match value.strip_prefix("~/") {
        Some(rest) => directories::BaseDirs::new()
            .map(|b| b.home_dir().join(rest).to_string_lossy().into_owned())
            .unwrap_or_else(|| value.to_string()),
        None => value.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tilde_path_expands() {
        let home = directories::BaseDirs::new().unwrap().home_dir().to_path_buf();
        assert_eq!(
            shellexpand("~/Pictures/a.jpg"),
            home.join("Pictures/a.jpg").to_string_lossy()
        );
    }

    #[test]
    fn a_plain_path_is_untouched() {
        assert_eq!(shellexpand("/tmp/a.jpg"), "/tmp/a.jpg");
    }
}

//! Downloading, and the metadata that travels with a download.

use std::path::{Path, PathBuf};

use lumen_core::traits::Provider;
use lumen_core::*;
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};

use crate::app::App;
use crate::commands::browse;
use crate::filters::SearchArgs;
use crate::output;

/// What a finished download left behind.
pub struct Downloaded {
    pub wallpaper: Wallpaper,
    pub path: PathBuf,
}

/// Downloads several wallpapers, showing one progress bar each.
pub async fn fetch(
    app: &App,
    wallpapers: &[Wallpaper],
    dir: &Path,
    metadata: bool,
) -> anyhow::Result<Vec<Downloaded>> {
    if wallpapers.is_empty() {
        return Ok(Vec::new());
    }
    std::fs::create_dir_all(dir)?;

    let bars = MultiProgress::new();
    let style = ProgressStyle::with_template(
        "{prefix:14} [{bar:28.cyan/blue}] {bytes:>9}/{total_bytes:<9} {binary_bytes_per_sec}",
    )?
    .progress_chars("=> ");

    let mut pending = Vec::new();
    for wallpaper in wallpapers {
        let filename = App::filename_for(wallpaper);
        let destination = dir.join(&filename);

        // Already there is already done. Re-downloading a wallpaper you have
        // is the one thing a wallpaper CLI should never do by surprise.
        if destination.is_file() {
            output::note(format!("{}  already downloaded", wallpaper.id));
            if metadata {
                write_metadata(wallpaper, &destination);
            }
            record(app, wallpaper, &destination);
            pending.push((wallpaper.clone(), destination, None));
            continue;
        }

        let task = app
            .downloads
            .enqueue(
                wallpaper.id.clone(),
                wallpaper.full_url.clone(),
                filename,
                dir,
            )
            .await?;

        let bar = bars.add(ProgressBar::new(wallpaper.file_size.max(1)));
        bar.set_style(style.clone());
        bar.set_prefix(wallpaper.id.clone());
        pending.push((wallpaper.clone(), destination, Some((task, bar))));
    }

    let mut finished = Vec::new();
    let mut watch = app.downloads.subscribe();
    let mut waiting: Vec<_> = pending
        .iter()
        .filter_map(|(w, path, task)| task.as_ref().map(|(id, bar)| (w.clone(), path.clone(), *id, bar.clone())))
        .collect();

    // Anything that was already on disk is done before the loop starts.
    for (wallpaper, path, task) in &pending {
        if task.is_none() {
            finished.push(Downloaded { wallpaper: wallpaper.clone(), path: path.clone() });
        }
    }

    while !waiting.is_empty() {
        if watch.changed().await.is_err() {
            break;
        }
        let tasks = watch.borrow().clone();
        waiting.retain(|(wallpaper, path, task_id, bar)| {
            let Some(task) = tasks.iter().find(|t| t.id == *task_id) else {
                return true;
            };
            if let Some(total) = task.total_bytes {
                bar.set_length(total);
            }
            bar.set_position(task.bytes_downloaded);

            match task.status {
                DownloadStatus::Completed => {
                    bar.finish();
                    if metadata {
                        write_metadata(wallpaper, path);
                    }
                    record(app, wallpaper, path);
                    finished.push(Downloaded {
                        wallpaper: wallpaper.clone(),
                        path: path.clone(),
                    });
                    false
                }
                DownloadStatus::Failed => {
                    bar.abandon_with_message(
                        task.error.clone().unwrap_or_else(|| "failed".into()),
                    );
                    false
                }
                DownloadStatus::Cancelled => {
                    bar.abandon_with_message("cancelled".to_string());
                    false
                }
                _ => true,
            }
        });
    }

    Ok(finished)
}

/// Writes the download into the history and the library, so the app sees it.
fn record(app: &App, wallpaper: &Wallpaper, path: &Path) {
    let bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(wallpaper.file_size);
    let _ = app.db.cache_wallpaper(wallpaper);
    let _ = app.db.add_download_record(&DownloadRecord {
        wallpaper_id: wallpaper.id.clone(),
        provider: WallpaperProvider::Wallhaven,
        local_path: path.to_string_lossy().into_owned(),
        file_size: bytes,
        downloaded_at: chrono::Utc::now(),
    });
}

/// Attaches what Wallhaven knows to the file itself.
///
/// Two forms, because they answer different questions: extended attributes so
/// Spotlight and Finder can find the file by tag, and a hidden sidecar holding
/// the whole record so the file can still say what it is if it leaves Lumen.
/// The sidecar is the app's own wire format — a file downloaded here opens in
/// the app's preview with its tags and palette intact.
pub fn write_metadata(wallpaper: &Wallpaper, path: &Path) {
    if !path.is_file() {
        return;
    }

    let dto = lumen_ffi::dto::WallpaperDto::from(wallpaper);
    if let Ok(json) = serde_json::to_vec_pretty(&dto) {
        if let Some(sidecar) = sidecar_path(path) {
            let _ = std::fs::write(sidecar, json);
        }
    }

    let tags: Vec<String> = wallpaper.tags.iter().map(|t| t.name.clone()).collect();
    if !tags.is_empty() {
        set_plist(path, "com.apple.metadata:kMDItemKeywords", &plist_array(&tags));
        let comment = format!("Wallhaven · {}", tags.join(", "));
        set_plist(path, "com.apple.metadata:kMDItemFinderComment", &plist_string(&comment));
    }
    let origins = vec![wallpaper.url.clone(), wallpaper.full_url.clone()];
    set_plist(path, "com.apple.metadata:kMDItemWhereFroms", &plist_array(&origins));
}

/// `.<filename>.lumen.json` beside the image — hidden, so the folder scanner
/// never indexes it as a wallpaper, and it travels with a copy of the file.
fn sidecar_path(file: &Path) -> Option<PathBuf> {
    let name = file.file_name()?.to_string_lossy();
    Some(file.with_file_name(format!(".{name}.lumen.json")))
}

// ── extended attributes ───────────────────────────────────────────────────
//
// macOS stores these as binary plists. A hand-rolled writer is used rather
// than a plist crate because two shapes are needed — a string and an array of
// strings — and both are short enough to emit directly in the XML form, which
// Spotlight reads just as happily as the binary one.

fn plist_string(value: &str) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
         \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\"><string>{}</string></plist>",
        escape(value)
    )
}

fn plist_array(values: &[String]) -> String {
    let items: String = values
        .iter()
        .map(|v| format!("<string>{}</string>", escape(v)))
        .collect();
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
         \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\"><array>{items}</array></plist>"
    )
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(target_os = "macos")]
fn set_plist(path: &Path, name: &str, xml: &str) {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let Ok(c_path) = CString::new(path.as_os_str().as_bytes()) else { return };
    let Ok(c_name) = CString::new(name) else { return };
    // A failure here is not worth reporting: a filesystem without extended
    // attribute support should not fail a download.
    unsafe {
        libc::setxattr(
            c_path.as_ptr(),
            c_name.as_ptr(),
            xml.as_ptr() as *const libc::c_void,
            xml.len(),
            0,
            0,
        );
    }
}

#[cfg(not(target_os = "macos"))]
fn set_plist(_path: &Path, _name: &str, _xml: &str) {}

// ── commands ──────────────────────────────────────────────────────────────

/// Fills in what a search result does not carry.
///
/// Wallhaven's search endpoint returns no tags — they only come from the
/// details endpoint. Downloading without them would write a file with no
/// keywords for Spotlight and a sidecar the app shows as untagged, so the
/// details are fetched before the bytes are, but only when the metadata is
/// going to be used.
async fn with_details(app: &App, wallpapers: Vec<Wallpaper>, metadata: bool) -> Vec<Wallpaper> {
    if !metadata {
        return wallpapers;
    }
    let mut filled = Vec::with_capacity(wallpapers.len());
    for wallpaper in wallpapers {
        if !wallpaper.tags.is_empty() {
            filled.push(wallpaper);
            continue;
        }
        match app.provider.get_wallpaper(&wallpaper.id).await {
            Ok(detailed) => {
                let _ = app.db.cache_wallpaper(&detailed);
                filled.push(detailed);
            }
            // A details call that fails is not worth failing the download for.
            Err(_) => filled.push(wallpaper),
        }
    }
    filled
}

/// `download <ID>...`
pub async fn by_ids(
    app: &App,
    ids: &[String],
    dir: Option<&str>,
    metadata: bool,
) -> anyhow::Result<Vec<Downloaded>> {
    let mut wallpapers = Vec::with_capacity(ids.len());
    for id in ids {
        // The cache saves a round trip when the id came from a search in the
        // same shell session.
        match app.db.get_cached_wallpaper(id)? {
            // A cached row from a search has no tags; only the details call
            // has them, and the metadata is the reason to care.
            Some(cached) if !cached.full_url.is_empty() && (!metadata || !cached.tags.is_empty()) => {
                wallpapers.push(cached)
            }
            _ => {
                let detailed = app.provider.get_wallpaper(id).await?;
                let _ = app.db.cache_wallpaper(&detailed);
                wallpapers.push(detailed);
            }
        }
    }
    let dir = dir.map(lumen_core::paths::resolve_dir).unwrap_or_else(|| app.download_dir.clone());
    fetch(app, &wallpapers, &dir, metadata).await
}

/// `download --search ...`
pub async fn by_search(
    app: &App,
    args: &SearchArgs,
    pages: u32,
    limit: Option<usize>,
    dir: Option<&str>,
    metadata: bool,
) -> anyhow::Result<Vec<Downloaded>> {
    let filters = args.to_filters()?;
    let (wallpapers, _) = browse::collect(app, &filters, pages, limit).await?;
    if wallpapers.is_empty() {
        output::note("Nothing matched, so nothing to download.");
        return Ok(Vec::new());
    }
    let wallpapers = with_details(app, wallpapers, metadata).await;
    let dir = dir.map(lumen_core::paths::resolve_dir).unwrap_or_else(|| app.download_dir.clone());
    fetch(app, &wallpapers, &dir, metadata).await
}

/// `downloads` — what has been downloaded before.
pub fn history(app: &App, limit: u32) -> anyhow::Result<()> {
    let records = app.db.get_download_records(limit)?;
    if app.json {
        return output::json(&records);
    }
    if records.is_empty() {
        output::note("Nothing downloaded yet.");
        return Ok(());
    }
    for record in &records {
        println!(
            "{:<8}  {:>9}  {}  {}",
            record.wallpaper_id,
            output::human_bytes(record.file_size),
            record.downloaded_at.format("%Y-%m-%d %H:%M"),
            record.local_path
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sidecar_is_hidden_and_beside_the_file() {
        let path = Path::new("/tmp/walls/wallhaven-abc.jpg");
        assert_eq!(
            sidecar_path(path).unwrap(),
            Path::new("/tmp/walls/.wallhaven-abc.jpg.lumen.json")
        );
    }

    #[test]
    fn plists_escape_what_would_break_them() {
        let xml = plist_array(&["rock & roll".into(), "<tag>".into()]);
        assert!(xml.contains("rock &amp; roll"));
        assert!(xml.contains("&lt;tag&gt;"));
        assert_eq!(xml.matches("<string>").count(), 2);
    }

    #[test]
    fn a_string_plist_holds_one_value() {
        let xml = plist_string("Wallhaven · forest");
        assert!(xml.contains("<string>Wallhaven · forest</string>"));
    }
}

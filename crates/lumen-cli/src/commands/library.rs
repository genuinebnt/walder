//! Folders imported from disk.
//!
//! The same index the app's Folders pane reads, so a folder imported here
//! appears there without a rescan.

use crate::app::App;
use crate::output;

pub fn import(app: &App, path: &str) -> anyhow::Result<()> {
    let root = lumen_core::paths::resolve_dir(path);
    if !root.is_dir() {
        anyhow::bail!("{} is not a folder", root.display());
    }
    let name = root
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| root.to_string_lossy().into_owned());

    let folder_id = app.db.import_folder(&root.to_string_lossy(), &name)?;
    let found = lumen_core::scan::scan_images(&root);
    let indexed = app
        .db
        .sync_imported_wallpapers(folder_id, &lumen_core::scan::as_rows(&found))?;

    if app.json {
        return output::json(&serde_json::json!({
            "id": folder_id.to_string(),
            "name": name,
            "path": root.to_string_lossy(),
            "count": found.len(),
            "changed": indexed,
        }));
    }
    println!("{name}  {} images", found.len());
    Ok(())
}

pub fn folders(app: &App) -> anyhow::Result<()> {
    let folders = app.db.imported_folders()?;
    if app.json {
        let listed: Vec<_> = folders
            .iter()
            .map(|(id, name, path, count)| {
                serde_json::json!({
                    "id": id.to_string(), "name": name, "path": path, "count": count
                })
            })
            .collect();
        return output::json(&listed);
    }
    if folders.is_empty() {
        output::note("No folders imported. Add one with: lumen-cli library import <PATH>");
        return Ok(());
    }
    for (_, name, path, count) in &folders {
        println!("{name:<24}  {count:>5}  {path}");
    }
    Ok(())
}

/// Re-walks every imported folder, or one of them.
pub fn rescan(app: &App, only: Option<&str>) -> anyhow::Result<()> {
    let folders = match only {
        Some(name) => vec![app.folder_named(name)?],
        None => app.db.imported_folders()?,
    };
    if folders.is_empty() {
        output::note("Nothing to rescan.");
        return Ok(());
    }

    let mut total = 0usize;
    for (id, name, path, _) in &folders {
        let found = lumen_core::scan::scan_images(std::path::Path::new(path));
        app.db
            .sync_imported_wallpapers(*id, &lumen_core::scan::as_rows(&found))?;
        total += found.len();
        if !app.json {
            println!("{name:<24}  {:>5}", found.len());
        }
    }
    if app.json {
        return output::json(&serde_json::json!({ "folders": folders.len(), "images": total }));
    }
    Ok(())
}

pub fn forget(app: &App, name: &str) -> anyhow::Result<()> {
    let (id, folder_name, _, count) = app.folder_named(name)?;
    app.db.remove_imported_folder(id)?;
    if app.json {
        return output::json(&serde_json::json!({ "forgot": folder_name, "images": count }));
    }
    // The images stay where they are — forgetting is about the index.
    output::note(format!("Forgot {folder_name} ({count} images left on disk)."));
    Ok(())
}

/// What is in a folder, or in all of them.
pub fn wallpapers(app: &App, folder: Option<&str>, favorites_only: bool) -> anyhow::Result<()> {
    let folder_id = match folder {
        Some(name) => Some(app.folder_named(name)?.0),
        None => None,
    };
    let rows = app.db.imported_wallpapers(folder_id, favorites_only)?;

    if app.json {
        let listed: Vec<_> = rows
            .iter()
            .map(|(id, folder_id, path, filename, bytes, favorite, subpath, width, height)| {
                serde_json::json!({
                    "id": id.to_string(),
                    "folderId": folder_id.to_string(),
                    "path": path,
                    "filename": filename,
                    "bytes": bytes,
                    "favorite": favorite,
                    "subpath": subpath,
                    "width": width,
                    "height": height,
                })
            })
            .collect();
        return output::json(&listed);
    }
    if rows.is_empty() {
        output::note("Nothing indexed here.");
        return Ok(());
    }
    for (_, _, path, filename, bytes, favorite, subpath, ..) in &rows {
        let mark = if *favorite { "♥" } else { " " };
        let where_ = if subpath.is_empty() { String::new() } else { format!("{subpath}/") };
        println!(
            "{mark} {:<40}  {:>9}  {path}",
            format!("{where_}{filename}"),
            output::human_bytes(*bytes)
        );
    }
    output::note(format!("\n{} images", rows.len()));
    Ok(())
}

/// Marks a local file as a favourite, the same flag the app's heart sets.
pub fn favorite(app: &App, path: &str, on: bool) -> anyhow::Result<()> {
    let wanted = lumen_core::paths::resolve_dir(path);
    let wanted = wanted.to_string_lossy().to_string();
    let row = app
        .db
        .imported_wallpapers(None, false)?
        .into_iter()
        .find(|(_, _, p, filename, ..)| *p == wanted || filename == path)
        .ok_or_else(|| anyhow::anyhow!("{path} is not in an imported folder"))?;

    app.db.set_imported_favorite(row.0, on)?;
    if app.json {
        return output::json(&serde_json::json!({ "path": row.2, "favorite": on }));
    }
    println!("{} {}", if on { "♥" } else { " " }, row.2);
    Ok(())
}

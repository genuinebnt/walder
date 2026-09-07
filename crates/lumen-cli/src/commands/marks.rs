//! Favourites and collections — the two ways a wallpaper gets filed.
//!
//! Both are bookmarks in the database: a favourite is a bookmark with no
//! folder, a collection is a bookmark folder. The app's Favourites tab and
//! Collections pane read exactly these rows.

use lumen_core::traits::Provider;
use lumen_core::*;

use crate::app::App;
use crate::output;

/// A bookmark references the cached wallpaper row, so an id that has never
/// been seen has to be fetched before it can be filed.
async fn ensure_cached(app: &App, ids: &[String]) -> anyhow::Result<Vec<Wallpaper>> {
    let mut wallpapers = Vec::with_capacity(ids.len());
    for id in ids {
        let id = id.trim_start_matches("wallhaven-");
        match app.db.get_cached_wallpaper(id)? {
            Some(cached) => wallpapers.push(cached),
            None => {
                let fetched = app.provider.get_wallpaper(id).await?;
                app.db.cache_wallpaper(&fetched)?;
                wallpapers.push(fetched);
            }
        }
    }
    Ok(wallpapers)
}

// ── favourites ────────────────────────────────────────────────────────────

pub fn list_favorites(app: &App) -> anyhow::Result<()> {
    let wallpapers = app.db.get_bookmarked_wallpapers(None)?;
    if app.json {
        return output::json(&wallpapers);
    }
    if wallpapers.is_empty() {
        output::note("No favourites yet.");
        return Ok(());
    }
    println!("{}", output::wallpaper_header());
    for wallpaper in &wallpapers {
        println!("{}", output::wallpaper_row(wallpaper));
    }
    output::note(format!("\n{} favourites", wallpapers.len()));
    Ok(())
}

pub async fn add_favorites(app: &App, ids: &[String]) -> anyhow::Result<()> {
    let wallpapers = ensure_cached(app, ids).await?;
    let known: Vec<String> = wallpapers.iter().map(|w| w.id.clone()).collect();
    let added = app.db.add_bookmarks_for(&known)?;
    if app.json {
        return output::json(&serde_json::json!({ "added": added, "requested": ids.len() }));
    }
    output::note(format!("Favourited {added} of {}.", ids.len()));
    Ok(())
}

pub fn remove_favorites(app: &App, ids: &[String]) -> anyhow::Result<()> {
    let ids: Vec<String> = ids
        .iter()
        .map(|id| id.trim_start_matches("wallhaven-").to_string())
        .collect();
    let removed = app.db.remove_bookmarks_for(&ids)?;
    if app.json {
        return output::json(&serde_json::json!({ "removed": removed }));
    }
    output::note(format!("Removed {removed}."));
    Ok(())
}

// ── collections ───────────────────────────────────────────────────────────

pub fn list_collections(app: &App) -> anyhow::Result<()> {
    let folders = app.db.get_folders()?;
    if app.json {
        let listed: Vec<_> = folders
            .iter()
            .map(|f| {
                let count = app
                    .db
                    .get_collection_wallpapers(f.id)
                    .map(|w| w.len())
                    .unwrap_or(0);
                serde_json::json!({ "id": f.id.to_string(), "name": f.name, "count": count })
            })
            .collect();
        return output::json(&listed);
    }
    if folders.is_empty() {
        output::note("No collections. Make one with: lumen-cli collections create <NAME>");
        return Ok(());
    }
    for folder in &folders {
        let count = app.db.get_collection_wallpapers(folder.id)?.len();
        println!("{:<28}  {count:>5}", folder.name);
    }
    Ok(())
}

pub fn create_collection(app: &App, name: &str) -> anyhow::Result<()> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        anyhow::bail!("a collection needs a name");
    }
    if app.collection_named(trimmed).is_ok() {
        anyhow::bail!("there is already a collection called \"{trimmed}\"");
    }
    let folder = BookmarkFolder::new(trimmed);
    app.db.add_folder(&folder)?;
    if app.json {
        return output::json(&serde_json::json!({ "id": folder.id.to_string(), "name": folder.name }));
    }
    output::note(format!("Created {}.", folder.name));
    Ok(())
}

pub fn delete_collection(app: &App, name: &str) -> anyhow::Result<()> {
    let folder = app.collection_named(name)?;
    app.db.delete_bookmark_folder(folder.id)?;
    if app.json {
        return output::json(&serde_json::json!({ "deleted": folder.name }));
    }
    output::note(format!("Deleted {}.", folder.name));
    Ok(())
}

pub async fn add_to_collection(app: &App, name: &str, ids: &[String]) -> anyhow::Result<()> {
    let folder = app.collection_named(name)?;
    let wallpapers = ensure_cached(app, ids).await?;
    let known: Vec<String> = wallpapers.iter().map(|w| w.id.clone()).collect();
    let added = app.db.add_many_to_collection(folder.id, &known)?;
    if app.json {
        return output::json(&serde_json::json!({ "collection": folder.name, "added": added }));
    }
    output::note(format!("Added {added} to {}.", folder.name));
    Ok(())
}

pub fn remove_from_collection(app: &App, name: &str, ids: &[String]) -> anyhow::Result<()> {
    let folder = app.collection_named(name)?;
    for id in ids {
        app.db
            .remove_from_collection(folder.id, id.trim_start_matches("wallhaven-"))?;
    }
    if app.json {
        return output::json(&serde_json::json!({ "collection": folder.name, "removed": ids.len() }));
    }
    output::note(format!("Removed {} from {}.", ids.len(), folder.name));
    Ok(())
}

pub fn show_collection(app: &App, name: &str) -> anyhow::Result<()> {
    let folder = app.collection_named(name)?;
    let wallpapers = app.db.get_collection_wallpapers(folder.id)?;
    if app.json {
        return output::json(&wallpapers);
    }
    if wallpapers.is_empty() {
        output::note(format!("{} is empty.", folder.name));
        return Ok(());
    }
    println!("{}", output::wallpaper_header());
    for wallpaper in &wallpapers {
        println!("{}", output::wallpaper_row(wallpaper));
    }
    output::note(format!("\n{} in {}", wallpapers.len(), folder.name));
    Ok(())
}

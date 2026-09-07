//! Preferences, shared with the app.
//!
//! These are the same rows Settings writes, so a key set here is the key the
//! app uses on its next launch.

use crate::app::App;
use crate::output;

pub fn show(app: &App) -> anyhow::Result<()> {
    let prefs = &app.prefs;
    if app.json {
        return output::json(&serde_json::json!({
            "apiKey": prefs.api_key.as_ref().map(|_| "set"),
            "downloadDir": app.download_dir.to_string_lossy(),
            "maxParallelDownloads": prefs.max_parallel_downloads,
            "database": lumen_core::paths::db_path().to_string_lossy(),
            "cache": lumen_core::paths::cache_dir().to_string_lossy(),
        }));
    }
    // The key itself is never printed: it is a credential, and this output is
    // the kind of thing that ends up pasted into an issue.
    println!("api key            {}", if prefs.api_key.is_some() { "set" } else { "not set" });
    println!("download dir       {}", app.download_dir.display());
    println!("concurrency        {}", prefs.max_parallel_downloads);
    println!("database           {}", lumen_core::paths::db_path().display());
    println!("cache              {}", lumen_core::paths::cache_dir().display());
    Ok(())
}

pub fn set_api_key(app: &App, key: &str) -> anyhow::Result<()> {
    let mut prefs = app.prefs.clone();
    prefs.api_key = Some(key.trim().to_string()).filter(|k| !k.is_empty());
    app.db.save_preferences(&prefs)?;
    output::note(if prefs.api_key.is_some() { "API key set." } else { "API key cleared." });
    Ok(())
}

pub fn set_download_dir(app: &App, path: &str) -> anyhow::Result<()> {
    let resolved = lumen_core::paths::resolve_dir(path);
    std::fs::create_dir_all(&resolved)?;
    let mut prefs = app.prefs.clone();
    prefs.download_dir = path.trim().to_string();
    app.db.save_preferences(&prefs)?;
    output::note(format!("Downloads go to {}.", resolved.display()));
    Ok(())
}

pub fn set_concurrency(app: &App, value: u32) -> anyhow::Result<()> {
    let clamped = value.clamp(1, 12);
    let mut prefs = app.prefs.clone();
    prefs.max_parallel_downloads = clamped;
    app.db.save_preferences(&prefs)?;
    output::note(format!("Downloading {clamped} at a time."));
    Ok(())
}

/// A quick look at what the CLI is working with.
pub fn status(app: &App) -> anyhow::Result<()> {
    let favorites = app.db.get_bookmarked_wallpapers(None)?.len();
    let collections = app.db.get_folders()?.len();
    let folders = app.db.imported_folders()?;
    let indexed: u32 = folders.iter().map(|(_, _, _, count)| count).sum();
    let cached = app.db.wallpaper_cache_count()?;
    let downloads = app.db.get_download_records(u32::MAX)?.len();
    let subscriptions = app.db.subscriptions()?.len();
    let history = app.db.wallpaper_history(u32::MAX)?.len();

    if app.json {
        return output::json(&serde_json::json!({
            "favorites": favorites,
            "collections": collections,
            "importedFolders": folders.len(),
            "indexedImages": indexed,
            "cachedWallpapers": cached,
            "downloads": downloads,
            "subscriptions": subscriptions,
            "history": history,
            "downloadDir": app.download_dir.to_string_lossy(),
            "database": lumen_core::paths::db_path().to_string_lossy(),
        }));
    }
    println!("favourites         {favorites}");
    println!("collections        {collections}");
    println!("imported folders   {}  ({indexed} images)", folders.len());
    println!("cached wallpapers  {cached}");
    println!("downloads          {downloads}");
    println!("subscriptions      {subscriptions}");
    println!("history            {history}");
    println!("download dir       {}", app.download_dir.display());
    Ok(())
}

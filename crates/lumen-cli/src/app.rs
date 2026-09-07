//! Everything a command needs, opened once.
//!
//! The CLI is a second front end over the same library and the same database
//! as the app — not a separate program that happens to share code. Anything it
//! writes (a favourite, an import, a history entry) shows up in the app on its
//! next read, and vice versa.

use std::path::PathBuf;
use std::sync::Arc;

use lumen_core::*;
use lumen_db::Database;
use lumen_downloader::DownloadManager;
use lumen_provider::WallhavenClient;
use lumen_setter::DesktopWallpaperSetter;

pub struct App {
    pub db: Arc<Database>,
    pub provider: WallhavenClient,
    pub downloads: DownloadManager,
    pub setter: DesktopWallpaperSetter,
    /// Where downloads land, resolved from preferences.
    pub download_dir: PathBuf,
    pub prefs: AppPreferences,
    /// Machine-readable output, for scripts and for the gate.
    pub json: bool,
}

impl App {
    pub fn open(json: bool) -> anyhow::Result<Self> {
        let data_dir = lumen_core::paths::data_dir();
        std::fs::create_dir_all(&data_dir)?;
        let db = Arc::new(Database::new(&lumen_core::paths::db_path())?);
        let prefs = db.get_preferences()?;

        // LUMEN_API_KEY wins, so a key can be supplied for one command without
        // being stored at all. Otherwise the keychain item the app writes.
        //
        // The first keychain read from a binary that is not the app prompts for
        // access; "Always Allow" makes it the last one. Declining leaves the
        // CLI unauthenticated, which is a working state, not an error.
        let api_key = std::env::var("LUMEN_API_KEY")
            .ok()
            .map(|k| k.trim().to_string())
            .filter(|k| !k.is_empty())
            .or_else(lumen_core::keychain::api_key);

        let download_dir = lumen_core::paths::resolve_dir(&prefs.download_dir);
        let concurrency = (prefs.max_parallel_downloads as usize).clamp(1, 12);

        Ok(Self {
            provider: WallhavenClient::new(api_key),
            downloads: DownloadManager::new(concurrency),
            setter: DesktopWallpaperSetter::new(),
            download_dir,
            prefs,
            db,
            json,
        })
    }

    /// Whether a key was found, without saying what it is.
    pub fn provider_has_key(&self) -> bool {
        self.api_key_source() != "not set"
    }

    /// Where the key in use came from — useful when the answer is "nowhere" and
    /// the user is sure they configured one.
    pub fn api_key_source(&self) -> &'static str {
        if std::env::var("LUMEN_API_KEY").is_ok_and(|k| !k.trim().is_empty()) {
            "set (LUMEN_API_KEY)"
        } else if lumen_core::keychain::api_key().is_some() {
            "set (keychain)"
        } else {
            "not set"
        }
    }

    /// Where a wallpaper Lumen has never downloaded is staged for setting.
    pub fn cache_dir(&self) -> anyhow::Result<PathBuf> {
        let dir = lumen_core::paths::cache_dir();
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    /// The filename the app uses, so both front ends find each other's files
    /// rather than downloading a second copy under a different name.
    pub fn filename_for(wallpaper: &Wallpaper) -> String {
        let extension = if wallpaper.file_type.ends_with("png") { "png" } else { "jpg" };
        format!("wallhaven-{}.{extension}", wallpaper.id)
    }

    /// A collection (the app's word) is a bookmark folder (the database's).
    pub fn collection_named(&self, name: &str) -> anyhow::Result<BookmarkFolder> {
        let folders = self.db.get_folders()?;
        folders
            .into_iter()
            .find(|f| f.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| anyhow::anyhow!("no collection named \"{name}\""))
    }

    /// An imported folder, by name or by path.
    pub fn folder_named(&self, name: &str) -> anyhow::Result<(uuid::Uuid, String, String, u32)> {
        let folders = self.db.imported_folders()?;
        folders
            .into_iter()
            .find(|(_, folder_name, path, _)| {
                folder_name.eq_ignore_ascii_case(name) || path == name
            })
            .ok_or_else(|| anyhow::anyhow!("no imported folder named \"{name}\""))
    }
}

use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::OptionalExtension;
use std::path::Path;
use tracing::info;
use uuid::Uuid;

use wallsetter_core::*;

pub struct Database {
    pool: Pool<SqliteConnectionManager>,
}

impl Database {
    pub fn new(db_path: &Path) -> wallsetter_core::Result<Self> {
        // Create parent directories if they don't exist
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(WallsetterError::Io)?;
        }

        let manager = SqliteConnectionManager::file(db_path);
        let pool =
            r2d2::Pool::new(manager).map_err(|e| WallsetterError::Database(e.to_string()))?;

        let db = Self { pool };
        db.init_schema()?;

        info!("Database initialized at {}", db_path.display());

        Ok(db)
    }

    fn init_schema(&self) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Wallpapers cache
        conn.execute(
            "CREATE TABLE IF NOT EXISTS wallpapers (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                data TEXT NOT NULL,
                last_updated DATETIME DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Bookmark Folders
        conn.execute(
            "CREATE TABLE IF NOT EXISTS bookmark_folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                icon TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Bookmarks
        conn.execute(
            "CREATE TABLE IF NOT EXISTS bookmarks (
                id TEXT PRIMARY KEY,
                wallpaper_id TEXT NOT NULL,
                provider TEXT NOT NULL,
                folder_id TEXT,
                added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                thumbnail_url TEXT NOT NULL,
                resolution_width INTEGER NOT NULL,
                resolution_height INTEGER NOT NULL,
                FOREIGN KEY(folder_id) REFERENCES bookmark_folders(id) ON DELETE SET NULL
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Preferences KV store
        conn.execute(
            "CREATE TABLE IF NOT EXISTS preferences (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Download History
        conn.execute(
            "CREATE TABLE IF NOT EXISTS download_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                wallpaper_id TEXT NOT NULL,
                provider TEXT NOT NULL,
                local_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                downloaded_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Download Folders
        conn.execute(
            "CREATE TABLE IF NOT EXISTS download_folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Local Wallpapers (downloaded files with folder organization)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS local_wallpapers (
                id TEXT PRIMARY KEY,
                folder_id TEXT REFERENCES download_folders(id) ON DELETE SET NULL,
                wallpaper_id TEXT NOT NULL,
                local_path TEXT NOT NULL,
                filename TEXT NOT NULL,
                resolution_width INTEGER NOT NULL,
                resolution_height INTEGER NOT NULL,
                file_size INTEGER NOT NULL,
                downloaded_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        Ok(())
    }

    // ──────────────────────────────────────────────
    // Bookmarks
    // ──────────────────────────────────────────────

    pub fn add_bookmark(&self, bookmark: &Bookmark) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        conn.execute(
            "INSERT OR REPLACE INTO bookmarks (
                id, wallpaper_id, provider, folder_id, added_at, thumbnail_url,
                resolution_width, resolution_height
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            (
                bookmark.id.to_string(),
                &bookmark.wallpaper_id,
                bookmark.provider.to_string(),
                bookmark.folder_id.map(|id| id.to_string()),
                bookmark.added_at.to_rfc3339(),
                &bookmark.thumbnail_url,
                bookmark.resolution.width,
                bookmark.resolution.height,
            ),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        Ok(())
    }

    pub fn remove_bookmark(&self, id: Uuid) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute("DELETE FROM bookmarks WHERE id = ?1", [id.to_string()])
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    pub fn get_bookmarks(&self, folder_id: Option<Uuid>) -> wallsetter_core::Result<Vec<Bookmark>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut stmt = if let Some(_fid) = folder_id {
            conn.prepare("SELECT * FROM bookmarks WHERE folder_id = ?1 ORDER BY added_at DESC")
                .map_err(|e| WallsetterError::Database(e.to_string()))?
        } else {
            conn.prepare("SELECT * FROM bookmarks ORDER BY added_at DESC")
                .map_err(|e| WallsetterError::Database(e.to_string()))?
        };

        let params: Vec<rusqlite::types::Value> = match folder_id {
            Some(fid) => vec![fid.to_string().into()],
            None => vec![],
        };

        let iter = stmt
            .query_map(rusqlite::params_from_iter(params), |row| {
                let id_str: String = row.get("id")?;
                let id = Uuid::parse_str(&id_str).unwrap_or_default();

                let fid_str: Option<String> = row.get("folder_id")?;
                let folder_id = fid_str.and_then(|s| Uuid::parse_str(&s).ok());

                let added_at_str: String = row.get("added_at")?;
                let added_at = chrono::DateTime::parse_from_rfc3339(&added_at_str)
                    .map(|dt| dt.with_timezone(&chrono::Utc))
                    .unwrap_or_else(|_| chrono::Utc::now());

                let provider_str: String = row.get("provider")?;
                let provider = if provider_str == "wallhaven" {
                    WallpaperProvider::Wallhaven
                } else {
                    WallpaperProvider::Wallhaven
                };

                Ok(Bookmark {
                    id,
                    wallpaper_id: row.get("wallpaper_id")?,
                    provider,
                    folder_id,
                    added_at,
                    thumbnail_url: row.get("thumbnail_url")?,
                    resolution: Resolution {
                        width: row.get("resolution_width")?,
                        height: row.get("resolution_height")?,
                    },
                })
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut bookmarks = Vec::new();
        for b in iter {
            bookmarks.push(b.map_err(|e| WallsetterError::Database(e.to_string()))?);
        }

        Ok(bookmarks)
    }

    pub fn is_bookmarked(&self, wallpaper_id: &str) -> wallsetter_core::Result<bool> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(1) FROM bookmarks WHERE wallpaper_id = ?1",
                [wallpaper_id],
                |row| row.get(0),
            )
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(count > 0)
    }

    // ──────────────────────────────────────────────
    // Folders
    // ──────────────────────────────────────────────

    pub fn add_folder(&self, folder: &BookmarkFolder) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        conn.execute(
            "INSERT INTO bookmark_folders (id, name, description, icon, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            (
                folder.id.to_string(),
                &folder.name,
                &folder.description,
                &folder.icon,
                folder.created_at.to_rfc3339(),
            ),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        Ok(())
    }

    pub fn get_folders(&self) -> wallsetter_core::Result<Vec<BookmarkFolder>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut stmt = conn
            .prepare("SELECT * FROM bookmark_folders ORDER BY name ASC")
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let iter = stmt
            .query_map([], |row| {
                let id_str: String = row.get("id")?;
                let id = Uuid::parse_str(&id_str).unwrap_or_default();

                let created_at_str: String = row.get("created_at")?;
                let created_at = chrono::DateTime::parse_from_rfc3339(&created_at_str)
                    .map(|dt| dt.with_timezone(&chrono::Utc))
                    .unwrap_or_else(|_| chrono::Utc::now());

                Ok(BookmarkFolder {
                    id,
                    name: row.get("name")?,
                    description: row.get("description")?,
                    icon: row.get("icon")?,
                    created_at,
                })
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut folders = Vec::new();
        for f in iter {
            folders.push(f.map_err(|e| WallsetterError::Database(e.to_string()))?);
        }

        Ok(folders)
    }

    // ──────────────────────────────────────────────
    // Preferences
    // ──────────────────────────────────────────────

    pub fn get_preferences(&self) -> wallsetter_core::Result<AppPreferences> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let json: Option<String> = conn
            .query_row(
                "SELECT value FROM preferences WHERE key = 'app_preferences'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        if let Some(data) = json {
            serde_json::from_str(&data).map_err(|e| WallsetterError::Json(e))
        } else {
            Ok(AppPreferences::default())
        }
    }

    pub fn save_preferences(&self, prefs: &AppPreferences) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let json = serde_json::to_string(prefs).map_err(|e| WallsetterError::Json(e))?;

        conn.execute(
            "INSERT OR REPLACE INTO preferences (key, value) VALUES ('app_preferences', ?1)",
            [json],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        Ok(())
    }

    // ──────────────────────────────────────────────
    // Wallpaper Cache
    // ──────────────────────────────────────────────

    pub fn cache_wallpaper(&self, wallpaper: &Wallpaper) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let json = serde_json::to_string(wallpaper).map_err(|e| WallsetterError::Json(e))?;

        conn.execute(
            "INSERT OR REPLACE INTO wallpapers (id, provider, data) VALUES (?1, ?2, ?3)",
            (&wallpaper.id, wallpaper.provider.to_string(), json),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        Ok(())
    }

    pub fn get_cached_wallpaper(&self, id: &str) -> wallsetter_core::Result<Option<Wallpaper>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let json: Option<String> = conn
            .query_row("SELECT data FROM wallpapers WHERE id = ?1", [id], |row| {
                row.get(0)
            })
            .optional()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        if let Some(data) = json {
            let wp = serde_json::from_str(&data).map_err(|e| WallsetterError::Json(e))?;
            Ok(Some(wp))
        } else {
            Ok(None)
        }
    }

    // ──────────────────────────────────────────────
    // Download History
    // ──────────────────────────────────────────────

    pub fn add_download_record(&self, record: &DownloadRecord) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        conn.execute(
            "INSERT INTO download_history (wallpaper_id, provider, local_path, file_size, downloaded_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            (
                &record.wallpaper_id,
                record.provider.to_string(),
                &record.local_path,
                record.file_size,
                record.downloaded_at.to_rfc3339(),
            ),
        ).map_err(|e| WallsetterError::Database(e.to_string()))?;

        Ok(())
    }

    pub fn get_download_records(&self, limit: u32) -> wallsetter_core::Result<Vec<DownloadRecord>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut stmt = conn
            .prepare("SELECT * FROM download_history ORDER BY downloaded_at DESC LIMIT ?1")
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let iter = stmt
            .query_map([limit], |row| {
                let dt_str: String = row.get("downloaded_at")?;
                let downloaded_at = chrono::DateTime::parse_from_rfc3339(&dt_str)
                    .map(|dt| dt.with_timezone(&chrono::Utc))
                    .unwrap_or_else(|_| chrono::Utc::now());

                let provider_str: String = row.get("provider")?;
                let provider = if provider_str == "wallhaven" {
                    WallpaperProvider::Wallhaven
                } else {
                    WallpaperProvider::Wallhaven
                };

                Ok(DownloadRecord {
                    wallpaper_id: row.get("wallpaper_id")?,
                    provider,
                    local_path: row.get("local_path")?,
                    file_size: row.get("file_size")?,
                    downloaded_at,
                })
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut records = Vec::new();
        for r in iter {
            records.push(r.map_err(|e| WallsetterError::Database(e.to_string()))?);
        }

        Ok(records)
    }

    // ──────────────────────────────────────────────
    // Download Folders
    // ──────────────────────────────────────────────

    pub fn add_download_folder(&self, folder: &DownloadFolder) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "INSERT INTO download_folders (id, name, created_at) VALUES (?1, ?2, ?3)",
            (
                folder.id.to_string(),
                &folder.name,
                folder.created_at.to_rfc3339(),
            ),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    pub fn get_download_folders(&self) -> wallsetter_core::Result<Vec<DownloadFolder>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT * FROM download_folders ORDER BY name ASC")
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let iter = stmt
            .query_map([], |row| {
                let id_str: String = row.get("id")?;
                let id = Uuid::parse_str(&id_str).unwrap_or_default();
                let created_at_str: String = row.get("created_at")?;
                let created_at = chrono::DateTime::parse_from_rfc3339(&created_at_str)
                    .map(|dt| dt.with_timezone(&chrono::Utc))
                    .unwrap_or_else(|_| chrono::Utc::now());
                Ok(DownloadFolder {
                    id,
                    name: row.get("name")?,
                    created_at,
                })
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let mut folders = Vec::new();
        for f in iter {
            folders.push(f.map_err(|e| WallsetterError::Database(e.to_string()))?);
        }
        Ok(folders)
    }

    pub fn get_download_folder_by_id(
        &self,
        id: Uuid,
    ) -> wallsetter_core::Result<Option<DownloadFolder>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let result = conn
            .query_row(
                "SELECT * FROM download_folders WHERE id = ?1",
                [id.to_string()],
                |row| {
                    let id_str: String = row.get("id")?;
                    let id = Uuid::parse_str(&id_str).unwrap_or_default();
                    let created_at_str: String = row.get("created_at")?;
                    let created_at = chrono::DateTime::parse_from_rfc3339(&created_at_str)
                        .map(|dt| dt.with_timezone(&chrono::Utc))
                        .unwrap_or_else(|_| chrono::Utc::now());
                    Ok(DownloadFolder {
                        id,
                        name: row.get("name")?,
                        created_at,
                    })
                },
            )
            .optional()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(result)
    }

    pub fn delete_download_folder(&self, id: Uuid) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "DELETE FROM download_folders WHERE id = ?1",
            [id.to_string()],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    // ──────────────────────────────────────────────
    // Local Wallpapers
    // ──────────────────────────────────────────────

    pub fn add_local_wallpaper(&self, lw: &LocalWallpaper) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "INSERT OR REPLACE INTO local_wallpapers
             (id, folder_id, wallpaper_id, local_path, filename, resolution_width,
              resolution_height, file_size, downloaded_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            (
                lw.id.to_string(),
                lw.folder_id.map(|id| id.to_string()),
                &lw.wallpaper_id,
                &lw.local_path,
                &lw.filename,
                lw.resolution.width,
                lw.resolution.height,
                lw.file_size,
                lw.downloaded_at.to_rfc3339(),
            ),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    pub fn get_local_wallpapers(
        &self,
        folder_id: Option<Uuid>,
    ) -> wallsetter_core::Result<Vec<LocalWallpaper>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let sql = if folder_id.is_some() {
            "SELECT * FROM local_wallpapers WHERE folder_id = ?1 ORDER BY downloaded_at DESC"
        } else {
            "SELECT * FROM local_wallpapers ORDER BY downloaded_at DESC"
        };

        let mut stmt = conn
            .prepare(sql)
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let params: Vec<rusqlite::types::Value> = match folder_id {
            Some(fid) => vec![fid.to_string().into()],
            None => vec![],
        };

        let iter = stmt
            .query_map(rusqlite::params_from_iter(params), |row| {
                let id_str: String = row.get("id")?;
                let id = Uuid::parse_str(&id_str).unwrap_or_default();
                let fid_str: Option<String> = row.get("folder_id")?;
                let folder_id = fid_str.and_then(|s| Uuid::parse_str(&s).ok());
                let dt_str: String = row.get("downloaded_at")?;
                let downloaded_at = chrono::DateTime::parse_from_rfc3339(&dt_str)
                    .map(|dt| dt.with_timezone(&chrono::Utc))
                    .unwrap_or_else(|_| chrono::Utc::now());
                Ok(LocalWallpaper {
                    id,
                    folder_id,
                    wallpaper_id: row.get("wallpaper_id")?,
                    local_path: row.get("local_path")?,
                    filename: row.get("filename")?,
                    resolution: Resolution {
                        width: row.get("resolution_width")?,
                        height: row.get("resolution_height")?,
                    },
                    file_size: row.get("file_size")?,
                    downloaded_at,
                })
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut result = Vec::new();
        for lw in iter {
            result.push(lw.map_err(|e| WallsetterError::Database(e.to_string()))?);
        }
        Ok(result)
    }

    pub fn move_local_wallpaper(
        &self,
        id: Uuid,
        new_folder_id: Option<Uuid>,
        new_local_path: &str,
    ) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "UPDATE local_wallpapers SET folder_id = ?1, local_path = ?2 WHERE id = ?3",
            (
                new_folder_id.map(|fid| fid.to_string()),
                new_local_path,
                id.to_string(),
            ),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    pub fn remove_local_wallpaper(&self, id: Uuid) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "DELETE FROM local_wallpapers WHERE id = ?1",
            [id.to_string()],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }
}

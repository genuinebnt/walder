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

        // Every pooled connection needs these: SQLite applies pragmas per
        // connection, and the defaults leave foreign keys unenforced and no
        // busy timeout, so a concurrent writer surfaces as SQLITE_BUSY.
        let manager = SqliteConnectionManager::file(db_path).with_init(|conn| {
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA synchronous = NORMAL;
                 PRAGMA foreign_keys = ON;
                 PRAGMA busy_timeout = 5000;
                 PRAGMA temp_store = MEMORY;",
            )
        });
        let pool = r2d2::Pool::builder()
            .max_size(8)
            .build(manager)
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

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

        // Collection membership. A wallpaper can sit in several collections,
        // and being in one is independent of being a favourite, so this is a
        // join table rather than a column on bookmarks.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS collection_items (
                collection_id TEXT NOT NULL
                    REFERENCES bookmark_folders(id) ON DELETE CASCADE,
                wallpaper_id TEXT NOT NULL,
                added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (collection_id, wallpaper_id)
            )",
            [],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;

        // Indices for the columns the app actually filters and joins on.
        // Without them every favourite check is a full scan of bookmarks.
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_bookmarks_wallpaper
                 ON bookmarks(wallpaper_id);
             CREATE INDEX IF NOT EXISTS idx_bookmarks_folder_added
                 ON bookmarks(folder_id, added_at DESC);
             CREATE INDEX IF NOT EXISTS idx_bookmarks_added
                 ON bookmarks(added_at DESC);
             CREATE INDEX IF NOT EXISTS idx_history_wallpaper
                 ON download_history(wallpaper_id);
             CREATE INDEX IF NOT EXISTS idx_history_downloaded
                 ON download_history(downloaded_at DESC);
             CREATE INDEX IF NOT EXISTS idx_local_folder
                 ON local_wallpapers(folder_id);
             CREATE INDEX IF NOT EXISTS idx_local_path
                 ON local_wallpapers(local_path);
             CREATE INDEX IF NOT EXISTS idx_wallpapers_updated
                 ON wallpapers(last_updated);
             CREATE INDEX IF NOT EXISTS idx_collection_items_wallpaper
                 ON collection_items(wallpaper_id);
             CREATE INDEX IF NOT EXISTS idx_collection_items_added
                 ON collection_items(collection_id, added_at DESC);",
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

    /// Bookmarked wallpapers, newest first, in one query.
    ///
    /// Reading the bookmarks and then fetching each cached wallpaper by id is
    /// a round trip per favourite; this joins instead. Bookmarks whose cache
    /// row was evicted are skipped rather than failing the whole read.
    pub fn get_bookmarked_wallpapers(
        &self,
        folder_id: Option<Uuid>,
    ) -> wallsetter_core::Result<Vec<Wallpaper>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let sql = if folder_id.is_some() {
            "SELECT w.data FROM bookmarks b
                 JOIN wallpapers w ON w.id = b.wallpaper_id
                 WHERE b.folder_id = ?1
                 ORDER BY b.added_at DESC"
        } else {
            "SELECT w.data FROM bookmarks b
                 JOIN wallpapers w ON w.id = b.wallpaper_id
                 ORDER BY b.added_at DESC"
        };

        let mut stmt = conn
            .prepare(sql)
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let params: Vec<rusqlite::types::Value> = match folder_id {
            Some(fid) => vec![fid.to_string().into()],
            None => vec![],
        };

        let rows = stmt
            .query_map(rusqlite::params_from_iter(params), |row| {
                row.get::<_, String>(0)
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut wallpapers = Vec::new();
        for row in rows {
            let json = row.map_err(|e| WallsetterError::Database(e.to_string()))?;
            match serde_json::from_str::<Wallpaper>(&json) {
                Ok(w) => wallpapers.push(w),
                // A row written by an older schema should not break the list.
                Err(e) => tracing::warn!("skipping unreadable cached wallpaper: {e}"),
            }
        }
        Ok(wallpapers)
    }

    // ──────────────────────────────────────────────
    // Collection membership
    // ──────────────────────────────────────────────

    /// Files a wallpaper into a collection. Adding it twice is a no-op.
    pub fn add_to_collection(
        &self,
        collection_id: Uuid,
        wallpaper_id: &str,
    ) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "INSERT OR IGNORE INTO collection_items (collection_id, wallpaper_id)
             VALUES (?1, ?2)",
            (collection_id.to_string(), wallpaper_id),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    pub fn remove_from_collection(
        &self,
        collection_id: Uuid,
        wallpaper_id: &str,
    ) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "DELETE FROM collection_items WHERE collection_id = ?1 AND wallpaper_id = ?2",
            (collection_id.to_string(), wallpaper_id),
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    /// The wallpapers in one collection, newest first.
    pub fn get_collection_wallpapers(
        &self,
        collection_id: Uuid,
    ) -> wallsetter_core::Result<Vec<Wallpaper>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let mut stmt = conn
            .prepare(
                "SELECT w.data FROM collection_items c
                     JOIN wallpapers w ON w.id = c.wallpaper_id
                     WHERE c.collection_id = ?1
                     ORDER BY c.added_at DESC",
            )
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let rows = stmt
            .query_map([collection_id.to_string()], |row| row.get::<_, String>(0))
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut wallpapers = Vec::new();
        for row in rows {
            let json = row.map_err(|e| WallsetterError::Database(e.to_string()))?;
            match serde_json::from_str::<Wallpaper>(&json) {
                Ok(w) => wallpapers.push(w),
                Err(e) => tracing::warn!("skipping unreadable cached wallpaper: {e}"),
            }
        }
        Ok(wallpapers)
    }

    /// How many wallpapers each collection holds, in one query rather than one
    /// per collection.
    pub fn collection_counts(
        &self,
    ) -> wallsetter_core::Result<std::collections::HashMap<Uuid, u32>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let mut stmt = conn
            .prepare(
                "SELECT collection_id, COUNT(1) FROM collection_items
                     GROUP BY collection_id",
            )
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?))
            })
            .map_err(|e| WallsetterError::Database(e.to_string()))?;

        let mut counts = std::collections::HashMap::new();
        for row in rows {
            let (id, count) = row.map_err(|e| WallsetterError::Database(e.to_string()))?;
            if let Ok(uuid) = Uuid::parse_str(&id) {
                counts.insert(uuid, count);
            }
        }
        Ok(counts)
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

    pub fn delete_bookmark_folder(&self, id: Uuid) -> wallsetter_core::Result<()> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.execute(
            "DELETE FROM bookmark_folders WHERE id = ?1",
            [id.to_string()],
        )
        .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
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

    /// Caches a page of results in one transaction.
    ///
    /// Caching them one at a time is one implicit transaction per row, so a
    /// 24-result page paid 24 commits before the UI saw anything.
    pub fn cache_wallpapers(&self, wallpapers: &[Wallpaper]) -> wallsetter_core::Result<()> {
        if wallpapers.is_empty() {
            return Ok(());
        }
        let mut conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let transaction = conn
            .transaction()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        {
            let mut stmt = transaction
                .prepare_cached(
                    "INSERT OR REPLACE INTO wallpapers (id, provider, data) VALUES (?1, ?2, ?3)",
                )
                .map_err(|e| WallsetterError::Database(e.to_string()))?;
            for wallpaper in wallpapers {
                let json = serde_json::to_string(wallpaper).map_err(WallsetterError::Json)?;
                stmt.execute((&wallpaper.id, wallpaper.provider.to_string(), json))
                    .map_err(|e| WallsetterError::Database(e.to_string()))?;
            }
        }
        transaction
            .commit()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        Ok(())
    }

    /// Number of rows in the wallpaper cache, so callers can prune on a
    /// threshold rather than after every search.
    pub fn wallpaper_cache_count(&self) -> wallsetter_core::Result<u32> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        conn.query_row("SELECT COUNT(1) FROM wallpapers", [], |row| row.get(0))
            .map_err(|e| WallsetterError::Database(e.to_string()))
    }

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

    /// Trims the wallpaper cache to `keep` most-recent rows, never evicting a
    /// row a bookmark points at.
    ///
    /// Every search result is cached, so browsing for a while grows this table
    /// without limit; bookmarks read through it, so eviction has to spare them.
    pub fn prune_wallpaper_cache(&self, keep: u32) -> wallsetter_core::Result<usize> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let removed = conn
            .execute(
                "DELETE FROM wallpapers
                 WHERE id NOT IN (SELECT wallpaper_id FROM bookmarks)
                   AND id NOT IN (
                       SELECT id FROM wallpapers
                       ORDER BY last_updated DESC
                       LIMIT ?1
                   )",
                [keep],
            )
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        if removed > 0 {
            info!("Pruned {removed} cached wallpapers");
        }
        Ok(removed)
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

    /// Returns the set of local_paths already tracked, for deduplication.
    pub fn get_tracked_local_paths(&self) -> wallsetter_core::Result<std::collections::HashSet<String>> {
        let conn = self
            .pool
            .get()
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let mut stmt = conn
            .prepare("SELECT local_path FROM local_wallpapers")
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let iter = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| WallsetterError::Database(e.to_string()))?;
        let mut paths = std::collections::HashSet::new();
        for p in iter {
            paths.insert(p.map_err(|e| WallsetterError::Database(e.to_string()))?);
        }
        Ok(paths)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wallsetter_core::{Category, Purity, Resolution, WallpaperProvider};

    fn temp_db() -> (Database, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("temp dir");
        let db = Database::new(&dir.path().join("test.db")).expect("open db");
        (db, dir)
    }

    fn wallpaper(id: &str) -> Wallpaper {
        Wallpaper {
            id: id.into(),
            provider: WallpaperProvider::Wallhaven,
            url: format!("https://wallhaven.cc/w/{id}"),
            short_url: None,
            full_url: format!("https://w.wallhaven.cc/full/{id}.jpg"),
            thumbnail_small: String::new(),
            thumbnail_large: String::new(),
            thumbnail_original: String::new(),
            uploader: None,
            resolution: Resolution::new(1920, 1080),
            file_size: 1024,
            file_type: "image/jpeg".into(),
            category: Category::General,
            purity: Purity::Sfw,
            colors: Vec::new(),
            tags: Vec::new(),
            source: None,
            views: 0,
            favorites: 0,
            ratio: 1.777,
            created_at: None,
        }
    }

    #[test]
    fn pragmas_are_applied_to_pooled_connections() {
        let (db, _dir) = temp_db();
        let conn = db.pool.get().expect("connection");

        let journal: String = conn
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .expect("journal_mode");
        assert_eq!(journal.to_lowercase(), "wal");

        // Declared foreign keys are inert unless this is on.
        let foreign_keys: i64 = conn
            .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
            .expect("foreign_keys");
        assert_eq!(foreign_keys, 1);
    }

    #[test]
    fn bookmarked_wallpapers_come_back_newest_first() {
        let (db, _dir) = temp_db();
        for id in ["aaa", "bbb", "ccc"] {
            let w = wallpaper(id);
            db.cache_wallpaper(&w).expect("cache");
            db.add_bookmark(&Bookmark::new(&w, None)).expect("bookmark");
            // added_at has one-second resolution, so order the inserts.
            std::thread::sleep(std::time::Duration::from_millis(1100));
        }

        let saved = db.get_bookmarked_wallpapers(None).expect("join");
        let ids: Vec<&str> = saved.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(ids, vec!["ccc", "bbb", "aaa"]);
    }

    #[test]
    fn a_bookmark_without_a_cached_wallpaper_is_skipped_not_fatal() {
        let (db, _dir) = temp_db();
        let present = wallpaper("here");
        db.cache_wallpaper(&present).expect("cache");
        db.add_bookmark(&Bookmark::new(&present, None)).expect("bookmark");

        // A bookmark whose cache row was evicted must not fail the whole read.
        let orphan = wallpaper("gone");
        db.cache_wallpaper(&orphan).expect("cache");
        db.add_bookmark(&Bookmark::new(&orphan, None)).expect("bookmark");
        db.pool
            .get()
            .unwrap()
            .execute("DELETE FROM wallpapers WHERE id = 'gone'", [])
            .expect("evict");

        let saved = db.get_bookmarked_wallpapers(None).expect("join");
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].id, "here");
    }

    #[test]
    fn pruning_bounds_the_cache_but_spares_bookmarks() {
        let (db, _dir) = temp_db();
        for index in 0..20 {
            db.cache_wallpaper(&wallpaper(&format!("w{index:02}")))
                .expect("cache");
        }
        // The oldest row is bookmarked, so pruning must leave it alone.
        let pinned = wallpaper("w00");
        db.add_bookmark(&Bookmark::new(&pinned, None)).expect("bookmark");

        db.prune_wallpaper_cache(5).expect("prune");

        let remaining: i64 = db
            .pool
            .get()
            .unwrap()
            .query_row("SELECT COUNT(1) FROM wallpapers", [], |r| r.get(0))
            .expect("count");
        assert!(remaining <= 6, "expected at most 5 cached + 1 pinned, got {remaining}");
        assert!(
            db.get_cached_wallpaper("w00").expect("lookup").is_some(),
            "a bookmarked wallpaper must survive pruning"
        );
    }

    #[test]
    fn is_bookmarked_tracks_add_and_remove() {
        let (db, _dir) = temp_db();
        let w = wallpaper("toggle");
        db.cache_wallpaper(&w).expect("cache");
        assert!(!db.is_bookmarked("toggle").expect("check"));

        let bookmark = Bookmark::new(&w, None);
        db.add_bookmark(&bookmark).expect("add");
        assert!(db.is_bookmarked("toggle").expect("check"));

        db.remove_bookmark(bookmark.id).expect("remove");
        assert!(!db.is_bookmarked("toggle").expect("check"));
    }

    #[test]
    fn collection_membership_survives_and_counts() {
        let (db, _dir) = temp_db();
        let folder = BookmarkFolder::new("Desert");
        db.add_folder(&folder).expect("folder");

        for id in ["one", "two"] {
            db.cache_wallpaper(&wallpaper(id)).expect("cache");
            db.add_to_collection(folder.id, id).expect("file");
        }
        // Filing the same wallpaper twice must not duplicate it.
        db.add_to_collection(folder.id, "one").expect("file again");

        let items = db.get_collection_wallpapers(folder.id).expect("read");
        assert_eq!(items.len(), 2);
        assert_eq!(db.collection_counts().expect("counts")[&folder.id], 2);

        db.remove_from_collection(folder.id, "one").expect("unfile");
        assert_eq!(db.get_collection_wallpapers(folder.id).expect("read").len(), 1);
    }

    #[test]
    fn collection_membership_is_independent_of_favourites() {
        let (db, _dir) = temp_db();
        let folder = BookmarkFolder::new("Night");
        db.add_folder(&folder).expect("folder");
        let w = wallpaper("shared");
        db.cache_wallpaper(&w).expect("cache");

        db.add_to_collection(folder.id, "shared").expect("file");
        assert!(!db.is_bookmarked("shared").expect("check"),
                "filing into a collection must not favourite it");

        db.add_bookmark(&Bookmark::new(&w, None)).expect("favourite");
        assert_eq!(db.get_collection_wallpapers(folder.id).expect("read").len(), 1,
                   "favouriting must not disturb collection membership");
    }

    #[test]
    fn deleting_a_collection_takes_its_membership_but_not_the_wallpapers() {
        let (db, _dir) = temp_db();
        let folder = BookmarkFolder::new("Temporary");
        db.add_folder(&folder).expect("folder");
        db.cache_wallpaper(&wallpaper("keep")).expect("cache");
        db.add_to_collection(folder.id, "keep").expect("file");

        db.delete_bookmark_folder(folder.id).expect("delete");

        assert!(db.get_collection_wallpapers(folder.id).expect("read").is_empty());
        assert!(db.get_cached_wallpaper("keep").expect("lookup").is_some(),
                "the wallpaper itself must outlive the collection");
    }
}

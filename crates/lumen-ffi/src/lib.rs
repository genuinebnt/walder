//! C ABI bridge between the Lumen SwiftUI front end and the Rust backend.
//!
//! Shape of the bridge:
//!   * one process-wide `Core` holding the tokio runtime, provider, database
//!     and download manager;
//!   * request/response calls return a `u64` request id immediately and deliver
//!     their JSON envelope through the callback Swift registered;
//!   * unsolicited pushes (download progress) arrive on the same callback with
//!     request id `0`.
//!
//! Every string crossing the boundary is UTF-8 and NUL-terminated. Strings the
//! Rust side allocates must be handed back to [`lumen_string_free`].

// Public so the CLI can write a downloaded file's sidecar in exactly the shape
// the app reads it back in, rather than keeping a second definition of it.
pub mod dto;

use dto::*;
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};
use tokio::runtime::Runtime;
use lumen_core::*;
use lumen_db::Database;
use lumen_downloader::DownloadManager;
use lumen_provider::wallhaven::WallhavenClient;

// ── callback plumbing ─────────────────────────────────────────────────────

/// `(request_id, json)` — `json` is owned by Rust and valid only for the call.
pub type LumenCallback = extern "C" fn(u64, *const c_char, *mut std::ffi::c_void);

struct Sink {
    callback: LumenCallback,
    ctx: *mut std::ffi::c_void,
}

// The Swift side hops to the main actor before touching anything; the context
// pointer is an immortal, thread-safe box.
unsafe impl Send for Sink {}
unsafe impl Sync for Sink {}

static SINK: RwLock<Option<Sink>> = RwLock::new(None);
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn emit(request_id: u64, json: String) {
    let guard = SINK.read().unwrap();
    let Some(sink) = guard.as_ref() else { return };
    let Ok(c) = CString::new(json) else { return };
    (sink.callback)(request_id, c.as_ptr(), sink.ctx);
}

fn next_id() -> u64 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

// ── core state ────────────────────────────────────────────────────────────

struct Core {
    runtime: Runtime,
    provider: RwLock<WallhavenClient>,
    db: Database,
    downloads: DownloadManager,
    download_dir: RwLock<PathBuf>,
    /// Where `lumen_ensure_local` stages files. Kept apart from the download
    /// directory so setting a wallpaper can never race the download manager
    /// writing the same path.
    cache_dir: PathBuf,
}

/// Cached search results kept on disk. Bookmarked wallpapers are never
/// evicted, so this only bounds the browsing cache.
const WALLPAPER_CACHE_LIMIT: u32 = 5_000;
/// How far over the limit the cache may drift before a prune runs, so pruning
/// happens once every few hundred results rather than on every search.
const PRUNE_SLACK: u32 = 500;

static CORE: OnceLock<Core> = OnceLock::new();
static INIT_ERROR: Mutex<Option<String>> = Mutex::new(None);

fn core() -> Option<&'static Core> {
    CORE.get()
}

/// Expands a leading `~` and falls back to `~/Pictures/Lumen`.
// ── string helpers ────────────────────────────────────────────────────────

/// # Safety
/// `ptr` must be NUL-terminated UTF-8, or null.
unsafe fn str_from(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"nul in payload\"}").unwrap())
        .into_raw()
}

/// Frees a string returned by any `lumen_*` function.
///
/// # Safety
/// `ptr` must have come from this library and not been freed already.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

// ── lifecycle ─────────────────────────────────────────────────────────────

/// Boots the runtime, database and download manager. Idempotent.
///
/// `config_json`: `{ "apiKey": String, "downloadDir": String, "maxParallel": Int }`
/// Returns a JSON envelope; caller frees with [`lumen_string_free`].
///
/// # Safety
/// `config_json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_init(config_json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(config_json) };
    let cfg: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);

    let api_key = cfg
        .get("apiKey")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let dir = lumen_core::paths::resolve_dir(cfg.get("downloadDir").and_then(|v| v.as_str()).unwrap_or(""));
    let max_parallel = cfg
        .get("maxParallel")
        .and_then(|v| v.as_u64())
        .unwrap_or(4)
        .clamp(1, 12) as usize;

    if let Some(core) = core() {
        // Already running — treat as a reconfigure.
        core.provider.write().unwrap().set_api_key(api_key);
        *core.download_dir.write().unwrap() = dir;
        core.downloads.set_max_concurrent(max_parallel);
        persist_preferences(core);
        return to_c(serde_json::json!({ "ok": true, "kind": "init", "data": "reconfigured" }).to_string());
    }

    let built = (|| -> lumen_core::Result<Core> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(4)
            .build()
            .map_err(|e| LumenError::Other(format!("runtime: {e}")))?;

        let data_dir = lumen_core::paths::data_dir();
        std::fs::create_dir_all(&data_dir)?;
        std::fs::create_dir_all(&dir)?;

        let db = Database::new(&lumen_core::paths::db_path())?;

        let cache_dir = lumen_core::paths::cache_dir();
        std::fs::create_dir_all(&cache_dir)?;

        Ok(Core {
            provider: RwLock::new(WallhavenClient::new(api_key)),
            db,
            downloads: DownloadManager::new(max_parallel),
            download_dir: RwLock::new(dir),
            cache_dir,
            runtime,
        })
    })();

    match built {
        Ok(c) => {
            let core = CORE.get_or_init(|| c);
            // A library imported before subpaths existed would otherwise stay
            // flat until the user thought to rescan.
            let _ = core.db.backfill_subpaths();
            persist_preferences(core);
            ensure_downloads_indexed(core);
            spawn_download_watch(core);
            to_c(serde_json::json!({ "ok": true, "kind": "init", "data": "started" }).to_string())
        }
        Err(e) => {
            *INIT_ERROR.lock().unwrap() = Some(e.to_string());
            to_c(err_json("init", e))
        }
    }
}

/// Registers the single callback used for async results and progress pushes.
///
/// # Safety
/// `callback` must stay valid for the process lifetime, as must `ctx`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_set_callback(callback: LumenCallback, ctx: *mut std::ffi::c_void) {
    *SINK.write().unwrap() = Some(Sink { callback, ctx });
}

/// Streams download-manager state to Swift as it changes.
fn spawn_download_watch(core: &'static Core) {
    let mut rx = core.downloads.subscribe();
    core.runtime.spawn(async move {
        while rx.changed().await.is_ok() {
            let tasks: Vec<DownloadDto> =
                rx.borrow().iter().map(DownloadDto::from_task).collect();
            emit(0, serde_json::to_string(&Envelope::ok("downloads", tasks)).unwrap_or_default());
        }
    });
}

// ── search ────────────────────────────────────────────────────────────────

/// Searches Wallhaven. Result arrives on the callback as `kind: "search"`.
///
/// # Safety
/// `filters_json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_search(filters_json: *const c_char) -> u64 {
    let raw = unsafe { str_from(filters_json) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("search", "core not initialised"));
        return id;
    };

    let filters = match serde_json::from_str::<FiltersDto>(&raw) {
        Ok(f) => f.into_core(),
        Err(e) => {
            emit(id, err_json("search", format!("bad filters: {e}")));
            return id;
        }
    };

    core.runtime.spawn(async move {
        let result = {
            let client = core.provider.read().unwrap().clone();
            client.search(&filters).await
        };
        match result {
            Ok(page) => {
                let _ = core.db.cache_wallpapers(&page.wallpapers);
                // Pruning scans the table, so do it when the cache has actually
                // grown past the limit rather than on every search.
                if core
                    .db
                    .wallpaper_cache_count()
                    .is_ok_and(|count| count > WALLPAPER_CACHE_LIMIT + PRUNE_SLACK)
                {
                    let _ = core.db.prune_wallpaper_cache(WALLPAPER_CACHE_LIMIT);
                }
                let dto = SearchPageDto::from(&page);
                emit(id, serde_json::to_string(&Envelope::ok("search", dto)).unwrap_or_default());
            }
            Err(e) => emit(id, err_json("search", e)),
        }
    });
    id
}

/// Fetches one wallpaper's full record (tags, uploader). Callback `kind: "details"`.
///
/// # Safety
/// `id_str` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_details(id_str: *const c_char) -> u64 {
    let wallpaper_id = unsafe { str_from(id_str) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("details", "core not initialised"));
        return id;
    };

    core.runtime.spawn(async move {
        let result = {
            let client = core.provider.read().unwrap().clone();
            client.get_wallpaper(&wallpaper_id).await
        };
        match result {
            Ok(w) => {
                let _ = core.db.cache_wallpaper(&w);
                let dto = WallpaperDto::from(&w);
                emit(id, serde_json::to_string(&Envelope::ok("details", dto)).unwrap_or_default());
            }
            Err(e) => emit(id, err_json("details", e)),
        }
    });
    id
}

// ── uploader and tags ─────────────────────────────────────────────────────

/// An uploader's public collections. Callback `kind: "uploaderCollections"`.
///
/// # Safety
/// `username` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_uploader_collections(username: *const c_char) -> u64 {
    let name = unsafe { str_from(username) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("uploaderCollections", "core not initialised"));
        return id;
    };
    if name.trim().is_empty() {
        emit(id, err_json("uploaderCollections", "username is required"));
        return id;
    }

    core.runtime.spawn(async move {
        let client = core.provider.read().unwrap().clone();
        match client.get_collections(Some(&name)).await {
            Ok(found) => {
                let list: Vec<UploaderCollectionDto> = found
                    .iter()
                    .map(|c| UploaderCollectionDto {
                        id: c.id as i64,
                        label: c.label.clone(),
                        count: c.count as i64,
                        views: c.views as i64,
                        public: c.public,
                    })
                    .collect();
                emit(
                    id,
                    serde_json::to_string(&Envelope::ok("uploaderCollections", list))
                        .unwrap_or_default(),
                );
            }
            Err(e) => emit(id, err_json("uploaderCollections", e)),
        }
    });
    id
}

/// The wallpapers in one of an uploader's collections. Callback `kind: "search"`.
///
/// `json`: `{ "username": String, "collectionId": Int, "page": Int }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_uploader_collection_wallpapers(json: *const c_char) -> u64 {
    let raw = unsafe { str_from(json) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("search", "core not initialised"));
        return id;
    };

    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let username = value["username"].as_str().unwrap_or_default().to_string();
    let collection_id = value["collectionId"].as_u64().unwrap_or_default();
    let page = value["page"].as_u64().unwrap_or(1).max(1) as u32;
    if username.is_empty() || collection_id == 0 {
        emit(id, err_json("search", "username and collectionId are required"));
        return id;
    }

    core.runtime.spawn(async move {
        let client = core.provider.read().unwrap().clone();
        match client
            .get_collection_wallpapers(&username, collection_id, page)
            .await
        {
            Ok(result) => {
                let _ = core.db.cache_wallpapers(&result.wallpapers);
                let dto = SearchPageDto::from(&result);
                emit(
                    id,
                    serde_json::to_string(&Envelope::ok("search", dto)).unwrap_or_default(),
                );
            }
            Err(e) => emit(id, err_json("search", e)),
        }
    });
    id
}

/// What Wallhaven knows about one tag. Callback `kind: "tag"`.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_tag_info(tag_id: u64) -> u64 {
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("tag", "core not initialised"));
        return id;
    };

    core.runtime.spawn(async move {
        let client = core.provider.read().unwrap().clone();
        match client.get_tag(tag_id).await {
            Ok(tag) => {
                let dto = TagInfoDto::from(&tag);
                emit(
                    id,
                    serde_json::to_string(&Envelope::ok("tag", dto)).unwrap_or_default(),
                );
            }
            Err(e) => emit(id, err_json("tag", e)),
        }
    });
    id
}

// ── downloads ─────────────────────────────────────────────────────────────

/// Enqueues a download. Progress arrives as `kind: "downloads"` pushes.
///
/// `json`: `{ "id": String, "url": String, "filename": String }`
///
/// # Safety
/// Where a download should land.
///
/// The payload may name a directory — that is how the app downloads straight
/// into one of your imported folders rather than into the shared download
/// folder. Anything absent, empty, or not actually a directory falls back to
/// the configured one, so a stale destination cannot strand a download.
fn destination_for(core: &'static Core, value: &serde_json::Value) -> PathBuf {
    let named = value["dir"].as_str().unwrap_or_default().trim();
    if !named.is_empty() {
        let resolved = lumen_core::paths::resolve_dir(named);
        if resolved.is_dir() {
            return resolved;
        }
    }
    core.download_dir.read().unwrap().clone()
}

/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_download(json: *const c_char) -> u64 {
    let raw = unsafe { str_from(json) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("download", "core not initialised"));
        return id;
    };

    let value: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            emit(id, err_json("download", format!("bad payload: {e}")));
            return id;
        }
    };
    let wallpaper_id = value["id"].as_str().unwrap_or_default().to_string();
    let url = value["url"].as_str().unwrap_or_default().to_string();
    let filename = value["filename"].as_str().unwrap_or_default().to_string();
    if url.is_empty() || filename.is_empty() {
        emit(id, err_json("download", "url and filename are required"));
        return id;
    }

    let dir = destination_for(core, &value);
    core.runtime.spawn(async move {
        if let Err(e) = std::fs::create_dir_all(&dir) {
            emit(id, err_json("download", e));
            return;
        }
        match core.downloads.enqueue(wallpaper_id, url, filename, &dir).await {
            Ok(task_id) => emit(
                id,
                serde_json::to_string(&Envelope::ok("download", task_id.to_string()))
                    .unwrap_or_default(),
            ),
            Err(e) => emit(id, err_json("download", e)),
        }
    });
    id
}

/// Drops completed tasks from the list. Callback `kind: "downloads"` follows.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_downloads_clear_finished() -> u64 {
    let id = next_id();
    if let Some(core) = core() {
        core.runtime.spawn(async move {
            core.downloads.clear_finished().await;
            emit(id, serde_json::json!({ "ok": true, "kind": "clearFinished" }).to_string());
        });
    }
    id
}

/// Returns the current download list synchronously as a JSON envelope.
/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_downloads_snapshot() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("downloads", "core not initialised"));
    };
    let tasks: Vec<DownloadDto> = core
        .runtime
        .block_on(core.downloads.get_tasks())
        .iter()
        .map(DownloadDto::from_task)
        .collect();
    to_c(serde_json::to_string(&Envelope::ok("downloads", tasks)).unwrap_or_default())
}

// ── wallpaper ─────────────────────────────────────────────────────────────

/// Downloads `url` into the cache if needed and returns the local path, so the
/// AppKit side can hand a `file://` URL to `NSWorkspace`.
/// Callback `kind: "localFile"`.
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_ensure_local(json: *const c_char) -> u64 {
    let raw = unsafe { str_from(json) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("localFile", "core not initialised"));
        return id;
    };

    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let url = value["url"].as_str().unwrap_or_default().to_string();
    let filename = value["filename"].as_str().unwrap_or_default().to_string();
    if url.is_empty() || filename.is_empty() {
        emit(id, err_json("localFile", "url and filename are required"));
        return id;
    }

    core.runtime.spawn(async move {
        // A completed download is the best copy; use it rather than fetching
        // again. Anything else is staged in the cache directory, which the
        // download manager never writes to.
        let downloaded = core.download_dir.read().unwrap().join(&filename);
        if downloaded.is_file() {
            emit(
                id,
                serde_json::to_string(&Envelope::ok("localFile", file_url(&downloaded)))
                    .unwrap_or_default(),
            );
            return;
        }

        let target = core.cache_dir.join(&filename);
        if target.is_file() {
            emit(
                id,
                serde_json::to_string(&Envelope::ok("localFile", file_url(&target)))
                    .unwrap_or_default(),
            );
            return;
        }

        let fetched = async {
            let response = reqwest::get(&url)
                .await
                .map_err(|e| LumenError::Http(e.to_string()))?;
            let status = response.status();
            if !status.is_success() {
                return Err(LumenError::Api {
                    status: status.as_u16(),
                    message: format!("could not fetch {url}"),
                });
            }
            let bytes = response
                .bytes()
                .await
                .map_err(|e| LumenError::Http(e.to_string()))?;

            // Write to a unique temporary file and rename, so a reader never
            // sees a half-written image and two concurrent sets cannot
            // interleave into one file.
            let staging = core
                .cache_dir
                .join(format!(".{}.{}", uuid::Uuid::new_v4(), "part"));
            std::fs::write(&staging, &bytes)?;
            if let Err(e) = std::fs::rename(&staging, &target) {
                let _ = std::fs::remove_file(&staging);
                return Err(e.into());
            }
            Ok::<_, LumenError>(file_url(&target))
        }
        .await;

        match fetched {
            Ok(path) => emit(
                id,
                serde_json::to_string(&Envelope::ok("localFile", path)).unwrap_or_default(),
            ),
            Err(e) => emit(id, err_json("localFile", e)),
        }
    });
    id
}

// ── bookmarks (favorites) ─────────────────────────────────────────────────

/// Returns every bookmarked wallpaper, newest first, as a JSON envelope of
/// `WallpaperDto`. Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_favorites_list() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("favorites", "core not initialised"));
    };
    match core.db.get_bookmarked_wallpapers(None) {
        Ok(saved) => {
            let list: Vec<WallpaperDto> = saved.iter().map(WallpaperDto::from).collect();
            to_c(serde_json::to_string(&Envelope::ok("favorites", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("favorites", e)),
    }
}

/// Adds or removes a bookmark for `wallpaper_json` and reports the new state as
/// `{ "favorited": Bool }`. Caller frees with [`lumen_string_free`].
///
/// # Safety
/// `wallpaper_json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_favorite_toggle(wallpaper_json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(wallpaper_json) };
    let Some(core) = core() else {
        return to_c(err_json("favorite", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let wallpaper_id = value["id"].as_str().unwrap_or_default().to_string();
    if wallpaper_id.is_empty() {
        return to_c(err_json("favorite", "id is required"));
    }

    let toggled = (|| -> lumen_core::Result<bool> {
        if core.db.is_bookmarked(&wallpaper_id)? {
            let marks = core.db.get_bookmarks(None)?;
            if let Some(mark) = marks.iter().find(|m| m.wallpaper_id == wallpaper_id) {
                core.db.remove_bookmark(mark.id)?;
            }
            return Ok(false);
        }
        // Bookmarks reference the cached wallpaper row, so make sure it exists.
        let cached = core.db.get_cached_wallpaper(&wallpaper_id)?;
        let wallpaper = match cached {
            Some(w) => w,
            None => return Err(LumenError::NotFound(wallpaper_id.clone())),
        };
        core.db.add_bookmark(&Bookmark::new(&wallpaper, None))?;
        Ok(true)
    })();

    match toggled {
        Ok(on) => to_c(
            serde_json::json!({ "ok": true, "kind": "favorite", "data": { "favorited": on } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("favorite", e)),
    }
}

// ── collections ───────────────────────────────────────────────────────────

/// Every collection with its wallpapers, newest first. Collections are
/// user-curated and small, so the whole set comes back in one read.
/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_collections_list() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("collections", "core not initialised"));
    };
    let listed = core.db.get_folders().and_then(|folders| {
        let mut out = Vec::with_capacity(folders.len());
        for folder in &folders {
            let wallpapers = core
                .db
                .get_collection_wallpapers(folder.id)?
                .iter()
                .map(WallpaperDto::from)
                .collect();
            out.push(CollectionDto {
                id: folder.id.to_string(),
                name: folder.name.clone(),
                wallpapers,
            });
        }
        Ok(out)
    });
    match listed {
        Ok(list) => {
            to_c(serde_json::to_string(&Envelope::ok("collections", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("collections", e)),
    }
}

/// Creates a collection and returns it. Caller frees with [`lumen_string_free`].
///
/// # Safety
/// `name` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_collection_create(name: *const c_char) -> *mut c_char {
    let name = unsafe { str_from(name) };
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return to_c(err_json("collection", "name is required"));
    }
    let Some(core) = core() else {
        return to_c(err_json("collection", "core not initialised"));
    };

    let folder = BookmarkFolder::new(trimmed);
    match core.db.add_folder(&folder) {
        Ok(()) => {
            let dto = CollectionDto {
                id: folder.id.to_string(),
                name: folder.name.clone(),
                wallpapers: Vec::new(),
            };
            to_c(serde_json::to_string(&Envelope::ok("collection", dto)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("collection", e)),
    }
}

/// Deletes a collection. Its membership rows go with it; the wallpapers do not.
///
/// # Safety
/// `id` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_collection_delete(id: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(id) };
    let Some(core) = core() else {
        return to_c(err_json("collection", "core not initialised"));
    };
    let Ok(uuid) = uuid::Uuid::parse_str(raw.trim()) else {
        return to_c(err_json("collection", "not a collection id"));
    };
    match core.db.delete_bookmark_folder(uuid) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "collection" }).to_string()),
        Err(e) => to_c(err_json("collection", e)),
    }
}

/// Adds or removes a wallpaper from a collection.
///
/// `json`: `{ "collectionId": String, "wallpaperId": String, "member": Bool }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_collection_set_member(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("collection", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let wallpaper_id = value["wallpaperId"].as_str().unwrap_or_default().to_string();
    let member = value["member"].as_bool().unwrap_or(true);
    let Ok(collection_id) = uuid::Uuid::parse_str(value["collectionId"].as_str().unwrap_or_default())
    else {
        return to_c(err_json("collection", "not a collection id"));
    };
    if wallpaper_id.is_empty() {
        return to_c(err_json("collection", "wallpaperId is required"));
    }

    // Membership joins against the wallpaper cache, so an uncached wallpaper
    // would file a row that never renders.
    let result = if member {
        match core.db.get_cached_wallpaper(&wallpaper_id) {
            Ok(Some(_)) => core.db.add_to_collection(collection_id, &wallpaper_id),
            Ok(None) => Err(LumenError::NotFound(wallpaper_id.clone())),
            Err(e) => Err(e),
        }
    } else {
        core.db.remove_from_collection(collection_id, &wallpaper_id)
    };

    match result {
        Ok(()) => to_c(
            serde_json::json!({ "ok": true, "kind": "collection", "data": { "member": member } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("collection", e)),
    }
}

/// Cached records for a list of wallpaper ids, skipping any not held.
///
/// `json`: `{ "ids": [String] }`. Caller frees with [`lumen_string_free`].
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_wallpapers_cached(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("cached", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let ids = ids_from(&value);

    let mut found = Vec::new();
    for id in ids {
        if let Ok(Some(wallpaper)) = core.db.get_cached_wallpaper(&id) {
            found.push(WallpaperDto::from(&wallpaper));
        }
    }
    to_c(serde_json::to_string(&Envelope::ok("cached", found)).unwrap_or_default())
}

/// Caches wallpaper records, so a restored backup has rows for favourites and
/// collection members to point at.
///
/// `json`: `{ "wallpapers": [WallpaperDto] }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_wallpapers_cache(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("cache", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let Some(entries) = value["wallpapers"].as_array() else {
        return to_c(err_json("cache", "wallpapers are required"));
    };

    let mut stored = 0;
    for entry in entries {
        // The DTO is the Swift shape; rebuild the core record from it.
        let Some(id) = entry["id"].as_str() else { continue };
        let resolution = entry["resolution"].as_str().unwrap_or("0x0");
        let (width, height) = resolution
            .split_once('x')
            .map(|(w, h)| (w.parse().unwrap_or(0), h.parse().unwrap_or(0)))
            .unwrap_or((0, 0));

        let wallpaper = Wallpaper {
            id: id.to_string(),
            provider: WallpaperProvider::Wallhaven,
            url: entry["url"].as_str().unwrap_or_default().to_string(),
            short_url: None,
            full_url: entry["path"].as_str().unwrap_or_default().to_string(),
            thumbnail_small: entry["thumb"].as_str().unwrap_or_default().to_string(),
            thumbnail_large: entry["thumb"].as_str().unwrap_or_default().to_string(),
            thumbnail_original: entry["thumb"].as_str().unwrap_or_default().to_string(),
            uploader: entry["uploader"].as_str().map(str::to_string),
            resolution: Resolution::new(width, height),
            file_size: entry["fileSize"].as_u64().unwrap_or(0),
            file_type: entry["fileType"].as_str().unwrap_or("image/jpeg").to_string(),
            category: match entry["category"].as_str().unwrap_or("general") {
                "anime" => Category::Anime,
                "people" => Category::People,
                _ => Category::General,
            },
            purity: match entry["purity"].as_str().unwrap_or("sfw") {
                "sketchy" => Purity::Sketchy,
                "nsfw" => Purity::Nsfw,
                _ => Purity::Sfw,
            },
            colors: entry["colors"]
                .as_array()
                .map(|c| c.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default(),
            tags: Vec::new(),
            source: None,
            views: entry["views"].as_u64().unwrap_or(0),
            favorites: entry["favorites"].as_u64().unwrap_or(0),
            ratio: entry["ratio"].as_f64().unwrap_or(1.777),
            created_at: None,
        };
        if core.db.cache_wallpaper(&wallpaper).is_ok() {
            stored += 1;
        }
    }
    to_c(
        serde_json::json!({ "ok": true, "kind": "cache", "data": { "stored": stored } })
            .to_string(),
    )
}

// ── crop rectangles ───────────────────────────────────────────────────────

/// Saves a crop for one file on one display.
///
/// `json`: `{ "path": String, "display": String, "x": Double, "y": Double,
///            "width": Double, "height": Double }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_crop_save(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("crop", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let path = value["path"].as_str().unwrap_or_default();
    let display = value["display"].as_str().unwrap_or_default();
    if path.is_empty() || display.is_empty() {
        return to_c(err_json("crop", "path and display are required"));
    }
    let rect = (
        value["x"].as_f64().unwrap_or(0.0),
        value["y"].as_f64().unwrap_or(0.0),
        value["width"].as_f64().unwrap_or(1.0),
        value["height"].as_f64().unwrap_or(1.0),
    );

    match core.db.save_crop(path, display, rect) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "crop" }).to_string()),
        Err(e) => to_c(err_json("crop", e)),
    }
}

/// The saved crop for a file on a display, or null.
///
/// `json`: `{ "path": String, "display": String }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_crop_get(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("crop", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let path = value["path"].as_str().unwrap_or_default();
    let display = value["display"].as_str().unwrap_or_default();

    match core.db.crop(path, display) {
        Ok(Some((x, y, width, height))) => to_c(
            serde_json::json!({
                "ok": true, "kind": "crop",
                "data": { "x": x, "y": y, "width": width, "height": height }
            })
            .to_string(),
        ),
        Ok(None) => to_c(serde_json::json!({ "ok": true, "kind": "crop" }).to_string()),
        Err(e) => to_c(err_json("crop", e)),
    }
}

/// Forgets a saved crop.
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_crop_clear(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("crop", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    match core.db.clear_crop(
        value["path"].as_str().unwrap_or_default(),
        value["display"].as_str().unwrap_or_default(),
    ) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "crop" }).to_string()),
        Err(e) => to_c(err_json("crop", e)),
    }
}

// ── image feature prints ──────────────────────────────────────────────────

/// Stores feature prints computed by Vision on the Swift side.
///
/// `json`: `{ "prints": [{ "path": String, "print": base64, "fileSize": Int }] }`
/// Returns `{ "stored": Int }`. Caller frees with [`lumen_string_free`].
///
/// # Safety
/// Stores semantic embeddings, which say what an image is *of* rather than what
/// it looks like. Keyed by the model that produced them, so changing model
/// invalidates the old set rather than mixing two incompatible spaces.
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_embeddings_store(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("embeddings", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let model = value["model"].as_str().unwrap_or_default().to_string();
    let Some(entries) = value["embeddings"].as_array() else {
        return to_c(err_json("embeddings", "embeddings are required"));
    };
    if model.is_empty() {
        return to_c(err_json("embeddings", "model is required"));
    }

    let mut stored = 0;
    for entry in entries {
        let path = entry["path"].as_str().unwrap_or_default();
        let encoded = entry["embedding"].as_str().unwrap_or_default();
        let size = entry["fileSize"].as_u64().unwrap_or(0);
        if path.is_empty() || encoded.is_empty() {
            continue;
        }
        let Some(bytes) = decode_base64(encoded) else { continue };
        if core.db.store_embedding(path, &model, &bytes, size).is_ok() {
            stored += 1;
        }
    }
    to_c(
        serde_json::json!({ "ok": true, "kind": "embeddings", "data": { "stored": stored } })
            .to_string(),
    )
}

/// Every embedding for a model, base64 encoded.
///
/// # Safety
/// `model` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_embeddings_all(model: *const c_char) -> *mut c_char {
    let model = unsafe { str_from(model) };
    let Some(core) = core() else {
        return to_c(err_json("embeddings", "core not initialised"));
    };
    match core.db.all_embeddings(&model) {
        Ok(rows) => {
            let listed: Vec<_> = rows
                .into_iter()
                .map(|(path, bytes)| {
                    serde_json::json!({ "path": path, "embedding": encode_base64(&bytes) })
                })
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("embeddings", listed)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("embeddings", e)),
    }
}

/// Which files a model has already covered, so a pass only does what is left.
///
/// # Safety
/// `model` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_embeddings_known(model: *const c_char) -> *mut c_char {
    let model = unsafe { str_from(model) };
    let Some(core) = core() else {
        return to_c(err_json("embeddings", "core not initialised"));
    };
    match core.db.embedded_paths(&model) {
        Ok(paths) => {
            let listed: Vec<_> = paths.into_iter().collect();
            to_c(serde_json::to_string(&Envelope::ok("embeddings", listed)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("embeddings", e)),
    }
}

/// Drops embeddings whose file has gone.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_embeddings_prune() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("embeddings", "core not initialised"));
    };
    match core.db.prune_embeddings() {
        Ok(removed) => to_c(
            serde_json::json!({ "ok": true, "kind": "embeddings", "data": { "removed": removed } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("embeddings", e)),
    }
}

/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_prints_store(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("prints", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let Some(entries) = value["prints"].as_array() else {
        return to_c(err_json("prints", "prints are required"));
    };

    let mut stored = 0;
    for entry in entries {
        let path = entry["path"].as_str().unwrap_or_default();
        let encoded = entry["print"].as_str().unwrap_or_default();
        let size = entry["fileSize"].as_u64().unwrap_or(0);
        if path.is_empty() || encoded.is_empty() {
            continue;
        }
        let Some(bytes) = decode_base64(encoded) else { continue };
        if core.db.store_print(path, &bytes, size).is_ok() {
            stored += 1;
        }
    }
    to_c(
        serde_json::json!({ "ok": true, "kind": "prints", "data": { "stored": stored } })
            .to_string(),
    )
}

/// Every stored print, as `{ path, print }` with the print base64 encoded.
/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_prints_all() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("prints", "core not initialised"));
    };
    match core.db.all_prints() {
        Ok(prints) => {
            let list: Vec<serde_json::Value> = prints
                .into_iter()
                .map(|(path, bytes)| {
                    serde_json::json!({ "path": path, "print": encode_base64(&bytes) })
                })
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("prints", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("prints", e)),
    }
}

/// Paths that already have a print, so only new files are computed.
/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_prints_known() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("prints", "core not initialised"));
    };
    match core.db.printed_paths() {
        Ok(paths) => {
            let list: Vec<String> = paths.into_iter().collect();
            to_c(serde_json::to_string(&Envelope::ok("prints", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("prints", e)),
    }
}

/// Drops prints for files no longer on disk.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_prints_prune() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("prints", "core not initialised"));
    };
    match core.db.prune_prints() {
        Ok(removed) => to_c(
            serde_json::json!({ "ok": true, "kind": "prints", "data": { "removed": removed } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("prints", e)),
    }
}

/// Minimal base64, so a Vision print can travel as JSON without pulling in a
/// dependency for four lines of work.
fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
    }
    out
}

fn decode_base64(text: &str) -> Option<Vec<u8>> {
    fn value(byte: u8) -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some(u32::from(byte - b'A')),
            b'a'..=b'z' => Some(u32::from(byte - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(byte - b'0') + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let cleaned: Vec<u8> = text.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    let padding = cleaned.iter().rev().take_while(|b| **b == b'=').count();
    let body = &cleaned[..cleaned.len().saturating_sub(padding)];

    let mut out = Vec::with_capacity(body.len() * 3 / 4);
    for chunk in body.chunks(4) {
        let mut packed = 0u32;
        for (index, byte) in chunk.iter().enumerate() {
            packed |= value(*byte)? << (18 - 6 * index);
        }
        out.push((packed >> 16) as u8);
        if chunk.len() > 2 {
            out.push((packed >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(packed as u8);
        }
    }
    Some(out)
}

// ── tag radar ─────────────────────────────────────────────────────────────

/// Subscribes to a query, so new matches are noticed in the background.
///
/// `json`: `{ "query": String, "label": String, "minFavorites": Int }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_radar_subscribe(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("radar", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let query = value["query"].as_str().unwrap_or_default().trim().to_string();
    if query.is_empty() {
        return to_c(err_json("radar", "query is required"));
    }
    let label = value["label"].as_str().unwrap_or(&query).to_string();
    let threshold = value["minFavorites"].as_u64().unwrap_or(0) as u32;

    match core.db.add_subscription(&query, &label, threshold) {
        Ok(id) => to_c(
            serde_json::json!({ "ok": true, "kind": "radar", "data": { "id": id.to_string() } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("radar", e)),
    }
}

/// Every subscription. Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_radar_list() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("radar", "core not initialised"));
    };
    match core.db.subscriptions() {
        Ok(found) => {
            let list: Vec<SubscriptionDto> = found
                .into_iter()
                .map(|(id, query, label, threshold, _, unseen)| SubscriptionDto {
                    id: id.to_string(),
                    query,
                    label,
                    min_favorites: threshold,
                    unseen,
                })
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("radar", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("radar", e)),
    }
}

/// # Safety
/// `id` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_radar_remove(id: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(id) };
    let Some(core) = core() else {
        return to_c(err_json("radar", "core not initialised"));
    };
    let Ok(uuid) = uuid::Uuid::parse_str(raw.trim()) else {
        return to_c(err_json("radar", "not a subscription id"));
    };
    match core.db.remove_subscription(uuid) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "radar" }).to_string()),
        Err(e) => to_c(err_json("radar", e)),
    }
}

/// Marks a subscription as looked at.
///
/// # Safety
/// `id` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_radar_mark_seen(id: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(id) };
    let Some(core) = core() else {
        return to_c(err_json("radar", "core not initialised"));
    };
    let Ok(uuid) = uuid::Uuid::parse_str(raw.trim()) else {
        return to_c(err_json("radar", "not a subscription id"));
    };
    match core.db.clear_subscription_unseen(uuid) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "radar" }).to_string()),
        Err(e) => to_c(err_json("radar", e)),
    }
}

/// Re-runs every subscription and reports what is new.
///
/// Callback `kind: "radarResults"` with
/// `[{ id, label, newMatches, wallpapers: [WallpaperDto] }]`.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_radar_check() -> u64 {
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("radarResults", "core not initialised"));
        return id;
    };

    core.runtime.spawn(async move {
        let subscriptions = match core.db.subscriptions() {
            Ok(found) => found,
            Err(e) => {
                emit(id, err_json("radarResults", e));
                return;
            }
        };

        let mut report = Vec::new();
        for (subscription_id, query, label, threshold, last_seen, _) in subscriptions {
            let filters = SearchFilters {
                query: Some(query.clone()),
                categories: vec![Category::General, Category::Anime, Category::People],
                purity: vec![Purity::Sfw],
                // Newest first is what makes "since last time" meaningful.
                sorting: Sorting::DateAdded,
                order: SortOrder::Desc,
                page: 1,
                ..Default::default()
            };

            let client = core.provider.read().unwrap().clone();
            let Ok(page) = client.search(&filters).await else { continue };

            // Everything above the last wallpaper this subscription reported.
            let fresh: Vec<_> = page
                .wallpapers
                .iter()
                .take_while(|w| Some(&w.id) != last_seen.as_ref())
                .filter(|w| w.favorites >= threshold as u64)
                .collect();

            let newest = page.wallpapers.first().map(|w| w.id.clone());
            let _ = core.db.cache_wallpapers(&page.wallpapers);
            let _ = core.db.record_subscription_check(
                subscription_id,
                newest.as_deref(),
                fresh.len() as u32,
            );

            if !fresh.is_empty() {
                report.push(serde_json::json!({
                    "id": subscription_id.to_string(),
                    "label": label,
                    "newMatches": fresh.len(),
                    "wallpapers": fresh.iter().map(|w| WallpaperDto::from(*w)).collect::<Vec<_>>(),
                }));
            }
        }

        emit(
            id,
            serde_json::json!({ "ok": true, "kind": "radarResults", "data": report }).to_string(),
        );
    });
    id
}

// ── wallpaper history ─────────────────────────────────────────────────────

/// Records what was just set, so it can be listed and undone.
///
/// `json`: `{ "wallpaperId": String?, "path": String, "label": String }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_history_record(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("history", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let path = value["path"].as_str().unwrap_or_default();
    if path.is_empty() {
        return to_c(err_json("history", "path is required"));
    }
    let label = value["label"].as_str().unwrap_or(path);
    let wallpaper_id = value["wallpaperId"].as_str();

    match core.db.record_wallpaper(wallpaper_id, path, label) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "history" }).to_string()),
        Err(e) => to_c(err_json("history", e)),
    }
}

/// What has been on the desktop, most recent first.
/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_history(limit: u32) -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("history", "core not initialised"));
    };
    match core.db.wallpaper_history(limit.clamp(1, 200)) {
        Ok(entries) => {
            let list: Vec<HistoryEntryDto> = entries
                .into_iter()
                .map(|(wallpaper_id, path, label, set_at)| HistoryEntryDto {
                    wallpaper_id,
                    url: file_url(std::path::Path::new(&path)),
                    label,
                    set_at,
                })
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("history", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("history", e)),
    }
}

/// Drops the newest entry, so undo does not step back onto what is showing.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_history_drop_latest() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("history", "core not initialised"));
    };
    match core.db.drop_latest_history() {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "history" }).to_string()),
        Err(e) => to_c(err_json("history", e)),
    }
}

// ── imported folders ──────────────────────────────────────────────────────

/// The scan, in the shape the database's sync call takes.
fn scan(root: &std::path::Path) -> Vec<(String, String, u64, String)> {
    lumen_core::scan::as_rows(&lumen_core::scan::scan_images(root))
}

/// Registers the download directory as an imported folder and indexes it.
///
/// The Downloads pane lists transfers, which live only as long as the process.
/// Without this, a wallpaper downloaded yesterday is on disk but nowhere in the
/// app — so the folder Lumen downloads into is always part of the library.
fn ensure_downloads_indexed(core: &'static Core) {
    let dir = core.download_dir.read().unwrap().clone();
    if !dir.is_dir() {
        return;
    }
    let Ok(folder_id) = core
        .db
        .import_folder(&dir.to_string_lossy(), "Lumen downloads")
    else {
        return;
    };
    let files = scan(&dir);
    let _ = core.db.sync_imported_wallpapers(folder_id, &files);
}

/// Imports a folder and indexes the images in it. Importing the same folder
/// again rescans rather than duplicating. Callback `kind: "library"`.
///
/// # Safety
/// `path` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_library_import(path: *const c_char) -> u64 {
    let raw = unsafe { str_from(path) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("library", "core not initialised"));
        return id;
    };
    let root = PathBuf::from(raw.trim());
    if !root.is_dir() {
        emit(id, err_json("library", "that is not a folder"));
        return id;
    }

    core.runtime.spawn(async move {
        let name = root
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| root.to_string_lossy().into_owned());

        let imported = core
            .db
            .import_folder(&root.to_string_lossy(), &name)
            .and_then(|folder_id| {
                // Scanning can take a moment on a large folder, which is why
                // this is async rather than a synchronous call.
                let files = scan(&root);
                core.db.sync_imported_wallpapers(folder_id, &files)?;
                Ok((folder_id, files.len()))
            });

        match imported {
            Ok((folder_id, count)) => {
                let dto = ImportedFolderDto {
                    id: folder_id.to_string(),
                    name,
                    path: root.to_string_lossy().into_owned(),
                    count: count as u32,
                };
                emit(
                    id,
                    serde_json::to_string(&Envelope::ok("library", dto)).unwrap_or_default(),
                );
            }
            Err(e) => emit(id, err_json("library", e)),
        }
    });
    id
}

/// Re-indexes just the download directory. Cheap enough to run whenever a
/// download finishes, unlike a full rescan of every imported folder.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_library_refresh_downloads() -> u64 {
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("library", "core not initialised"));
        return id;
    };
    core.runtime.spawn(async move {
        ensure_downloads_indexed(core);
        emit(id, serde_json::json!({ "ok": true, "kind": "library" }).to_string());
    });
    id
}

/// Rescans every imported folder, picking up additions and dropping files that
/// are gone. Callback `kind: "library"`.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_library_rescan() -> u64 {
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("library", "core not initialised"));
        return id;
    };

    core.runtime.spawn(async move {
        let result = core.db.imported_folders().and_then(|folders| {
            let mut total = 0;
            for (folder_id, _, path, _) in &folders {
                let files = scan(std::path::Path::new(path));
                total += core.db.sync_imported_wallpapers(*folder_id, &files)?;
            }
            Ok(total)
        });
        match result {
            Ok(total) => emit(
                id,
                serde_json::json!({ "ok": true, "kind": "library", "data": { "count": total } })
                    .to_string(),
            ),
            Err(e) => emit(id, err_json("library", e)),
        }
    });
    id
}

/// Every imported folder. Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_library_folders() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("library", "core not initialised"));
    };
    match core.db.imported_folders() {
        Ok(folders) => {
            let list: Vec<ImportedFolderDto> = folders
                .into_iter()
                .map(|(id, name, path, count)| ImportedFolderDto {
                    id: id.to_string(),
                    name,
                    path,
                    count,
                })
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("library", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("library", e)),
    }
}

/// Wallpapers in one imported folder, or all of them when `folder_id` is empty.
/// Caller frees with [`lumen_string_free`].
///
/// # Safety
/// `folder_id` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_library_wallpapers(
    folder_id: *const c_char,
    favorites_only: bool,
) -> *mut c_char {
    let raw = unsafe { str_from(folder_id) };
    let Some(core) = core() else {
        return to_c(err_json("library", "core not initialised"));
    };
    let scoped = uuid::Uuid::parse_str(raw.trim()).ok();

    match core.db.imported_wallpapers(scoped, favorites_only) {
        Ok(found) => {
            let list: Vec<LocalWallpaperDto> = found
                .into_iter()
                .map(|(id, folder, path, filename, size, favorite, subpath)| LocalWallpaperDto {
                    id: id.to_string(),
                    folder_id: folder.to_string(),
                    url: file_url(std::path::Path::new(&path)),
                    path,
                    filename,
                    file_size: size as i64,
                    is_favorite: favorite,
                    subpath,
                })
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("library", list)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("library", e)),
    }
}

/// Forgets a folder. The files on disk are untouched.
///
/// # Safety
/// `folder_id` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_library_forget(folder_id: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(folder_id) };
    let Some(core) = core() else {
        return to_c(err_json("library", "core not initialised"));
    };
    let Ok(id) = uuid::Uuid::parse_str(raw.trim()) else {
        return to_c(err_json("library", "not a folder id"));
    };
    match core.db.remove_imported_folder(id) {
        Ok(()) => to_c(serde_json::json!({ "ok": true, "kind": "library" }).to_string()),
        Err(e) => to_c(err_json("library", e)),
    }
}

/// Favourites or un-favourites one imported wallpaper.
///
/// `json`: `{ "id": String, "favorite": Bool }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_library_favorite(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("library", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let favorite = value["favorite"].as_bool().unwrap_or(true);
    let Ok(id) = uuid::Uuid::parse_str(value["id"].as_str().unwrap_or_default()) else {
        return to_c(err_json("library", "not a wallpaper id"));
    };
    match core.db.set_imported_favorite(id, favorite) {
        Ok(()) => to_c(
            serde_json::json!({ "ok": true, "kind": "library", "data": { "favorite": favorite } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("library", e)),
    }
}

// ── library awareness ─────────────────────────────────────────────────────

/// Ids of wallpapers already sitting in the download directory.
///
/// Files are named `wallhaven-<id>.<ext>`, so the directory itself is the
/// source of truth — it stays right when the user moves or deletes files
/// behind the app's back, which a database table would not.
/// The Wallhaven ids already present in the imported library, read from the
/// filenames.
///
/// Answers "do I already have this?" while browsing, for wallpapers collected
/// before Lumen existed. Derived here rather than in the app because the index
/// is already in the database: sending the ids is a few tens of kilobytes where
/// sending the rows they came from would be hundreds.
#[unsafe(no_mangle)]
pub extern "C" fn lumen_library_wallhaven_ids() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("libraryIds", "core not initialised"));
    };
    match core.db.imported_filenames() {
        Ok(names) => {
            let ids: Vec<String> = names
                .iter()
                .filter_map(|name| lumen_core::wallhaven::id_from_filename(name))
                .collect();
            to_c(serde_json::to_string(&Envelope::ok("libraryIds", ids)).unwrap_or_default())
        }
        Err(e) => to_c(err_json("libraryIds", e)),
    }
}

/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_downloaded_ids() -> *mut c_char {
    let Some(core) = core() else {
        return to_c(err_json("downloaded", "core not initialised"));
    };
    let dir = core.download_dir.read().unwrap().clone();

    let mut ids: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            // A ".part" is a download in flight, not one you have.
            if name.ends_with(".part") {
                continue;
            }
            let Some(rest) = name.strip_prefix("wallhaven-") else {
                continue;
            };
            let id = rest.split('.').next().unwrap_or_default();
            if !id.is_empty() {
                ids.push(id.to_string());
            }
        }
    }
    ids.sort();
    ids.dedup();
    to_c(serde_json::to_string(&Envelope::ok("downloaded", ids)).unwrap_or_default())
}

// ── bulk actions ──────────────────────────────────────────────────────────

/// Reads a JSON array of wallpaper ids from `value["ids"]`.
fn ids_from(value: &serde_json::Value) -> Vec<String> {
    value["ids"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Bookmarks or un-bookmarks several wallpapers at once.
///
/// `json`: `{ "ids": [String], "favorited": Bool }`
/// Returns `{ "changed": Int }`. Caller frees with [`lumen_string_free`].
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_favorites_set_many(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("favorites", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let ids = ids_from(&value);
    let favorited = value["favorited"].as_bool().unwrap_or(true);
    if ids.is_empty() {
        return to_c(err_json("favorites", "ids are required"));
    }

    let result = if favorited {
        core.db.add_bookmarks_for(&ids)
    } else {
        core.db.remove_bookmarks_for(&ids)
    };
    match result {
        Ok(changed) => to_c(
            serde_json::json!({ "ok": true, "kind": "favorites", "data": { "changed": changed } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("favorites", e)),
    }
}

/// Files several wallpapers into one collection.
///
/// `json`: `{ "collectionId": String, "ids": [String] }`
/// Returns `{ "changed": Int }`. Caller frees with [`lumen_string_free`].
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_collection_add_many(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("collection", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let ids = ids_from(&value);
    let Ok(collection_id) = uuid::Uuid::parse_str(value["collectionId"].as_str().unwrap_or_default())
    else {
        return to_c(err_json("collection", "not a collection id"));
    };
    if ids.is_empty() {
        return to_c(err_json("collection", "ids are required"));
    }

    match core.db.add_many_to_collection(collection_id, &ids) {
        Ok(changed) => to_c(
            serde_json::json!({ "ok": true, "kind": "collection", "data": { "changed": changed } })
                .to_string(),
        ),
        Err(e) => to_c(err_json("collection", e)),
    }
}

/// Enqueues several downloads at once. Progress arrives as `kind: "downloads"`.
///
/// `json`: `{ "items": [{ "id": String, "url": String, "filename": String }] }`
///
/// # Safety
/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_download_many(json: *const c_char) -> u64 {
    let raw = unsafe { str_from(json) };
    let id = next_id();
    let Some(core) = core() else {
        emit(id, err_json("download", "core not initialised"));
        return id;
    };

    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let items: Vec<(String, String, String)> = value["items"]
        .as_array()
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    let wallpaper_id = entry["id"].as_str()?.to_string();
                    let url = entry["url"].as_str()?.to_string();
                    let filename = entry["filename"].as_str()?.to_string();
                    (!url.is_empty() && !filename.is_empty())
                        .then_some((wallpaper_id, url, filename))
                })
                .collect()
        })
        .unwrap_or_default();

    if items.is_empty() {
        emit(id, err_json("download", "items are required"));
        return id;
    }

    let dir = destination_for(core, &value);
    core.runtime.spawn(async move {
        if let Err(e) = std::fs::create_dir_all(&dir) {
            emit(id, err_json("download", e));
            return;
        }
        // The manager's semaphore bounds how many actually run at once, so
        // enqueuing the whole selection is safe.
        let mut queued = 0;
        for (wallpaper_id, url, filename) in items {
            if core
                .downloads
                .enqueue(wallpaper_id, url, filename, &dir)
                .await
                .is_ok()
            {
                queued += 1;
            }
        }
        emit(
            id,
            serde_json::json!({ "ok": true, "kind": "download", "data": { "queued": queued } })
                .to_string(),
        );
    });
    id
}

// ── preferences ───────────────────────────────────────────────────────────

/// Applies live preference changes (API key, download directory).
///
/// # Safety
/// Mirrors the settings the app holds into the database.
///
/// The app keeps these in `UserDefaults`, which nothing outside the bundle can
/// read — so without this the CLI would have no download folder and no
/// concurrency even though the user had configured both. The API key is not
/// among them: it goes to the keychain instead.
fn persist_preferences(core: &'static Core) {
    let Ok(mut prefs) = core.db.get_preferences() else { return };
    // Deliberately not the API key: that lives in the keychain, which both
    // front ends read. A key left in this row by an earlier version is
    // plaintext on disk, so it is cleared rather than carried forward.
    prefs.api_key = None;
    prefs.download_dir = core.download_dir.read().unwrap().to_string_lossy().into_owned();
    prefs.max_parallel_downloads = core.downloads.max_concurrent() as u32;
    let _ = core.db.save_preferences(&prefs);
}

/// `json` must be NUL-terminated UTF-8, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_set_preferences(json: *const c_char) -> *mut c_char {
    let raw = unsafe { str_from(json) };
    let Some(core) = core() else {
        return to_c(err_json("preferences", "core not initialised"));
    };
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);

    if let Some(key) = value.get("apiKey").and_then(|v| v.as_str()) {
        core.provider
            .write()
            .unwrap()
            .set_api_key((!key.is_empty()).then(|| key.to_string()));
    }
    if let Some(dir) = value.get("downloadDir").and_then(|v| v.as_str()) {
        let resolved = lumen_core::paths::resolve_dir(dir);
        let _ = std::fs::create_dir_all(&resolved);
        let changed = *core.download_dir.read().unwrap() != resolved;
        *core.download_dir.write().unwrap() = resolved;
        // A new download directory becomes the browsable one.
        if changed {
            ensure_downloads_indexed(core);
        }
    }
    if let Some(limit) = value.get("maxParallel").and_then(|v| v.as_u64()) {
        core.downloads.set_max_concurrent(limit.clamp(1, 12) as usize);
    }
    persist_preferences(core);
    to_c(serde_json::json!({ "ok": true, "kind": "preferences" }).to_string())
}

/// The directory downloads land in. Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_download_dir() -> *mut c_char {
    match core() {
        Some(c) => to_c(c.download_dir.read().unwrap().to_string_lossy().into_owned()),
        None => to_c(String::new()),
    }
}

/// `"ready"` once [`lumen_init`] has succeeded, otherwise the failure reason.
/// Caller frees with [`lumen_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn lumen_status() -> *mut c_char {
    if core().is_some() {
        return to_c("ready".into());
    }
    let reason = INIT_ERROR
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| "not initialised".into());
    to_c(reason)
}

#[cfg(test)]
mod tests {
    use super::{decode_base64, encode_base64, lumen_string_free, str_from, to_c};
    use std::ffi::CString;

    /// The C string boundary, which is where a leak or a double free would
    /// live. Run under Miri (`cargo +nightly miri test -p lumen-ffi`), which
    /// checks the pointer arithmetic and the allocation pairing that ordinary
    /// tests cannot see.
    #[test]
    fn strings_handed_out_are_freed_exactly_once() {
        for payload in ["", "plain", "{\"ok\":true}", "unicode — ✓ 日本語"] {
            let pointer = to_c(payload.to_string());
            assert!(!pointer.is_null());
            // Reading it back must not disturb the allocation.
            let seen = unsafe { str_from(pointer) };
            assert_eq!(seen, payload);
            unsafe { lumen_string_free(pointer) };
        }
    }

    #[test]
    fn freeing_null_is_a_no_op() {
        // Swift passes whatever the C call returned, including null on failure.
        unsafe { lumen_string_free(std::ptr::null_mut()) };
    }

    #[test]
    fn reading_a_null_pointer_yields_an_empty_string() {
        assert_eq!(unsafe { str_from(std::ptr::null()) }, "");
    }

    #[test]
    fn a_payload_containing_a_nul_does_not_truncate_silently() {
        // CString::new rejects an interior NUL; to_c must not hand back a
        // pointer into freed memory when it does.
        let pointer = to_c("before\0after".to_string());
        let seen = unsafe { str_from(pointer) };
        assert!(seen.contains("nul in payload"), "got {seen}");
        unsafe { lumen_string_free(pointer) };
    }

    #[test]
    fn borrowed_input_is_copied_rather_than_kept() {
        // The Rust side must not retain a pointer Swift owns.
        let owned = CString::new("caller owns this").unwrap();
        let copied = unsafe { str_from(owned.as_ptr()) };
        drop(owned);
        assert_eq!(copied, "caller owns this");
    }

    #[test]
    fn base64_round_trips_every_length_and_byte_value() {
        // Feature prints are opaque binary; a padding bug would corrupt them
        // silently and only show up as bad similarity matches.
        for length in 0..64usize {
            let original: Vec<u8> = (0..length).map(|i| (i * 7 % 256) as u8).collect();
            let encoded = encode_base64(&original);
            assert_eq!(encoded.len() % 4, 0, "length {length} is not padded");
            assert_eq!(decode_base64(&encoded).expect("decode"), original, "length {length}");
        }

        // Every byte value, not just the ones a small loop happens to hit.
        let all: Vec<u8> = (0..=255u8).collect();
        assert_eq!(decode_base64(&encode_base64(&all)).expect("decode"), all);
    }

    #[test]
    fn decoding_rejects_rubbish_rather_than_returning_wrong_bytes() {
        assert!(decode_base64("not base64!").is_none());
        assert_eq!(decode_base64("").expect("empty"), Vec::<u8>::new());
        // Whitespace is tolerated, since JSON transports can introduce it.
        assert_eq!(decode_base64("QQ ==").expect("spaced"), b"A".to_vec());
    }
}


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

mod dto;

use dto::*;
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};
use tokio::runtime::Runtime;
use wallsetter_core::*;
use wallsetter_db::Database;
use wallsetter_downloader::DownloadManager;
use wallsetter_provider::wallhaven::WallhavenClient;

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
}

static CORE: OnceLock<Core> = OnceLock::new();
static INIT_ERROR: Mutex<Option<String>> = Mutex::new(None);

fn core() -> Option<&'static Core> {
    CORE.get()
}

/// Expands a leading `~` and falls back to `~/Pictures/Lumen`.
fn resolve_dir(raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return directories::UserDirs::new()
            .and_then(|d| d.picture_dir().map(|p| p.join("Lumen")))
            .unwrap_or_else(|| PathBuf::from("."));
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        if let Some(home) = directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf()) {
            return home.join(rest);
        }
    }
    PathBuf::from(trimmed)
}

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
    let dir = resolve_dir(cfg.get("downloadDir").and_then(|v| v.as_str()).unwrap_or(""));
    let max_parallel = cfg
        .get("maxParallel")
        .and_then(|v| v.as_u64())
        .unwrap_or(4)
        .clamp(1, 12) as usize;

    if let Some(core) = core() {
        // Already running — treat as a reconfigure.
        core.provider.write().unwrap().set_api_key(api_key);
        *core.download_dir.write().unwrap() = dir;
        return to_c(serde_json::json!({ "ok": true, "kind": "init", "data": "reconfigured" }).to_string());
    }

    let built = (|| -> wallsetter_core::Result<Core> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(4)
            .build()
            .map_err(|e| WallsetterError::Other(format!("runtime: {e}")))?;

        let data_dir = directories::ProjectDirs::from("cc", "lumen", "Lumen")
            .map(|d| d.data_dir().to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."));
        std::fs::create_dir_all(&data_dir)?;
        std::fs::create_dir_all(&dir)?;

        let db = Database::new(&data_dir.join("lumen.db"))?;

        Ok(Core {
            provider: RwLock::new(WallhavenClient::new(api_key)),
            db,
            downloads: DownloadManager::new(max_parallel),
            download_dir: RwLock::new(dir),
            runtime,
        })
    })();

    match built {
        Ok(c) => {
            let core = CORE.get_or_init(|| c);
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
            let dir = core.download_dir.read().unwrap().clone();
            let tasks: Vec<DownloadDto> = rx
                .borrow()
                .iter()
                .map(|t| DownloadDto::from_task(t, &dir))
                .collect();
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
                for w in &page.wallpapers {
                    let _ = core.db.cache_wallpaper(w);
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

// ── downloads ─────────────────────────────────────────────────────────────

/// Enqueues a download. Progress arrives as `kind: "downloads"` pushes.
///
/// `json`: `{ "id": String, "url": String, "filename": String }`
///
/// # Safety
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

    core.runtime.spawn(async move {
        let dir = core.download_dir.read().unwrap().clone();
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
    let dir = core.download_dir.read().unwrap().clone();
    let tasks: Vec<DownloadDto> = core
        .runtime
        .block_on(core.downloads.get_tasks())
        .iter()
        .map(|t| DownloadDto::from_task(t, &dir))
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
        let dir = core.download_dir.read().unwrap().clone();
        let target = dir.join(&filename);
        if target.exists() {
            emit(
                id,
                serde_json::to_string(&Envelope::ok(
                    "localFile",
                    target.to_string_lossy().into_owned(),
                ))
                .unwrap_or_default(),
            );
            return;
        }
        let fetched = async {
            std::fs::create_dir_all(&dir)?;
            let bytes = reqwest::get(&url)
                .await
                .map_err(|e| WallsetterError::Http(e.to_string()))?
                .bytes()
                .await
                .map_err(|e| WallsetterError::Http(e.to_string()))?;
            std::fs::write(&target, &bytes)?;
            Ok::<_, WallsetterError>(target.to_string_lossy().into_owned())
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
    let listed = core.db.get_bookmarks(None).and_then(|marks| {
        let mut out = Vec::with_capacity(marks.len());
        for mark in &marks {
            if let Some(w) = core.db.get_cached_wallpaper(&mark.wallpaper_id)? {
                out.push(WallpaperDto::from(&w));
            }
        }
        Ok(out)
    });
    match listed {
        Ok(list) => to_c(serde_json::to_string(&Envelope::ok("favorites", list)).unwrap_or_default()),
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

    let toggled = (|| -> wallsetter_core::Result<bool> {
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
            None => return Err(WallsetterError::NotFound(wallpaper_id.clone())),
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

// ── preferences ───────────────────────────────────────────────────────────

/// Applies live preference changes (API key, download directory).
///
/// # Safety
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
        let resolved = resolve_dir(dir);
        let _ = std::fs::create_dir_all(&resolved);
        *core.download_dir.write().unwrap() = resolved;
    }
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

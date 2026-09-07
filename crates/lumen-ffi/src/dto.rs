//! Wire types shared with the Swift front end.
//!
//! These mirror the Swift `Codable` structs field-for-field, so the bridge is a
//! plain JSON string in each direction. Core's own models stay free to change
//! shape without breaking the UI.

use serde::{Deserialize, Serialize};
use std::path::Path;
use wallsetter_core::*;

/// Renders a filesystem path as a `file://` URL, which is what the Swift side
/// decodes these fields into. A bare path yields a scheme-less URL that
/// `AsyncImage` and `NSWorkspace` both reject.
pub fn file_url(path: &Path) -> String {
    let mut out = String::from("file://");
    for byte in path.to_string_lossy().as_bytes() {
        match byte {
            b'/' | b'-' | b'_' | b'.' | b'~' => out.push(*byte as char),
            b if b.is_ascii_alphanumeric() => out.push(*b as char),
            b => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

// ── inbound ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct FiltersDto {
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub purity: Vec<String>,
    #[serde(default)]
    pub sorting: String,
    #[serde(default)]
    pub ascending: bool,
    #[serde(default, rename = "topRange")]
    pub top_range: String,
    /// "atLeast" | "exactly"
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub resolution: String,
    /// Exact-match resolutions. Wallhaven accepts several, unlike `atleast`.
    #[serde(default, rename = "exactResolutions")]
    pub exact_resolutions: Vec<String>,
    #[serde(default)]
    pub ratios: Vec<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default = "one")]
    pub page: u32,
    /// Wallhaven's pagination seed. Random sort only stays stable across pages
    /// when the seed from the first response is sent back.
    #[serde(default)]
    pub seed: Option<String>,
    /// `true` shows only AI art, `false` hides it, absent leaves it alone.
    #[serde(default, rename = "aiArt")]
    pub ai_art: Option<bool>,
}

fn one() -> u32 {
    1
}

fn parse_resolution(s: &str) -> Option<Resolution> {
    let (w, h) = s.split_once('x')?;
    Some(Resolution::new(w.trim().parse().ok()?, h.trim().parse().ok()?))
}

impl FiltersDto {
    pub fn into_core(self) -> SearchFilters {
        let categories = self
            .categories
            .iter()
            .filter_map(|c| match c.as_str() {
                "general" => Some(Category::General),
                "anime" => Some(Category::Anime),
                "people" => Some(Category::People),
                _ => None,
            })
            .collect::<Vec<_>>();

        let purity = self
            .purity
            .iter()
            .filter_map(|p| match p.as_str() {
                "sfw" => Some(Purity::Sfw),
                "sketchy" => Some(Purity::Sketchy),
                "nsfw" => Some(Purity::Nsfw),
                _ => None,
            })
            .collect::<Vec<_>>();

        let sorting = match self.sorting.as_str() {
            "relevance" => Sorting::Relevance,
            "random" => Sorting::Random,
            "views" => Sorting::Views,
            "favorites" => Sorting::Favorites,
            "toplist" => Sorting::Toplist,
            "hot" => Sorting::Hot,
            _ => Sorting::DateAdded,
        };

        let toplist_range = match self.top_range.as_str() {
            "1d" => Some(ToplistRange::OneDay),
            "3d" => Some(ToplistRange::ThreeDays),
            "1w" => Some(ToplistRange::OneWeek),
            "1M" => Some(ToplistRange::OneMonth),
            "3M" => Some(ToplistRange::ThreeMonths),
            "6M" => Some(ToplistRange::SixMonths),
            "1y" => Some(ToplistRange::OneYear),
            _ => None,
        };

        let resolution = parse_resolution(&self.resolution);
        let exactly = self.mode == "exactly";

        SearchFilters {
            query: (!self.query.is_empty()).then(|| self.query.clone()),
            categories: if categories.is_empty() {
                vec![Category::General]
            } else {
                categories
            },
            purity: if purity.is_empty() {
                vec![Purity::Sfw]
            } else {
                purity
            },
            sorting,
            order: if self.ascending {
                SortOrder::Asc
            } else {
                SortOrder::Desc
            },
            toplist_range: (sorting == Sorting::Toplist).then_some(toplist_range).flatten(),
            atleast: (!exactly).then_some(resolution).flatten(),
            resolutions: if exactly {
                // Several exact resolutions are allowed; fall back to the
                // single value when none were picked.
                let listed: Vec<Resolution> = self
                    .exact_resolutions
                    .iter()
                    .filter_map(|r| parse_resolution(r))
                    .collect();
                if listed.is_empty() {
                    resolution.into_iter().collect()
                } else {
                    listed
                }
            } else {
                Vec::new()
            },
            ratios: self.ratios.clone(),
            colors: self.color.clone().into_iter().collect(),
            page: self.page.max(1),
            seed: self.seed.clone().filter(|s| !s.is_empty()),
            ai_art_filter: self.ai_art,
        }
    }
}

// ── outbound ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct WallpaperDto {
    pub id: String,
    pub url: Option<String>,
    pub path: String,
    pub thumb: String,
    pub resolution: String,
    pub ratio: f64,
    pub views: i64,
    pub favorites: i64,
    pub category: String,
    pub purity: String,
    #[serde(rename = "fileSize")]
    pub file_size: i64,
    #[serde(rename = "fileType")]
    pub file_type: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    /// Wallhaven username of whoever uploaded it, when the endpoint returns
    /// one. Search `@username` to see the rest of their uploads.
    pub uploader: Option<String>,
    /// Dominant palette, as hex without a leading `#`.
    pub colors: Vec<String>,
    pub tags: Vec<String>,
    /// Tags with their identity, so a tag page can look one up. `tags` stays a
    /// plain name list because that is all the grid needs.
    #[serde(rename = "tagRefs")]
    pub tag_refs: Vec<TagRefDto>,
    #[serde(rename = "localFile")]
    pub local_file: Option<String>,
}

impl From<&Wallpaper> for WallpaperDto {
    fn from(w: &Wallpaper) -> Self {
        Self {
            id: w.id.clone(),
            url: Some(w.url.clone()).filter(|s| !s.is_empty()),
            path: w.full_url.clone(),
            thumb: w.thumbnail_large.clone(),
            resolution: w.resolution.to_string(),
            ratio: w.ratio,
            views: w.views as i64,
            favorites: w.favorites as i64,
            category: w.category.to_string(),
            purity: w.purity.to_string(),
            file_size: w.file_size as i64,
            file_type: w.file_type.clone(),
            created_at: w
                .created_at
                .map(|d| d.format("%Y-%m-%d").to_string())
                .unwrap_or_default(),
            uploader: w.uploader.clone().filter(|u| !u.is_empty()),
            // Wallhaven returns colours as "#424153"; the search parameter and
            // the UI both want them bare, so strip it once here.
            colors: w
                .colors
                .iter()
                .map(|c| c.trim_start_matches('#').to_ascii_lowercase())
                .filter(|c| c.len() == 6)
                .collect(),
            tags: w.tags.iter().map(|t| t.name.clone()).collect(),
            tag_refs: w.tags.iter().map(TagRefDto::from).collect(),
            local_file: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TagRefDto {
    pub id: i64,
    pub name: String,
    pub category: String,
    pub purity: String,
}

impl From<&Tag> for TagRefDto {
    fn from(t: &Tag) -> Self {
        Self {
            id: t.id as i64,
            name: t.name.clone(),
            category: t.category.clone(),
            purity: t.purity.to_string(),
        }
    }
}

/// A tag as its own page: what Wallhaven knows about it beyond the name.
#[derive(Debug, Clone, Serialize)]
pub struct TagInfoDto {
    pub id: i64,
    pub name: String,
    pub alias: Option<String>,
    pub category: String,
    pub purity: String,
    #[serde(rename = "createdAt")]
    pub created_at: Option<String>,
}

impl From<&Tag> for TagInfoDto {
    fn from(t: &Tag) -> Self {
        Self {
            id: t.id as i64,
            name: t.name.clone(),
            alias: t.alias.clone().filter(|a| !a.is_empty()),
            category: t.category.clone(),
            purity: t.purity.to_string(),
            created_at: t.created_at.clone(),
        }
    }
}

/// One of an uploader's public collections on Wallhaven.
#[derive(Debug, Clone, Serialize)]
pub struct UploaderCollectionDto {
    pub id: i64,
    pub label: String,
    pub count: i64,
    pub views: i64,
    pub public: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchPageDto {
    pub wallpapers: Vec<WallpaperDto>,
    #[serde(rename = "currentPage")]
    pub current_page: u32,
    #[serde(rename = "lastPage")]
    pub last_page: u32,
    pub total: u32,
    /// Echoed back so the next page of a random sort stays consistent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seed: Option<String>,
}

impl From<&SearchResult> for SearchPageDto {
    fn from(r: &SearchResult) -> Self {
        Self {
            wallpapers: r.wallpapers.iter().map(WallpaperDto::from).collect(),
            current_page: r.current_page,
            last_page: r.last_page,
            total: r.total,
            seed: r.seed.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct DownloadDto {
    pub id: String,
    #[serde(rename = "wallpaperId")]
    pub wallpaper_id: String,
    pub filename: String,
    /// "Queued" | "Active" | "Done" | "Failed" | "Cancelled"
    pub state: String,
    pub progress: f64,
    #[serde(rename = "localFile")]
    pub local_file: Option<String>,
    pub error: Option<String>,
    #[serde(rename = "speedBps")]
    pub speed_bps: i64,
}

impl DownloadDto {
    /// The destination comes off the task itself: the download directory may
    /// have changed since this one was enqueued.
    pub fn from_task(t: &DownloadTask) -> Self {
        let state = match t.status {
            DownloadStatus::Queued => "Queued",
            DownloadStatus::Downloading => "Active",
            DownloadStatus::Completed => "Done",
            DownloadStatus::Failed => "Failed",
            DownloadStatus::Cancelled => "Cancelled",
        };
        let progress = match t.total_bytes {
            Some(total) if total > 0 => (t.bytes_downloaded as f64 / total as f64).clamp(0.0, 1.0),
            _ if t.status == DownloadStatus::Completed => 1.0,
            _ => 0.0,
        };
        Self {
            id: t.id.to_string(),
            wallpaper_id: t.wallpaper_id.clone(),
            filename: t.filename.clone(),
            state: state.to_string(),
            progress,
            local_file: (t.status == DownloadStatus::Completed)
                .then(|| file_url(&t.destination)),
            error: t.error.clone(),
            speed_bps: t.speed_bps as i64,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CollectionDto {
    pub id: String,
    pub name: String,
    pub wallpapers: Vec<WallpaperDto>,
}

/// A folder of wallpapers the user already has on disk.
#[derive(Debug, Clone, Serialize)]
pub struct ImportedFolderDto {
    pub id: String,
    pub name: String,
    pub path: String,
    pub count: u32,
}

/// One file inside an imported folder.
#[derive(Debug, Clone, Serialize)]
pub struct LocalWallpaperDto {
    pub id: String,
    #[serde(rename = "folderId")]
    pub folder_id: String,
    /// `file://` URL, so Swift can load and set it directly.
    pub url: String,
    pub path: String,
    pub filename: String,
    #[serde(rename = "fileSize")]
    pub file_size: i64,
    #[serde(rename = "isFavorite")]
    pub is_favorite: bool,
    /// Directory inside the imported root, empty at the top level.
    pub subpath: String,
}

/// One entry in the desktop's history.
#[derive(Debug, Clone, Serialize)]
pub struct HistoryEntryDto {
    #[serde(rename = "wallpaperId")]
    pub wallpaper_id: Option<String>,
    pub url: String,
    pub label: String,
    #[serde(rename = "setAt")]
    pub set_at: String,
}

/// A saved search that is re-run in the background.
#[derive(Debug, Clone, Serialize)]
pub struct SubscriptionDto {
    pub id: String,
    pub query: String,
    pub label: String,
    #[serde(rename = "minFavorites")]
    pub min_favorites: u32,
    /// Matches found since the user last looked.
    pub unseen: u32,
}

/// Every callback payload is this envelope, so Swift decodes one shape.
#[derive(Debug, Clone, Serialize)]
pub struct Envelope<T: Serialize> {
    pub ok: bool,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl<T: Serialize> Envelope<T> {
    pub fn ok(kind: &str, data: T) -> Self {
        Self { ok: true, kind: kind.into(), data: Some(data), error: None }
    }
}

pub fn err_json(kind: &str, message: impl std::fmt::Display) -> String {
    serde_json::json!({ "ok": false, "kind": kind, "error": message.to_string() }).to_string()
}

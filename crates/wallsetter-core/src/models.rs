use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ──────────────────────────────────────────────
// Wallpaper Provider (extensible enum)
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WallpaperProvider {
    Wallhaven,
    // Future: Unsplash, Pexels, Bing, etc.
}

impl std::fmt::Display for WallpaperProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Wallhaven => write!(f, "wallhaven"),
        }
    }
}

// ──────────────────────────────────────────────
// Wallpaper
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Wallpaper {
    pub id: String,
    pub provider: WallpaperProvider,
    pub url: String,
    pub short_url: Option<String>,
    pub full_url: String, // direct link to full image
    pub thumbnail_small: String,
    pub thumbnail_large: String,
    pub thumbnail_original: String,
    pub uploader: Option<String>,
    pub resolution: Resolution,
    pub file_size: u64,
    pub file_type: String, // "image/jpeg", "image/png"
    pub category: Category,
    pub purity: Purity,
    pub colors: Vec<String>, // hex colors
    pub tags: Vec<Tag>,
    pub source: Option<String>,
    pub views: u64,
    pub favorites: u64,
    pub ratio: f64,
    pub created_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Resolution {
    pub width: u32,
    pub height: u32,
}

impl std::fmt::Display for Resolution {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}x{}", self.width, self.height)
    }
}

impl Resolution {
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tag {
    pub id: u64,
    pub name: String,
    pub alias: Option<String>,
    pub category_id: u64,
    pub category: String,
    pub purity: Purity,
    pub created_at: Option<String>,
}

// ──────────────────────────────────────────────
// Enums for filters
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Category {
    #[default]
    General,
    Anime,
    People,
}

impl std::fmt::Display for Category {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::General => write!(f, "general"),
            Self::Anime => write!(f, "anime"),
            Self::People => write!(f, "people"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Purity {
    #[default]
    Sfw,
    Sketchy,
    Nsfw,
}

impl std::fmt::Display for Purity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Sfw => write!(f, "sfw"),
            Self::Sketchy => write!(f, "sketchy"),
            Self::Nsfw => write!(f, "nsfw"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Sorting {
    #[default]
    DateAdded,
    Relevance,
    Random,
    Views,
    Favorites,
    Toplist,
    Hot,
}

impl Sorting {
    pub fn as_api_str(&self) -> &'static str {
        match self {
            Self::DateAdded => "date_added",
            Self::Relevance => "relevance",
            Self::Random => "random",
            Self::Views => "views",
            Self::Favorites => "favorites",
            Self::Toplist => "toplist",
            Self::Hot => "hot",
        }
    }
}

impl std::fmt::Display for Sorting {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DateAdded => write!(f, "Date Added"),
            Self::Relevance => write!(f, "Relevance"),
            Self::Random => write!(f, "Random"),
            Self::Views => write!(f, "Views"),
            Self::Favorites => write!(f, "Favorites"),
            Self::Toplist => write!(f, "Toplist"),
            Self::Hot => write!(f, "Hot"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SortOrder {
    #[default]
    Desc,
    Asc,
}

impl SortOrder {
    pub fn as_api_str(&self) -> &'static str {
        match self {
            Self::Desc => "desc",
            Self::Asc => "asc",
        }
    }
}

impl std::fmt::Display for SortOrder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Desc => write!(f, "Descending"),
            Self::Asc => write!(f, "Ascending"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum ToplistRange {
    OneDay,
    ThreeDays,
    OneWeek,
    OneMonth,
    ThreeMonths,
    #[default]
    SixMonths,
    OneYear,
}

impl ToplistRange {
    pub fn as_api_str(&self) -> &'static str {
        match self {
            Self::OneDay => "1d",
            Self::ThreeDays => "3d",
            Self::OneWeek => "1w",
            Self::OneMonth => "1M",
            Self::ThreeMonths => "3M",
            Self::SixMonths => "6M",
            Self::OneYear => "1y",
        }
    }
}

impl std::fmt::Display for ToplistRange {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::OneDay => write!(f, "1 Day"),
            Self::ThreeDays => write!(f, "3 Days"),
            Self::OneWeek => write!(f, "1 Week"),
            Self::OneMonth => write!(f, "1 Month"),
            Self::ThreeMonths => write!(f, "3 Months"),
            Self::SixMonths => write!(f, "6 Months"),
            Self::OneYear => write!(f, "1 Year"),
        }
    }
}

// ──────────────────────────────────────────────
// Search
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SearchFilters {
    pub query: Option<String>,
    pub categories: Vec<Category>,
    pub purity: Vec<Purity>,
    pub sorting: Sorting,
    pub order: SortOrder,
    pub toplist_range: Option<ToplistRange>,
    pub atleast: Option<Resolution>, // minimum resolution
    pub resolutions: Vec<Resolution>,
    pub ratios: Vec<String>, // "16x9", "16x10", etc.
    pub colors: Vec<String>, // hex colors without #
    pub page: u32,
    pub seed: Option<String>, // for random pagination
    pub ai_art_filter: Option<bool>,
}

impl SearchFilters {
    pub fn new() -> Self {
        Self {
            page: 1,
            categories: vec![Category::General, Category::Anime, Category::People],
            purity: vec![Purity::Sfw],
            ..Default::default()
        }
    }

    pub fn with_query(mut self, query: impl Into<String>) -> Self {
        self.query = Some(query.into());
        self
    }

    pub fn with_page(mut self, page: u32) -> Self {
        self.page = page;
        self
    }

    pub fn with_sorting(mut self, sorting: Sorting) -> Self {
        self.sorting = sorting;
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub wallpapers: Vec<Wallpaper>,
    pub current_page: u32,
    pub last_page: u32,
    pub total: u32,
    pub seed: Option<String>,
}

// ──────────────────────────────────────────────
// Download
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DownloadStatus {
    Queued,
    Downloading,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadTask {
    pub id: Uuid,
    pub wallpaper_id: String,
    pub url: String,
    pub filename: String,
    pub status: DownloadStatus,
    pub bytes_downloaded: u64,
    pub total_bytes: Option<u64>,
    pub speed_bps: u64, // bytes per second
    pub created_at: DateTime<Utc>,
    pub error: Option<String>,
}

impl DownloadTask {
    pub fn new(wallpaper_id: String, url: String, filename: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            wallpaper_id,
            url,
            filename,
            status: DownloadStatus::Queued,
            bytes_downloaded: 0,
            total_bytes: None,
            speed_bps: 0,
            created_at: Utc::now(),
            error: None,
        }
    }

    pub fn progress_percent(&self) -> Option<f32> {
        self.total_bytes.map(|total| {
            if total == 0 {
                0.0
            } else {
                (self.bytes_downloaded as f32 / total as f32) * 100.0
            }
        })
    }
}

// ──────────────────────────────────────────────
// Bookmarks
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookmarkFolder {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub icon: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl BookmarkFolder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            description: None,
            icon: None,
            created_at: Utc::now(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bookmark {
    pub id: Uuid,
    pub wallpaper_id: String,
    pub provider: WallpaperProvider,
    pub folder_id: Option<Uuid>,
    pub added_at: DateTime<Utc>,
    pub thumbnail_url: String,
    pub resolution: Resolution,
}

impl Bookmark {
    pub fn new(wallpaper: &Wallpaper, folder_id: Option<Uuid>) -> Self {
        Self {
            id: Uuid::new_v4(),
            wallpaper_id: wallpaper.id.clone(),
            provider: wallpaper.provider,
            folder_id,
            added_at: Utc::now(),
            thumbnail_url: wallpaper.thumbnail_small.clone(),
            resolution: wallpaper.resolution,
        }
    }
}

// ──────────────────────────────────────────────
// Preferences
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppPreferences {
    pub api_key: Option<String>,
    pub download_dir: String,
    pub thumbnail_cache_dir: String,
    pub default_filters: SearchFilters,
    pub theme: Theme,
    #[serde(default = "default_grid_columns")]
    pub grid_columns: u32,
    pub max_parallel_downloads: u32,
    pub scheduler: SchedulerConfig,
}

fn default_grid_columns() -> u32 {
    4
}

impl Default for AppPreferences {
    fn default() -> Self {
        Self {
            api_key: None,
            download_dir: "~/Pictures/Wallpapers".to_string(),
            thumbnail_cache_dir: String::new(), // set at runtime
            default_filters: SearchFilters::new(),
            theme: Theme::Dark,
            grid_columns: default_grid_columns(),
            max_parallel_downloads: 4,
            scheduler: SchedulerConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    Light,
    #[default]
    Dark,
}

// ──────────────────────────────────────────────
// Scheduler
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulerConfig {
    pub enabled: bool,
    pub mode: SchedulerMode,
    pub interval_minutes: u32,
    pub time_slots: Vec<TimeSlot>,
    pub source: SchedulerSource,
    pub shuffle: bool,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: SchedulerMode::Interval,
            interval_minutes: 30,
            time_slots: Vec::new(),
            source: SchedulerSource::DownloadDir,
            shuffle: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SchedulerMode {
    #[default]
    Interval,
    TimeOfDay,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimeSlot {
    pub hour_start: u8, // 0-23
    pub hour_end: u8,   // 0-23
    pub label: String,  // "Morning", "Evening", etc.
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SchedulerSource {
    #[default]
    DownloadDir,
    BookmarkFolder(Uuid),
    DownloadFolder(Uuid),
    CustomDir(String),
}

// ──────────────────────────────────────────────
// Collection (from Wallhaven)
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Collection {
    pub id: u64,
    pub label: String,
    pub views: u64,
    pub public: bool,
    pub count: u64,
}

// ──────────────────────────────────────────────
// Wallpaper History
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WallpaperHistory {
    pub wallpaper_id: String,
    pub local_path: String,
    pub set_at: DateTime<Utc>,
    pub provider: WallpaperProvider,
}

// ──────────────────────────────────────────────
// Download Record (for DB persistence)
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadRecord {
    pub wallpaper_id: String,
    pub provider: WallpaperProvider,
    pub local_path: String,
    pub file_size: u64,
    pub downloaded_at: DateTime<Utc>,
}

// ──────────────────────────────────────────────
// Download Folders (local organization)
// ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadFolder {
    pub id: Uuid,
    pub name: String,
    pub created_at: DateTime<Utc>,
}

impl DownloadFolder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            created_at: Utc::now(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalWallpaper {
    pub id: Uuid,
    pub folder_id: Option<Uuid>,
    pub wallpaper_id: String,
    pub local_path: String,
    pub filename: String,
    pub resolution: Resolution,
    pub file_size: u64,
    pub downloaded_at: DateTime<Utc>,
}

impl LocalWallpaper {
    pub fn new(
        folder_id: Option<Uuid>,
        wallpaper_id: String,
        local_path: String,
        filename: String,
        resolution: Resolution,
        file_size: u64,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            folder_id,
            wallpaper_id,
            local_path,
            filename,
            resolution,
            file_size,
            downloaded_at: Utc::now(),
        }
    }
}

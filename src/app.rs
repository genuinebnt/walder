use iced::widget::{button, column, container, row, text};
use iced::{Element, Length, Task, Theme as IcedTheme};
use reqwest;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
// Removed unused tracing imports

use wallsetter_core::*;
use wallsetter_db::Database;
use wallsetter_downloader::DownloadManager;
use wallsetter_provider::WallhavenClient;
use wallsetter_scheduler::Scheduler;
use wallsetter_setter::DesktopWallpaperSetter;

use crate::theme::active_theme;

pub struct WallsetterApp {
    // Core state
    db: Arc<Database>,
    provider: Arc<WallhavenClient>,
    #[allow(dead_code)]
    downloader: Arc<DownloadManager>,
    #[allow(dead_code)]
    setter: Arc<DesktopWallpaperSetter>,
    #[allow(dead_code)]
    scheduler: Arc<Scheduler>,

    // UI state
    current_view: View,
    preferences: AppPreferences,
    active_filters: SearchFilters,

    // Search state
    search_query: String,
    search_sidebar_visible: bool,
    search_results: Option<SearchResult>,
    is_searching: bool,
    is_appending_search_results: bool,
    related_tags: Vec<(String, u32)>,
    author_username: Option<String>,
    author_results: Option<SearchResult>,
    is_loading_author: bool,
    thumbnails: HashMap<String, iced::widget::image::Handle>,
    thumbnail_sources: HashMap<String, String>,
    full_images: HashMap<String, iced::widget::image::Handle>,
    preview_loading_frame: usize,
    selected_wallpapers: HashSet<String>,
    resolution_mode: ResolutionMode,
    resolution_filter_input: String,
    atleast_resolution_input: String,
    ratio_filter_input: String,
    color_filter_input: String,
    // Download state
    download_tasks: Vec<DownloadTask>,

    // Bookmarks state
    bookmarks: Vec<Bookmark>,
    bookmark_folders: Vec<BookmarkFolder>,

    // Error state
    error_message: Option<String>,

    // Navigation history
    previous_view: Option<Box<View>>,
}

#[derive(Debug, Clone)]
pub enum View {
    Search,
    Downloads,
    Bookmarks,
    Settings,
    Preview(Wallpaper),
    AuthorProfile(String),
}

#[derive(Debug, Clone)]
pub enum Message {
    // Navigation
    SwitchView(View),

    // Search
    SearchQueryChanged(String),
    SearchByTag(String),
    ToggleSearchSidebar,
    SubmitSearch,
    SearchScrolled(iced::widget::scrollable::Viewport),
    SearchCompleted(std::result::Result<SearchResult, String>),
    ThumbnailLoaded(
        String,
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ),
    FullImageLoaded(
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ),
    PreviewWallpaperLoaded(std::result::Result<Wallpaper, String>),

    // Preview & Set
    GoBack,
    DownloadSingle(Wallpaper),
    SetWallpaper(std::path::PathBuf),
    OpenAuthorProfile(String),

    // Bookmarks
    LoadBookmarks,
    BookmarksLoaded(std::result::Result<(Vec<Bookmark>, Vec<BookmarkFolder>), String>),
    AddBookmark(Wallpaper),
    OpenBookmark(String),
    BookmarkWallpaperLoaded(std::result::Result<Wallpaper, String>),

    // Selection & Download
    TileClicked(String),
    SelectAll,
    DeselectAll,
    DownloadSelected,
    BookmarkSelected,
    QuickSet(Wallpaper),
    QuickSetCompleted(std::result::Result<(), String>),
    DownloadAuthorWorks,
    DownloadAllAuthorWorks,
    DownloadAllAuthorWorksCompleted(std::result::Result<usize, String>),

    // Pagination
    NextPage,
    PreviousPage,
    AuthorNextPage,
    AuthorPreviousPage,

    // Author works
    AuthorWorksLoaded(std::result::Result<SearchResult, String>),

    // Grid layout
    GridColumnsChanged(u32),

    // Filters
    ToggleCategory(Category, bool),
    TogglePurity(Purity, bool),
    SortingChanged(Sorting),
    SortOrderChanged(SortOrder),
    ToplistRangeChanged(ToplistRange),
    ResolutionModeChanged(ResolutionMode),
    ToggleResolutionFilter(Resolution, bool),
    ToggleRatioFilter(String, bool),
    AtleastResolutionChanged(String),
    ResolutionFilterChanged(String),
    RatioFilterChanged(String),
    ColorFilterChanged(String),
    SaveFiltersAsDefault,

    // Downloads
    Tick,
    PreviewLoadingTick,
    DownloadsUpdated(Vec<DownloadTask>),

    // Theme & Settings
    ToggleTheme,
    SettingsChanged(SettingsMessage),

    // Errors
    ClearError,
}

#[derive(Debug, Clone)]
pub enum SettingsMessage {
    ApiKeyChanged(String),
    DownloadDirChanged(String),
    MaxParallelChanged(String),
    SchedulerEnabledChanged(bool),
    SchedulerIntervalChanged(String),
    SchedulerShuffleChanged(bool),
    Save,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolutionMode {
    AtLeast,
    Exactly,
}

impl std::fmt::Display for ResolutionMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AtLeast => write!(f, "At Least"),
            Self::Exactly => write!(f, "Exactly"),
        }
    }
}

impl WallsetterApp {
    const GRID_COLUMN_PRESETS: [u32; 3] = [3, 4, 6];

    fn normalize_grid_columns(cols: u32) -> u32 {
        let mut best = Self::GRID_COLUMN_PRESETS[0];
        let mut best_delta = cols.abs_diff(best);

        for candidate in Self::GRID_COLUMN_PRESETS.iter().skip(1) {
            let delta = cols.abs_diff(*candidate);
            if delta < best_delta {
                best = *candidate;
                best_delta = delta;
            }
        }

        best
    }

    pub fn new(
        db: Arc<Database>,
        provider: Arc<WallhavenClient>,
        downloader: Arc<DownloadManager>,
        setter: Arc<DesktopWallpaperSetter>,
        scheduler: Arc<Scheduler>,
    ) -> (Self, Task<Message>) {
        let mut preferences = db.get_preferences().unwrap_or_default();
        preferences.grid_columns = Self::normalize_grid_columns(preferences.grid_columns);
        preferences.max_parallel_downloads = preferences.max_parallel_downloads.clamp(1, 10);
        preferences.scheduler.interval_minutes = preferences.scheduler.interval_minutes.max(1);

        let mut active_filters = preferences.default_filters.clone();
        Self::sanitize_filters(&mut active_filters);
        let resolution_mode = if active_filters.atleast.is_some() {
            ResolutionMode::AtLeast
        } else {
            ResolutionMode::Exactly
        };
        let resolution_filter_input = Self::format_resolution_filters(&active_filters.resolutions);
        let atleast_resolution_input =
            Self::format_atleast_resolution_filter(active_filters.atleast.as_ref());
        let ratio_filter_input = Self::format_ratio_filters(&active_filters.ratios);
        let color_filter_input = Self::format_color_filters(&active_filters.colors);

        let app = Self {
            db,
            provider,
            downloader,
            setter,
            scheduler,
            current_view: View::Search,
            preferences,
            active_filters,
            search_query: String::new(),
            search_sidebar_visible: true,
            search_results: None,
            is_searching: false,
            is_appending_search_results: false,
            related_tags: Vec::new(),
            author_username: None,
            author_results: None,
            is_loading_author: false,
            thumbnails: HashMap::new(),
            thumbnail_sources: HashMap::new(),
            full_images: HashMap::new(),
            preview_loading_frame: 0,
            selected_wallpapers: HashSet::new(),
            resolution_mode,
            resolution_filter_input,
            atleast_resolution_input,
            ratio_filter_input,
            color_filter_input,
            download_tasks: Vec::new(),
            bookmarks: Vec::new(),
            bookmark_folders: Vec::new(),
            error_message: None,
            previous_view: None,
        };

        // Initial task (e.g., fetch initial wallpapers)
        let initial_task = Task::perform(
            Self::fetch_initial_wallpapers(
                app.provider.clone(),
                app.preferences.default_filters.clone(),
            ),
            Message::SearchCompleted,
        );

        (app, initial_task)
    }

    async fn fetch_initial_wallpapers(
        provider: Arc<WallhavenClient>,
        filters: SearchFilters,
    ) -> std::result::Result<SearchResult, String> {
        provider.search(&filters).await.map_err(|e| e.to_string())
    }

    async fn fetch_wallpaper(
        provider: Arc<WallhavenClient>,
        wallpaper_id: String,
    ) -> std::result::Result<Wallpaper, String> {
        provider
            .get_wallpaper(&wallpaper_id)
            .await
            .map_err(|e| e.to_string())
    }

    async fn fetch_author_wallpapers(
        provider: Arc<WallhavenClient>,
        username: String,
        page: u32,
        base_filters: SearchFilters,
    ) -> std::result::Result<SearchResult, String> {
        let mut filters = base_filters;
        Self::sanitize_filters(&mut filters);
        filters.query = Some(format!("@{}", username.trim()));
        filters.page = page.max(1);
        filters.seed = None;
        provider.search(&filters).await.map_err(|e| e.to_string())
    }

    async fn queue_all_author_works(
        provider: Arc<WallhavenClient>,
        downloader: Arc<DownloadManager>,
        username: String,
        download_dir: String,
        filters: SearchFilters,
    ) -> std::result::Result<usize, String> {
        let mut page = 1;
        let mut items: Vec<(String, String, String)> = Vec::new();

        loop {
            let result = Self::fetch_author_wallpapers(
                provider.clone(),
                username.clone(),
                page,
                filters.clone(),
            )
            .await?;
            let last_page = result.last_page;

            for wp in result.wallpapers {
                let filename = format!("{}.{}", wp.id, wp.file_type.replace("image/", ""));
                items.push((wp.id, wp.full_url, filename));
            }

            if page >= last_page {
                break;
            }
            page += 1;
        }

        if items.is_empty() {
            return Ok(0);
        }

        let count = items.len();
        let dest = resolve_download_dir(&download_dir);
        downloader
            .enqueue_bulk(items, &dest)
            .await
            .map_err(|e| e.to_string())?;

        Ok(count)
    }

    async fn fetch_thumbnail(
        id: String,
        url: String,
    ) -> (
        String,
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ) {
        let result = async {
            let bytes = reqwest::get(&url).await?.bytes().await?;
            // We use image crate to detect format or just load it directly using Iced
            // Provide bytes to Handle::from_memory
            Ok(iced::widget::image::Handle::from_bytes(bytes.to_vec()))
        }
        .await
        .map_err(|e: reqwest::Error| e.to_string());

        (id, url, result)
    }

    async fn fetch_full_image(
        id: String,
        url: String,
        local_path: Option<std::path::PathBuf>,
    ) -> (
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ) {
        let result = async {
            if let Some(path) = local_path
                && path.exists()
            {
                let bytes = tokio::fs::read(&path)
                    .await
                    .map_err(|e| format!("Failed to read local preview file: {e}"))?;
                return Ok(iced::widget::image::Handle::from_bytes(bytes));
            }

            let bytes = reqwest::get(&url)
                .await
                .map_err(|e| e.to_string())?
                .bytes()
                .await
                .map_err(|e| e.to_string())?;
            Ok(iced::widget::image::Handle::from_bytes(bytes.to_vec()))
        }
        .await;

        (id, result)
    }

    fn local_wallpaper_path(download_dir: &str, wp: &Wallpaper) -> Option<std::path::PathBuf> {
        let mut expected = resolve_download_dir(download_dir);
        let extension = wp
            .file_type
            .strip_prefix("image/")
            .filter(|ext| !ext.is_empty())
            .unwrap_or("jpg");
        expected.push(format!("{}.{}", wp.id, extension));

        if expected.exists() {
            return Some(expected);
        }

        let directory = resolve_download_dir(download_dir);
        let prefix = format!("{}.", wp.id);

        let entries = std::fs::read_dir(&directory).ok()?;
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            if file_name.to_string_lossy().starts_with(&prefix) {
                let path = entry.path();
                if path.is_file() {
                    return Some(path);
                }
            }
        }

        None
    }

    async fn quick_set_wallpaper(
        setter: Arc<DesktopWallpaperSetter>,
        download_dir: String,
        wp: Wallpaper,
    ) -> std::result::Result<(), String> {
        let filename = format!("{}.{}", wp.id, wp.file_type.replace("image/", ""));
        let mut path = resolve_download_dir(&download_dir);
        path.push(&filename);

        if !path.exists() {
            if let Some(parent) = path.parent() {
                tokio::fs::create_dir_all(parent)
                    .await
                    .map_err(|e| format!("Failed to create download directory: {}", e))?;
            }

            let resp = reqwest::get(&wp.full_url)
                .await
                .map_err(|e| format!("Failed to download wallpaper: {}", e))?;

            if !resp.status().is_success() {
                return Err(format!(
                    "Failed to download wallpaper: HTTP {}",
                    resp.status()
                ));
            }

            let bytes = resp
                .bytes()
                .await
                .map_err(|e| format!("Failed to read image bytes: {}", e))?;

            tokio::fs::write(&path, &bytes)
                .await
                .map_err(|e| format!("Failed to save wallpaper: {}", e))?;
        }

        setter
            .set_wallpaper(&path)
            .map_err(|e| format!("Failed to set wallpaper: {}", e))?;

        Ok(())
    }

    pub fn title(&self) -> String {
        String::from("Walder")
    }

    fn has_active_downloads(&self) -> bool {
        self.download_tasks.iter().any(|task| {
            matches!(
                task.status,
                DownloadStatus::Queued | DownloadStatus::Downloading
            )
        })
    }

    fn should_poll_downloads(&self) -> bool {
        matches!(self.current_view, View::Downloads) || self.has_active_downloads()
    }

    fn is_preview_loading(&self) -> bool {
        if let View::Preview(wallpaper) = &self.current_view {
            !self.full_images.contains_key(&wallpaper.id)
        } else {
            false
        }
    }

    fn sanitize_filters(filters: &mut SearchFilters) {
        if filters.categories.is_empty() {
            filters.categories = vec![Category::General];
        }

        if filters.purity.is_empty() {
            filters.purity = vec![Purity::Sfw];
        }

        if filters.page == 0 {
            filters.page = 1;
        }
    }

    fn parse_resolution_filters(raw: &str) -> Vec<Resolution> {
        let mut parsed = Vec::new();

        for token in raw.split(',') {
            let normalized = token
                .trim()
                .to_lowercase()
                .replace(':', "x")
                .replace(' ', "");

            if normalized.is_empty() {
                continue;
            }

            let Some((w, h)) = normalized.split_once('x') else {
                continue;
            };

            let (Ok(width), Ok(height)) = (w.parse::<u32>(), h.parse::<u32>()) else {
                continue;
            };

            if width == 0 || height == 0 {
                continue;
            }

            let candidate = Resolution::new(width, height);
            if parsed
                .iter()
                .all(|existing: &Resolution| existing.width != width || existing.height != height)
            {
                parsed.push(candidate);
            }
        }

        parsed
    }

    fn parse_single_resolution_filter(raw: &str) -> Option<Resolution> {
        Self::parse_resolution_filters(raw).into_iter().next()
    }

    fn parse_ratio_filters(raw: &str) -> Vec<String> {
        let mut parsed = Vec::new();

        for token in raw.split(',') {
            let normalized = token
                .trim()
                .to_lowercase()
                .replace(':', "x")
                .replace(' ', "");

            if normalized.is_empty() {
                continue;
            }

            if normalized == "landscape" || normalized == "allwide" {
                let candidate = "landscape".to_string();
                if !parsed.contains(&candidate) {
                    parsed.push(candidate);
                }
                continue;
            }

            if normalized == "portrait" || normalized == "allportrait" {
                let candidate = "portrait".to_string();
                if !parsed.contains(&candidate) {
                    parsed.push(candidate);
                }
                continue;
            }

            let Some((w, h)) = normalized.split_once('x') else {
                continue;
            };

            let (Ok(width), Ok(height)) = (w.parse::<u32>(), h.parse::<u32>()) else {
                continue;
            };

            if width == 0 || height == 0 {
                continue;
            }

            let candidate = format!("{width}x{height}");
            if !parsed.contains(&candidate) {
                parsed.push(candidate);
            }
        }

        parsed
    }

    fn format_resolution_filters(resolutions: &[Resolution]) -> String {
        resolutions
            .iter()
            .map(|res| format!("{}x{}", res.width, res.height))
            .collect::<Vec<_>>()
            .join(", ")
    }

    fn format_atleast_resolution_filter(resolution: Option<&Resolution>) -> String {
        resolution
            .map(|res| format!("{}x{}", res.width, res.height))
            .unwrap_or_default()
    }

    fn format_ratio_filters(ratios: &[String]) -> String {
        ratios.join(", ")
    }

    fn parse_color_filters(raw: &str) -> Vec<String> {
        for token in raw.split([',', ' ']) {
            let candidate = token.trim().trim_start_matches('#').to_lowercase();
            if candidate.len() == 6 && candidate.chars().all(|c| c.is_ascii_hexdigit()) {
                return vec![candidate];
            }
        }

        Vec::new()
    }

    fn format_color_filters(colors: &[String]) -> String {
        colors
            .first()
            .map(|color| format!("#{color}"))
            .unwrap_or_default()
    }

    fn sync_input_filters_into_active(&mut self) {
        self.active_filters.ratios = Self::parse_ratio_filters(&self.ratio_filter_input);
        self.active_filters.colors = Self::parse_color_filters(&self.color_filter_input);

        match self.resolution_mode {
            ResolutionMode::AtLeast => {
                self.active_filters.atleast =
                    Self::parse_single_resolution_filter(&self.atleast_resolution_input);
                self.active_filters.resolutions.clear();
            }
            ResolutionMode::Exactly => {
                self.active_filters.atleast = None;
                self.active_filters.resolutions =
                    Self::parse_resolution_filters(&self.resolution_filter_input);
            }
        }

        if self.active_filters.sorting == Sorting::Toplist {
            if self.active_filters.toplist_range.is_none() {
                self.active_filters.toplist_range = Some(ToplistRange::SixMonths);
            }
        } else {
            self.active_filters.toplist_range = None;
        }
    }

    fn strip_ascii_prefix_ci<'a>(input: &'a str, prefix: &str) -> Option<&'a str> {
        let head = input.get(..prefix.len())?;
        if head.eq_ignore_ascii_case(prefix) {
            input.get(prefix.len()..)
        } else {
            None
        }
    }

    fn parse_primary_tag_query(raw: &str) -> Option<String> {
        let mut tokens = raw.split_whitespace().peekable();

        while let Some(token) = tokens.next() {
            let token = token.trim();
            if token.is_empty() || token.starts_with('-') {
                continue;
            }

            let unsigned = token.trim_start_matches('+');
            let candidate = if let Some(rest) = unsigned.strip_prefix('#') {
                Some(rest)
            } else if unsigned.eq_ignore_ascii_case("tag:") {
                tokens
                    .next()
                    .map(str::trim)
                    .map(|next| next.trim_start_matches('#'))
            } else {
                Self::strip_ascii_prefix_ci(unsigned, "tag:")
            };

            if let Some(raw_tag) = candidate {
                let normalized = raw_tag
                    .trim()
                    .trim_start_matches('#')
                    .trim_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-'))
                    .to_lowercase();

                if !normalized.is_empty() {
                    return Some(normalized);
                }
            }
        }

        None
    }

    fn normalize_search_query_for_api(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }

        let mut normalized_tokens: Vec<String> = Vec::new();
        let mut tokens = trimmed.split_whitespace().peekable();

        while let Some(token) = tokens.next() {
            let token = token.trim();
            if token.is_empty() {
                continue;
            }

            let (sign, unsigned) = if let Some(rest) = token.strip_prefix('+') {
                ("+", rest)
            } else if let Some(rest) = token.strip_prefix('-') {
                ("-", rest)
            } else {
                ("", token)
            };

            let unsigned = unsigned.trim();
            if unsigned.is_empty() {
                continue;
            }

            let normalized = if unsigned.eq_ignore_ascii_case("author:") {
                tokens.next().and_then(|next| {
                    let username = next.trim().trim_start_matches('@');
                    if username.is_empty() {
                        None
                    } else {
                        Some(format!("{sign}@{username}"))
                    }
                })
            } else if let Some(rest) = Self::strip_ascii_prefix_ci(unsigned, "author:") {
                let username = rest.trim().trim_start_matches('@');
                if username.is_empty() {
                    None
                } else {
                    Some(format!("{sign}@{username}"))
                }
            } else if unsigned.eq_ignore_ascii_case("tag:") {
                tokens.next().and_then(|next| {
                    let tag = next.trim().trim_start_matches('#');
                    if tag.is_empty() {
                        None
                    } else {
                        Some(format!("{sign}{tag}"))
                    }
                })
            } else if let Some(rest) = Self::strip_ascii_prefix_ci(unsigned, "tag:") {
                let tag = rest.trim().trim_start_matches('#');
                if tag.is_empty() {
                    None
                } else {
                    Some(format!("{sign}{tag}"))
                }
            } else if let Some(rest) = unsigned.strip_prefix('#') {
                let tag = rest.trim();
                if tag.is_empty() {
                    None
                } else {
                    Some(format!("{sign}{tag}"))
                }
            } else {
                Some(format!("{sign}{unsigned}"))
            };

            if let Some(normalized) = normalized {
                let cleaned = normalized.trim();
                if !cleaned.is_empty() {
                    normalized_tokens.push(cleaned.to_string());
                }
            }
        }

        if normalized_tokens.is_empty() {
            None
        } else {
            Some(normalized_tokens.join(" "))
        }
    }

    fn derive_related_tags(
        results: &SearchResult,
        primary_tag: &str,
        limit: usize,
    ) -> Vec<(String, u32)> {
        let mut counts: HashMap<String, u32> = HashMap::new();

        for wallpaper in &results.wallpapers {
            let mut seen: HashSet<String> = HashSet::new();

            for tag in &wallpaper.tags {
                let name = tag.name.trim().to_lowercase();
                if name.is_empty() || name == primary_tag {
                    continue;
                }

                if seen.insert(name.clone()) {
                    *counts.entry(name).or_insert(0) += 1;
                }
            }
        }

        let mut related: Vec<(String, u32)> = counts.into_iter().collect();
        related.sort_by(|(name_a, count_a), (name_b, count_b)| {
            count_b.cmp(count_a).then_with(|| name_a.cmp(name_b))
        });
        related.truncate(limit);
        related
    }

    fn preferred_thumbnail_url(wp: &Wallpaper, grid_columns: u32) -> String {
        match Self::normalize_grid_columns(grid_columns) {
            3 => wp.thumbnail_original.clone(),
            4 => wp.thumbnail_large.clone(),
            _ => wp.thumbnail_small.clone(),
        }
    }

    fn should_fetch_thumbnail(&self, id: &str, source_url: &str) -> bool {
        match self.thumbnail_sources.get(id) {
            Some(existing) => existing != source_url,
            None => true,
        }
    }

    fn build_thumbnail_tasks_for_wallpapers<'a, I>(&mut self, wallpapers: I) -> Vec<Task<Message>>
    where
        I: IntoIterator<Item = &'a Wallpaper>,
    {
        let grid_columns = self.preferences.grid_columns;
        wallpapers
            .into_iter()
            .filter_map(|wp| {
                let thumb_url = Self::preferred_thumbnail_url(wp, grid_columns);
                if self.should_fetch_thumbnail(&wp.id, &thumb_url) {
                    self.thumbnail_sources
                        .insert(wp.id.clone(), thumb_url.clone());
                    Some(Task::perform(
                        Self::fetch_thumbnail(wp.id.clone(), thumb_url),
                        |(id, url, res)| Message::ThumbnailLoaded(id, url, res),
                    ))
                } else {
                    None
                }
            })
            .collect()
    }

    fn push_local_thumbnail_if_available(&mut self, task: &DownloadTask) {
        if self.thumbnails.contains_key(&task.wallpaper_id) {
            return;
        }

        if task.status != DownloadStatus::Completed {
            return;
        }

        let mut path = resolve_download_dir(&self.preferences.download_dir);
        path.push(&task.filename);
        if path.exists() {
            self.thumbnails.insert(
                task.wallpaper_id.clone(),
                iced::widget::image::Handle::from_path(path),
            );
        }
    }

    fn is_same_view(a: &View, b: &View) -> bool {
        match (a, b) {
            (View::Search, View::Search)
            | (View::Downloads, View::Downloads)
            | (View::Bookmarks, View::Bookmarks)
            | (View::Settings, View::Settings) => true,
            (View::Preview(lhs), View::Preview(rhs)) => lhs.id == rhs.id,
            (View::AuthorProfile(lhs), View::AuthorProfile(rhs)) => lhs == rhs,
            _ => false,
        }
    }

    pub fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::SwitchView(view) => {
                if Self::is_same_view(&self.current_view, &view) {
                    return Task::none();
                }

                self.previous_view = Some(Box::new(self.current_view.clone()));
                self.current_view = view.clone();

                match view {
                    View::Bookmarks => {
                        return Task::perform(async { () }, |_| Message::LoadBookmarks);
                    }
                    View::Preview(wp) => {
                        self.preview_loading_frame = 0;
                        let mut tasks: Vec<Task<Message>> = vec![Task::perform(
                            Self::fetch_wallpaper(self.provider.clone(), wp.id.clone()),
                            Message::PreviewWallpaperLoaded,
                        )];

                        if !self.full_images.contains_key(&wp.id) {
                            let local_path =
                                Self::local_wallpaper_path(&self.preferences.download_dir, &wp);
                            tasks.push(Task::perform(
                                Self::fetch_full_image(
                                    wp.id.clone(),
                                    wp.full_url.clone(),
                                    local_path,
                                ),
                                |(id, res)| Message::FullImageLoaded(id, res),
                            ));
                        }

                        return Task::batch(tasks);
                    }
                    View::AuthorProfile(username) => {
                        self.author_username = Some(username.clone());
                        self.author_results = None;
                        self.is_loading_author = true;
                        let filters = self.active_filters.clone();
                        return Task::perform(
                            Self::fetch_author_wallpapers(
                                self.provider.clone(),
                                username,
                                1,
                                filters,
                            ),
                            Message::AuthorWorksLoaded,
                        );
                    }
                    _ => {}
                }

                Task::none()
            }
            Message::GoBack => {
                if let Some(prev) = self.previous_view.take() {
                    self.current_view = *prev;
                } else {
                    self.current_view = View::Search;
                }
                Task::none()
            }
            Message::SearchQueryChanged(query) => {
                self.search_query = query;
                if Self::parse_primary_tag_query(&self.search_query).is_none() {
                    self.related_tags.clear();
                }
                Task::none()
            }
            Message::ToggleSearchSidebar => {
                self.search_sidebar_visible = !self.search_sidebar_visible;
                Task::none()
            }
            Message::SearchByTag(tag) => {
                let normalized = tag
                    .trim()
                    .trim_start_matches('#')
                    .trim()
                    .to_lowercase()
                    .replace(' ', "_");
                if normalized.is_empty() {
                    return Task::none();
                }

                self.current_view = View::Search;
                self.search_query = format!("#{normalized}");
                self.related_tags.clear();
                self.is_searching = true;
                self.is_appending_search_results = false;
                self.active_filters.page = 1;
                self.active_filters.seed = None;
                self.sync_input_filters_into_active();
                Self::sanitize_filters(&mut self.active_filters);

                let mut filters = self.active_filters.clone();
                filters.query = Self::normalize_search_query_for_api(&self.search_query);

                self.selected_wallpapers.clear();

                Task::perform(
                    Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                    Message::SearchCompleted,
                )
            }
            Message::SubmitSearch => {
                if self.is_searching {
                    return Task::none();
                }

                self.is_searching = true;
                self.is_appending_search_results = false;
                self.active_filters.page = 1;
                self.active_filters.seed = None;
                self.sync_input_filters_into_active();
                Self::sanitize_filters(&mut self.active_filters);
                let mut filters = self.active_filters.clone();
                filters.query = Self::normalize_search_query_for_api(&self.search_query);

                // Clear selection on new search
                self.selected_wallpapers.clear();

                Task::perform(
                    Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                    Message::SearchCompleted,
                )
            }
            Message::SearchScrolled(viewport) => {
                if self.is_searching {
                    return Task::none();
                }

                let Some(results) = &self.search_results else {
                    return Task::none();
                };

                if results.current_page >= results.last_page {
                    return Task::none();
                }

                let viewport_bounds = viewport.bounds();
                let content_bounds = viewport.content_bounds();
                if content_bounds.height <= viewport_bounds.height {
                    return Task::none();
                }

                let absolute = viewport.absolute_offset();
                let max_offset = (content_bounds.height - viewport_bounds.height).max(0.0);
                if max_offset <= 0.0 {
                    return Task::none();
                }

                let distance_to_bottom = max_offset - absolute.y;
                if distance_to_bottom > 280.0 {
                    return Task::none();
                }

                self.is_searching = true;
                self.is_appending_search_results = true;

                let mut filters = self.active_filters.clone();
                Self::sanitize_filters(&mut filters);
                filters.page = results.current_page + 1;
                filters.query = Self::normalize_search_query_for_api(&self.search_query);
                self.active_filters.page = filters.page;

                Task::perform(
                    Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                    Message::SearchCompleted,
                )
            }
            Message::SearchCompleted(result) => {
                self.is_searching = false;
                let append_mode = self.is_appending_search_results;
                self.is_appending_search_results = false;
                match result {
                    Ok(r) => {
                        let SearchResult {
                            wallpapers,
                            current_page,
                            last_page,
                            total,
                            seed,
                        } = r;

                        let tasks = self.build_thumbnail_tasks_for_wallpapers(&wallpapers);

                        self.active_filters.page = current_page;
                        self.active_filters.seed = seed.clone();

                        if append_mode {
                            if let Some(existing) = &mut self.search_results {
                                existing.wallpapers.extend(wallpapers);
                                existing.current_page = current_page;
                                existing.last_page = last_page;
                                existing.total = total;
                                existing.seed = seed.clone();
                            } else {
                                self.search_results = Some(SearchResult {
                                    wallpapers,
                                    current_page,
                                    last_page,
                                    total,
                                    seed: seed.clone(),
                                });
                            }
                        } else {
                            self.search_results = Some(SearchResult {
                                wallpapers,
                                current_page,
                                last_page,
                                total,
                                seed: seed.clone(),
                            });
                        }

                        self.related_tags = if let Some(primary_tag) =
                            Self::parse_primary_tag_query(&self.search_query)
                        {
                            if let Some(results) = &self.search_results {
                                Self::derive_related_tags(results, &primary_tag, 18)
                            } else {
                                Vec::new()
                            }
                        } else {
                            Vec::new()
                        };

                        self.error_message = None;
                        return Task::batch(tasks);
                    }
                    Err(e) => {
                        self.related_tags.clear();
                        self.error_message = Some(e);
                    }
                }
                Task::none()
            }
            Message::AuthorWorksLoaded(result) => {
                self.is_loading_author = false;

                match result {
                    Ok(results) => {
                        let tasks = self.build_thumbnail_tasks_for_wallpapers(&results.wallpapers);

                        self.author_results = Some(results);
                        self.error_message = None;
                        return Task::batch(tasks);
                    }
                    Err(e) => {
                        self.author_results = None;
                        self.error_message = Some(e);
                    }
                }

                Task::none()
            }
            Message::NextPage => {
                if self.is_searching {
                    return Task::none();
                }
                if let Some(results) = &self.search_results {
                    let current = results.current_page;
                    let last = results.last_page;
                    if current < last {
                        self.is_searching = true;
                        self.is_appending_search_results = false;
                        let mut filters = self.active_filters.clone();
                        Self::sanitize_filters(&mut filters);
                        filters.page = current + 1;
                        filters.query = Self::normalize_search_query_for_api(&self.search_query);
                        self.active_filters.page = filters.page;
                        return Task::perform(
                            Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                            Message::SearchCompleted,
                        );
                    }
                }
                Task::none()
            }
            Message::PreviousPage => {
                if self.is_searching {
                    return Task::none();
                }
                if let Some(results) = &self.search_results {
                    let current = results.current_page;
                    if current > 1 {
                        self.is_searching = true;
                        self.is_appending_search_results = false;
                        let mut filters = self.active_filters.clone();
                        Self::sanitize_filters(&mut filters);
                        filters.page = current - 1;
                        filters.query = Self::normalize_search_query_for_api(&self.search_query);
                        self.active_filters.page = filters.page;
                        return Task::perform(
                            Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                            Message::SearchCompleted,
                        );
                    }
                }
                Task::none()
            }
            Message::AuthorNextPage => {
                if self.is_loading_author {
                    return Task::none();
                }

                if let (Some(username), Some(results)) =
                    (&self.author_username, &self.author_results)
                {
                    if results.current_page < results.last_page {
                        self.is_loading_author = true;
                        let filters = self.active_filters.clone();
                        return Task::perform(
                            Self::fetch_author_wallpapers(
                                self.provider.clone(),
                                username.clone(),
                                results.current_page + 1,
                                filters,
                            ),
                            Message::AuthorWorksLoaded,
                        );
                    }
                }

                Task::none()
            }
            Message::AuthorPreviousPage => {
                if self.is_loading_author {
                    return Task::none();
                }

                if let (Some(username), Some(results)) =
                    (&self.author_username, &self.author_results)
                {
                    if results.current_page > 1 {
                        self.is_loading_author = true;
                        let filters = self.active_filters.clone();
                        return Task::perform(
                            Self::fetch_author_wallpapers(
                                self.provider.clone(),
                                username.clone(),
                                results.current_page - 1,
                                filters,
                            ),
                            Message::AuthorWorksLoaded,
                        );
                    }
                }

                Task::none()
            }
            Message::ThumbnailLoaded(id, source_url, result) => {
                match result {
                    Ok(handle) => {
                        let should_apply = match self.thumbnail_sources.get(&id) {
                            Some(expected) => expected == &source_url,
                            None => true,
                        };

                        if should_apply {
                            self.thumbnail_sources.insert(id.clone(), source_url);
                            self.thumbnails.insert(id, handle);
                        }
                    }
                    Err(_) => {
                        if let Some(expected) = self.thumbnail_sources.get(&id)
                            && expected == &source_url
                        {
                            self.thumbnail_sources.remove(&id);
                        }
                    }
                }
                Task::none()
            }
            Message::FullImageLoaded(id, result) => {
                if let Ok(handle) = result {
                    self.full_images.insert(id, handle);
                }
                Task::none()
            }
            Message::PreviewWallpaperLoaded(result) => {
                if let Ok(wallpaper) = result
                    && let View::Preview(current) = &self.current_view
                    && current.id == wallpaper.id
                {
                    self.current_view = View::Preview(wallpaper);
                }
                Task::none()
            }
            Message::TileClicked(id) => {
                if self.selected_wallpapers.contains(&id) {
                    self.selected_wallpapers.remove(&id);
                } else {
                    self.selected_wallpapers.insert(id);
                }

                Task::none()
            }
            Message::SelectAll => {
                if let Some(results) = &self.search_results {
                    for wp in &results.wallpapers {
                        self.selected_wallpapers.insert(wp.id.clone());
                    }
                }
                Task::none()
            }
            Message::DeselectAll => {
                self.selected_wallpapers.clear();
                Task::none()
            }
            Message::DownloadSelected => {
                if self.selected_wallpapers.is_empty() {
                    return Task::none();
                }

                if let Some(results) = &self.search_results {
                    let mut items = Vec::new();
                    for wp in &results.wallpapers {
                        if self.selected_wallpapers.contains(&wp.id) {
                            let filename =
                                format!("{}.{}", wp.id, wp.file_type.replace("image/", ""));
                            items.push((wp.id.clone(), wp.full_url.clone(), filename));
                        }
                    }

                    if !items.is_empty() {
                        let dl_manager = self.downloader.clone();
                        let dest = resolve_download_dir(&self.preferences.download_dir);

                        // Clear selection after triggering download
                        self.selected_wallpapers.clear();
                        self.current_view = View::Downloads;

                        return Task::perform(
                            async move {
                                let _ = dl_manager.enqueue_bulk(items, &dest).await;
                            },
                            |_| Message::Tick,
                        );
                    }
                }
                Task::none()
            }
            Message::BookmarkSelected => {
                if self.selected_wallpapers.is_empty() {
                    return Task::none();
                }

                if let Some(results) = &self.search_results {
                    let mut added = 0_u32;
                    let mut skipped = 0_u32;
                    let mut failed = 0_u32;

                    for wp in &results.wallpapers {
                        if !self.selected_wallpapers.contains(&wp.id) {
                            continue;
                        }

                        match self.db.is_bookmarked(&wp.id) {
                            Ok(true) => skipped += 1,
                            Ok(false) => {
                                let bookmark = Bookmark::new(wp, None);
                                if self.db.add_bookmark(&bookmark).is_ok() {
                                    added += 1;
                                } else {
                                    failed += 1;
                                }
                            }
                            Err(_) => failed += 1,
                        }
                    }

                    self.selected_wallpapers.clear();

                    if failed > 0 {
                        self.error_message = Some(format!(
                            "Bookmarked {added}, skipped {skipped}, failed {failed}."
                        ));
                    } else {
                        self.error_message = None;
                    }

                    return Task::perform(async { () }, |_| Message::LoadBookmarks);
                }

                Task::none()
            }
            Message::DownloadAuthorWorks => {
                if let Some(results) = &self.author_results {
                    if results.wallpapers.is_empty() {
                        return Task::none();
                    }

                    let items: Vec<(String, String, String)> = results
                        .wallpapers
                        .iter()
                        .map(|wp| {
                            let filename =
                                format!("{}.{}", wp.id, wp.file_type.replace("image/", ""));
                            (wp.id.clone(), wp.full_url.clone(), filename)
                        })
                        .collect();

                    let dl_manager = self.downloader.clone();
                    let dest = resolve_download_dir(&self.preferences.download_dir);
                    self.current_view = View::Downloads;

                    return Task::perform(
                        async move {
                            let _ = dl_manager.enqueue_bulk(items, &dest).await;
                        },
                        |_| Message::Tick,
                    );
                }

                Task::none()
            }
            Message::DownloadAllAuthorWorks => {
                if let Some(username) = &self.author_username {
                    let provider = self.provider.clone();
                    let downloader = self.downloader.clone();
                    let download_dir = self.preferences.download_dir.clone();
                    let filters = self.active_filters.clone();
                    self.current_view = View::Downloads;

                    return Task::perform(
                        Self::queue_all_author_works(
                            provider,
                            downloader,
                            username.clone(),
                            download_dir,
                            filters,
                        ),
                        Message::DownloadAllAuthorWorksCompleted,
                    );
                }

                Task::none()
            }
            Message::DownloadAllAuthorWorksCompleted(result) => {
                match result {
                    Ok(_) => {
                        self.error_message = None;
                    }
                    Err(e) => {
                        self.error_message = Some(format!("Failed to queue author downloads: {e}"));
                    }
                }

                Task::perform(async { () }, |_| Message::Tick)
            }
            Message::DownloadSingle(wp) => {
                let filename = format!("{}.{}", wp.id, wp.file_type.replace("image/", ""));
                let dl_manager = self.downloader.clone();
                let dest = resolve_download_dir(&self.preferences.download_dir);

                self.previous_view = Some(Box::new(self.current_view.clone()));
                self.current_view = View::Downloads;

                Task::perform(
                    async move {
                        let _ = dl_manager
                            .enqueue(wp.id.clone(), wp.full_url.clone(), filename, &dest)
                            .await;
                    },
                    |_| Message::Tick,
                )
            }
            Message::SetWallpaper(path) => {
                match self.setter.set_wallpaper(&path) {
                    Ok(_) => {
                        self.error_message = None; // clear any old errors
                    }
                    Err(e) => {
                        self.error_message = Some(format!("Failed to set wallpaper: {}", e));
                    }
                }
                Task::none()
            }
            Message::OpenAuthorProfile(username) => {
                let normalized = username.trim().to_string();
                if normalized.is_empty() {
                    self.error_message = Some("Author username is missing.".to_string());
                    return Task::none();
                }

                if Self::is_same_view(&self.current_view, &View::AuthorProfile(normalized.clone()))
                {
                    return Task::none();
                }

                self.previous_view = Some(Box::new(self.current_view.clone()));
                self.current_view = View::AuthorProfile(normalized.clone());
                self.author_username = Some(normalized.clone());
                self.author_results = None;
                self.is_loading_author = true;
                let filters = self.active_filters.clone();

                Task::perform(
                    Self::fetch_author_wallpapers(self.provider.clone(), normalized, 1, filters),
                    Message::AuthorWorksLoaded,
                )
            }
            Message::QuickSet(wp) => {
                let setter = self.setter.clone();
                let download_dir = self.preferences.download_dir.clone();
                Task::perform(
                    Self::quick_set_wallpaper(setter, download_dir, wp),
                    Message::QuickSetCompleted,
                )
            }
            Message::QuickSetCompleted(result) => {
                match result {
                    Ok(()) => {
                        self.error_message = None;
                    }
                    Err(e) => {
                        self.error_message = Some(e);
                    }
                }
                Task::none()
            }
            Message::GridColumnsChanged(cols) => {
                let cols = Self::normalize_grid_columns(cols);
                if cols == self.preferences.grid_columns {
                    return Task::none();
                }

                self.preferences.grid_columns = cols;
                let _ = self.db.save_preferences(&self.preferences);

                let mut tasks = vec![];
                let search_wallpapers = self
                    .search_results
                    .as_ref()
                    .map(|r| r.wallpapers.clone())
                    .unwrap_or_default();
                let author_wallpapers = self
                    .author_results
                    .as_ref()
                    .map(|r| r.wallpapers.clone())
                    .unwrap_or_default();

                tasks.extend(self.build_thumbnail_tasks_for_wallpapers(&search_wallpapers));
                tasks.extend(self.build_thumbnail_tasks_for_wallpapers(&author_wallpapers));

                if tasks.is_empty() {
                    Task::none()
                } else {
                    Task::batch(tasks)
                }
            }
            Message::LoadBookmarks => {
                let db = self.db.clone();
                Task::perform(
                    async move {
                        let bookmarks = db.get_bookmarks(None).map_err(|e| e.to_string())?;
                        let folders = db.get_folders().map_err(|e| e.to_string())?;
                        Ok((bookmarks, folders))
                    },
                    Message::BookmarksLoaded,
                )
            }
            Message::BookmarksLoaded(result) => {
                match result {
                    Ok((bookmarks, folders)) => {
                        self.bookmarks = bookmarks.clone();
                        self.bookmark_folders = folders;

                        let mut tasks = vec![];
                        for bm in &bookmarks {
                            if self.should_fetch_thumbnail(&bm.wallpaper_id, &bm.thumbnail_url) {
                                tasks.push(Task::perform(
                                    Self::fetch_thumbnail(
                                        bm.wallpaper_id.clone(),
                                        bm.thumbnail_url.clone(),
                                    ),
                                    |(id, url, res)| Message::ThumbnailLoaded(id, url, res),
                                ));
                            }
                        }
                        return Task::batch(tasks);
                    }
                    Err(e) => {
                        self.error_message = Some(format!("Failed to load bookmarks: {}", e));
                    }
                }
                Task::none()
            }
            Message::AddBookmark(wp) => {
                match self.db.is_bookmarked(&wp.id) {
                    Ok(true) => {
                        self.error_message =
                            Some("This wallpaper is already bookmarked.".to_string());
                    }
                    Ok(false) => {
                        let bookmark = Bookmark::new(&wp, None);
                        if let Err(e) = self.db.add_bookmark(&bookmark) {
                            self.error_message = Some(format!("Failed to add bookmark: {}", e));
                        } else {
                            self.error_message = None;
                            return Task::perform(async { () }, |_| Message::LoadBookmarks);
                        }
                    }
                    Err(e) => {
                        self.error_message = Some(format!("Failed to check bookmark: {}", e));
                    }
                }
                Task::none()
            }
            Message::OpenBookmark(wallpaper_id) => {
                let provider = self.provider.clone();
                Task::perform(
                    Self::fetch_wallpaper(provider, wallpaper_id),
                    Message::BookmarkWallpaperLoaded,
                )
            }
            Message::BookmarkWallpaperLoaded(result) => {
                match result {
                    Ok(wallpaper) => {
                        self.previous_view = Some(Box::new(self.current_view.clone()));
                        self.current_view = View::Preview(wallpaper.clone());
                        self.preview_loading_frame = 0;
                        self.error_message = None;

                        if !self.full_images.contains_key(&wallpaper.id) {
                            let local_path = Self::local_wallpaper_path(
                                &self.preferences.download_dir,
                                &wallpaper,
                            );
                            return Task::perform(
                                Self::fetch_full_image(
                                    wallpaper.id.clone(),
                                    wallpaper.full_url.clone(),
                                    local_path,
                                ),
                                |(id, res)| Message::FullImageLoaded(id, res),
                            );
                        }
                    }
                    Err(e) => {
                        self.error_message = Some(format!("Failed to open bookmark: {}", e));
                    }
                }
                Task::none()
            }
            Message::ToggleCategory(cat, checked) => {
                let categories = &mut self.active_filters.categories;
                if checked {
                    if !categories.contains(&cat) {
                        categories.push(cat);
                    }
                } else {
                    if categories.len() == 1 && categories.contains(&cat) {
                        self.error_message =
                            Some("At least one category must stay enabled.".to_string());
                        return Task::none();
                    }
                    categories.retain(|&c| c != cat);
                }
                Task::none()
            }
            Message::TogglePurity(pur, checked) => {
                let purities = &mut self.active_filters.purity;
                if checked {
                    if !purities.contains(&pur) {
                        purities.push(pur);
                    }
                } else {
                    if purities.len() == 1 && purities.contains(&pur) {
                        self.error_message =
                            Some("At least one purity level must stay enabled.".to_string());
                        return Task::none();
                    }
                    purities.retain(|&p| p != pur);
                }
                Task::none()
            }
            Message::SortingChanged(sorting) => {
                self.active_filters.sorting = sorting;
                if sorting == Sorting::Toplist {
                    if self.active_filters.toplist_range.is_none() {
                        self.active_filters.toplist_range = Some(ToplistRange::SixMonths);
                    }
                } else {
                    self.active_filters.toplist_range = None;
                }
                Task::none()
            }
            Message::SortOrderChanged(order) => {
                self.active_filters.order = order;
                Task::none()
            }
            Message::ToplistRangeChanged(range) => {
                self.active_filters.toplist_range = Some(range);
                Task::none()
            }
            Message::ResolutionModeChanged(mode) => {
                self.resolution_mode = mode;

                match mode {
                    ResolutionMode::AtLeast => {
                        self.active_filters.atleast =
                            Self::parse_single_resolution_filter(&self.atleast_resolution_input);
                        self.active_filters.resolutions.clear();
                    }
                    ResolutionMode::Exactly => {
                        self.active_filters.atleast = None;
                        self.active_filters.resolutions =
                            Self::parse_resolution_filters(&self.resolution_filter_input);
                    }
                }
                Task::none()
            }
            Message::ToggleResolutionFilter(resolution, checked) => {
                self.resolution_mode = ResolutionMode::Exactly;
                self.active_filters.atleast = None;
                if checked {
                    if self
                        .active_filters
                        .resolutions
                        .iter()
                        .all(|r| r.width != resolution.width || r.height != resolution.height)
                    {
                        self.active_filters.resolutions.push(resolution);
                    }
                } else {
                    self.active_filters
                        .resolutions
                        .retain(|r| r.width != resolution.width || r.height != resolution.height);
                }

                self.resolution_filter_input =
                    Self::format_resolution_filters(&self.active_filters.resolutions);
                Task::none()
            }
            Message::ToggleRatioFilter(ratio, checked) => {
                if checked {
                    if !self.active_filters.ratios.contains(&ratio) {
                        self.active_filters.ratios.push(ratio);
                    }
                } else {
                    self.active_filters.ratios.retain(|r| r != &ratio);
                }

                self.ratio_filter_input = Self::format_ratio_filters(&self.active_filters.ratios);
                Task::none()
            }
            Message::AtleastResolutionChanged(input) => {
                self.atleast_resolution_input = input.clone();
                if self.resolution_mode == ResolutionMode::AtLeast {
                    self.active_filters.atleast = Self::parse_single_resolution_filter(&input);
                    self.active_filters.resolutions.clear();
                }
                Task::none()
            }
            Message::ResolutionFilterChanged(input) => {
                self.resolution_filter_input = input.clone();
                if self.resolution_mode == ResolutionMode::Exactly {
                    self.active_filters.resolutions = Self::parse_resolution_filters(&input);
                }
                Task::none()
            }
            Message::RatioFilterChanged(input) => {
                self.ratio_filter_input = input.clone();
                self.active_filters.ratios = Self::parse_ratio_filters(&input);
                Task::none()
            }
            Message::ColorFilterChanged(input) => {
                self.color_filter_input = input;
                self.active_filters.colors = Self::parse_color_filters(&self.color_filter_input);
                Task::none()
            }
            Message::SaveFiltersAsDefault => {
                Self::sanitize_filters(&mut self.active_filters);
                self.sync_input_filters_into_active();
                self.preferences.default_filters = self.active_filters.clone();
                let _ = self.db.save_preferences(&self.preferences);
                Task::none()
            }
            Message::Tick => {
                if !self.should_poll_downloads() {
                    return Task::none();
                }
                let downloader = self.downloader.clone();
                Task::perform(
                    async move { downloader.get_tasks().await },
                    Message::DownloadsUpdated,
                )
            }
            Message::PreviewLoadingTick => {
                if self.is_preview_loading() {
                    self.preview_loading_frame = (self.preview_loading_frame + 1) % 4;
                } else {
                    self.preview_loading_frame = 0;
                }
                Task::none()
            }
            Message::DownloadsUpdated(mut tasks) => {
                tasks.sort_by(|a, b| b.created_at.cmp(&a.created_at));
                self.download_tasks = tasks;

                for task in self.download_tasks.clone() {
                    self.push_local_thumbnail_if_available(&task);
                }

                Task::none()
            }
            Message::ToggleTheme => {
                self.preferences.theme = match self.preferences.theme {
                    Theme::Light => Theme::Dark,
                    Theme::Dark => Theme::Light,
                };
                let _ = self.db.save_preferences(&self.preferences);
                Task::none()
            }
            Message::SettingsChanged(msg) => {
                match msg {
                    SettingsMessage::ApiKeyChanged(key) => {
                        let trimmed = key.trim().to_string();
                        self.preferences.api_key = if trimmed.is_empty() {
                            None
                        } else {
                            Some(trimmed)
                        };
                    }
                    SettingsMessage::DownloadDirChanged(dir) => {
                        self.preferences.download_dir = dir;
                    }
                    SettingsMessage::MaxParallelChanged(max) => {
                        if let Ok(val) = max.parse::<u32>() {
                            self.preferences.max_parallel_downloads = val.clamp(1, 10);
                        }
                    }
                    SettingsMessage::SchedulerEnabledChanged(enabled) => {
                        self.preferences.scheduler.enabled = enabled;
                    }
                    SettingsMessage::SchedulerIntervalChanged(interval) => {
                        if let Ok(val) = interval.parse::<u32>() {
                            self.preferences.scheduler.interval_minutes = val.max(1);
                        }
                    }
                    SettingsMessage::SchedulerShuffleChanged(shuffle) => {
                        self.preferences.scheduler.shuffle = shuffle;
                    }
                    SettingsMessage::Save => {
                        self.preferences.max_parallel_downloads =
                            self.preferences.max_parallel_downloads.clamp(1, 10);
                        self.preferences.scheduler.interval_minutes =
                            self.preferences.scheduler.interval_minutes.max(1);

                        let _ = self.db.save_preferences(&self.preferences);
                        self.provider =
                            Arc::new(WallhavenClient::new(self.preferences.api_key.clone()));

                        let scheduler = self.scheduler.clone();
                        return Task::perform(
                            async move {
                                let _ = scheduler.reload_config().await;
                            },
                            |_| Message::ClearError,
                        );
                    }
                }
                Task::none()
            }
            Message::ClearError => {
                self.error_message = None;
                Task::none()
            }
        }
    }

    pub fn view(&self) -> Element<'_, Message> {
        let page: Element<'_, Message> = match &self.current_view {
            View::Search => crate::views::search::view(self),
            View::Downloads => crate::views::downloads::view(self),
            View::Bookmarks => crate::views::bookmarks::view(self),
            View::Settings => crate::views::settings::view(self),
            View::Preview(wp) => crate::views::preview::view(self, wp),
            View::AuthorProfile(_) => crate::views::author::view(self),
        };

        let mut content = column![
            self.header_view(),
            container(page)
                .padding(14)
                .width(Length::Fill)
                .height(Length::Fill)
                .style(crate::theme::app_frame)
        ]
        .spacing(14)
        .padding(16);

        if let Some(ref err) = self.error_message {
            content = content.push(
                container(
                    row![
                        text(err).color([0.85, 0.2, 0.2]),
                        button("Dismiss")
                            .on_press(Message::ClearError)
                            .style(crate::theme::button_danger)
                    ]
                    .spacing(12),
                )
                .padding(12)
                .style(crate::theme::panel),
            );
        }

        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    }

    pub fn theme(&self) -> IcedTheme {
        active_theme(self.preferences.theme)
    }

    fn header_view(&self) -> Element<'_, Message> {
        let mut search = button("Search")
            .style(crate::theme::button_secondary)
            .on_press(Message::SwitchView(View::Search));
        if matches!(self.current_view, View::Search) {
            search = search.style(crate::theme::button_primary);
        }

        let mut downloads = button("Downloads")
            .style(crate::theme::button_secondary)
            .on_press(Message::SwitchView(View::Downloads));
        if matches!(self.current_view, View::Downloads) {
            downloads = downloads.style(crate::theme::button_primary);
        }

        let mut bookmarks = button("Bookmarks")
            .style(crate::theme::button_secondary)
            .on_press(Message::SwitchView(View::Bookmarks));
        if matches!(self.current_view, View::Bookmarks) {
            bookmarks = bookmarks.style(crate::theme::button_primary);
        }

        let mut settings = button("Settings")
            .style(crate::theme::button_secondary)
            .on_press(Message::SwitchView(View::Settings));
        if matches!(self.current_view, View::Settings) {
            settings = settings.style(crate::theme::button_primary);
        }

        let theme_label = match self.preferences.theme {
            Theme::Light => "Use Dark",
            Theme::Dark => "Use Light",
        };

        container(
            row![
                column![
                    text("Walder").size(25),
                    text("Minimal wallpaper workflow, fast and focused.")
                        .size(12)
                        .color([0.60, 0.66, 0.74]),
                ]
                .spacing(2),
                row![
                    search,
                    downloads,
                    bookmarks,
                    settings,
                    button(theme_label)
                        .style(crate::theme::button_secondary)
                        .on_press(Message::ToggleTheme),
                ]
                .spacing(8)
                .width(Length::Fill)
                .align_y(iced::Alignment::Center)
            ]
            .spacing(18)
            .align_y(iced::Alignment::Center),
        )
        .padding(14)
        .style(crate::theme::panel)
        .into()
    }

    pub fn subscription(&self) -> iced::Subscription<Message> {
        let mut subscriptions = Vec::new();

        if self.should_poll_downloads() {
            subscriptions.push(
                iced::time::every(std::time::Duration::from_millis(750)).map(|_| Message::Tick),
            );
        }

        if self.is_preview_loading() {
            subscriptions.push(
                iced::time::every(std::time::Duration::from_millis(120))
                    .map(|_| Message::PreviewLoadingTick),
            );
        }

        match subscriptions.len() {
            0 => iced::Subscription::none(),
            1 => subscriptions.remove(0),
            _ => iced::Subscription::batch(subscriptions),
        }
    }

    pub fn preferences(&self) -> &AppPreferences {
        &self.preferences
    }

    pub fn search_query(&self) -> &str {
        &self.search_query
    }

    pub fn is_search_sidebar_visible(&self) -> bool {
        self.search_sidebar_visible
    }

    pub fn resolution_filter_input(&self) -> &str {
        &self.resolution_filter_input
    }

    pub fn resolution_mode(&self) -> ResolutionMode {
        self.resolution_mode
    }

    pub fn atleast_resolution_input(&self) -> &str {
        &self.atleast_resolution_input
    }

    pub fn ratio_filter_input(&self) -> &str {
        &self.ratio_filter_input
    }

    pub fn color_filter_input(&self) -> &str {
        &self.color_filter_input
    }

    pub fn is_searching(&self) -> bool {
        self.is_searching
    }

    pub fn has_more_search_pages(&self) -> bool {
        self.search_results
            .as_ref()
            .map(|results| results.current_page < results.last_page)
            .unwrap_or(false)
    }

    pub fn search_results(&self) -> Option<&SearchResult> {
        self.search_results.as_ref()
    }

    pub fn related_tags(&self) -> &[(String, u32)] {
        &self.related_tags
    }

    pub fn active_filters(&self) -> &SearchFilters {
        &self.active_filters
    }

    pub fn author_username(&self) -> Option<&str> {
        self.author_username.as_deref()
    }

    pub fn author_results(&self) -> Option<&SearchResult> {
        self.author_results.as_ref()
    }

    pub fn is_loading_author(&self) -> bool {
        self.is_loading_author
    }

    pub fn get_thumbnail(&self, id: &str) -> Option<iced::widget::image::Handle> {
        self.thumbnails.get(id).cloned()
    }

    pub fn get_full_image(&self, id: &str) -> Option<iced::widget::image::Handle> {
        self.full_images.get(id).cloned()
    }

    pub fn preview_loading_indicator(&self) -> &'static str {
        match self.preview_loading_frame % 4 {
            0 => "-",
            1 => "\\",
            2 => "|",
            _ => "/",
        }
    }

    pub fn selected_wallpapers(&self) -> &HashSet<String> {
        &self.selected_wallpapers
    }

    pub fn download_tasks(&self) -> &[DownloadTask] {
        &self.download_tasks
    }

    pub fn bookmarks(&self) -> &[Bookmark] {
        &self.bookmarks
    }

    pub fn bookmark_folders(&self) -> &[BookmarkFolder] {
        &self.bookmark_folders
    }
}

pub fn resolve_download_dir(raw: &str) -> std::path::PathBuf {
    use std::path::PathBuf;

    if raw.starts_with('~') {
        let home = std::env::var("HOME").unwrap_or_default();
        let replaced = raw.replacen('~', &home, 1);
        PathBuf::from(replaced)
    } else {
        PathBuf::from(raw)
    }
}

#[cfg(test)]
mod tests {
    use super::WallsetterApp;

    #[test]
    fn normalize_search_query_supports_author_aliases() {
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("@tomthecom"),
            Some("@tomthecom".to_string())
        );
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("author:tomthecom"),
            Some("@tomthecom".to_string())
        );
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("Author:@tomthecom"),
            Some("@tomthecom".to_string())
        );
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("author: tomthecom"),
            Some("@tomthecom".to_string())
        );
    }

    #[test]
    fn normalize_search_query_supports_tag_aliases() {
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("#nature"),
            Some("nature".to_string())
        );
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("tag:nature"),
            Some("nature".to_string())
        );
        assert_eq!(
            WallsetterApp::normalize_search_query_for_api("Tag:#nature +#mountain -tag:city"),
            Some("nature +mountain -city".to_string())
        );
    }

    #[test]
    fn parse_primary_tag_query_supports_hash_and_tag_prefix() {
        assert_eq!(
            WallsetterApp::parse_primary_tag_query("#nature +#mountain"),
            Some("nature".to_string())
        );
        assert_eq!(
            WallsetterApp::parse_primary_tag_query("tag:nature +tag:mountain"),
            Some("nature".to_string())
        );
        assert_eq!(
            WallsetterApp::parse_primary_tag_query("-#nature #mountain"),
            Some("mountain".to_string())
        );
        assert_eq!(WallsetterApp::parse_primary_tag_query("-tag:nature"), None);
    }

    #[test]
    fn parse_ratio_filters_supports_keywords() {
        assert_eq!(
            WallsetterApp::parse_ratio_filters("landscape, portrait, 16x9"),
            vec![
                "landscape".to_string(),
                "portrait".to_string(),
                "16x9".to_string()
            ]
        );
    }
}

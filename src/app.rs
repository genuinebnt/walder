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
    search_results: Option<SearchResult>,
    is_searching: bool,
    thumbnails: HashMap<String, iced::widget::image::Handle>,
    full_images: HashMap<String, iced::widget::image::Handle>,
    selected_wallpapers: HashSet<String>,
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
}

#[derive(Debug, Clone)]
pub enum Message {
    // Navigation
    SwitchView(View),

    // Search
    SearchQueryChanged(String),
    SubmitSearch,
    SearchCompleted(std::result::Result<SearchResult, String>),
    ThumbnailLoaded(
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ),
    FullImageLoaded(
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ),

    // Preview & Set
    GoBack,
    DownloadSingle(Wallpaper),
    SetWallpaper(std::path::PathBuf),

    // Bookmarks
    LoadBookmarks,
    BookmarksLoaded(std::result::Result<(Vec<Bookmark>, Vec<BookmarkFolder>), String>),
    AddBookmark(Wallpaper),
    OpenBookmark(String),
    BookmarkWallpaperLoaded(std::result::Result<Wallpaper, String>),

    // Selection & Download
    ToggleSelection(String, bool),
    SelectAll,
    DeselectAll,
    DownloadSelected,
    QuickSet(Wallpaper),
    QuickSetCompleted(std::result::Result<(), String>),

    // Pagination
    NextPage,
    PreviousPage,

    // Grid layout
    GridColumnsChanged(u32),

    // Filters
    ToggleCategory(Category, bool),
    TogglePurity(Purity, bool),
    SortingChanged(Sorting),
    SaveFiltersAsDefault,

    // Downloads
    Tick,
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

impl WallsetterApp {
    pub fn new(
        db: Arc<Database>,
        provider: Arc<WallhavenClient>,
        downloader: Arc<DownloadManager>,
        setter: Arc<DesktopWallpaperSetter>,
        scheduler: Arc<Scheduler>,
    ) -> (Self, Task<Message>) {
        let mut preferences = db.get_preferences().unwrap_or_default();
        preferences.grid_columns = preferences.grid_columns.clamp(2, 8);
        preferences.max_parallel_downloads = preferences.max_parallel_downloads.clamp(1, 10);
        preferences.scheduler.interval_minutes = preferences.scheduler.interval_minutes.max(1);

        let mut active_filters = preferences.default_filters.clone();
        Self::sanitize_filters(&mut active_filters);

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
            search_results: None,
            is_searching: false,
            thumbnails: HashMap::new(),
            full_images: HashMap::new(),
            selected_wallpapers: HashSet::new(),
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

    async fn fetch_thumbnail(
        id: String,
        url: String,
    ) -> (
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

        (id, result)
    }

    async fn fetch_full_image(
        id: String,
        url: String,
    ) -> (
        String,
        std::result::Result<iced::widget::image::Handle, String>,
    ) {
        let result = async {
            let bytes = reqwest::get(&url).await?.bytes().await?;
            Ok(iced::widget::image::Handle::from_bytes(bytes.to_vec()))
        }
        .await
        .map_err(|e: reqwest::Error| e.to_string());

        (id, result)
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
        String::from("Wallsetter")
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

    fn is_same_view_kind(a: &View, b: &View) -> bool {
        matches!(
            (a, b),
            (View::Search, View::Search)
                | (View::Downloads, View::Downloads)
                | (View::Bookmarks, View::Bookmarks)
                | (View::Settings, View::Settings)
                | (View::Preview(_), View::Preview(_))
        )
    }

    pub fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::SwitchView(view) => {
                if Self::is_same_view_kind(&self.current_view, &view) {
                    return Task::none();
                }

                self.previous_view = Some(Box::new(self.current_view.clone()));
                self.current_view = view.clone();

                match view {
                    View::Bookmarks => {
                        return Task::perform(async { () }, |_| Message::LoadBookmarks);
                    }
                    View::Preview(wp) => {
                        if !self.full_images.contains_key(&wp.id) {
                            return Task::perform(
                                Self::fetch_full_image(wp.id.clone(), wp.full_url.clone()),
                                |(id, res)| Message::FullImageLoaded(id, res),
                            );
                        }
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
                Task::none()
            }
            Message::SubmitSearch => {
                if self.is_searching {
                    return Task::none();
                }

                self.is_searching = true;
                self.active_filters.page = 1;
                self.active_filters.seed = None;
                Self::sanitize_filters(&mut self.active_filters);
                let mut filters = self.active_filters.clone();
                if !self.search_query.trim().is_empty() {
                    filters = filters.with_query(self.search_query.clone());
                } else {
                    filters.query = None;
                }

                // Clear selection on new search
                self.selected_wallpapers.clear();

                Task::perform(
                    Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                    Message::SearchCompleted,
                )
            }
            Message::SearchCompleted(result) => {
                self.is_searching = false;
                match result {
                    Ok(r) => {
                        let mut tasks = vec![];
                        // Clear old thumbnails or keep a cache
                        // self.thumbnails.clear();

                        for wp in &r.wallpapers {
                            if !self.thumbnails.contains_key(&wp.id) {
                                tasks.push(Task::perform(
                                    Self::fetch_thumbnail(
                                        wp.id.clone(),
                                        wp.thumbnail_small.clone(),
                                    ),
                                    |(id, res)| Message::ThumbnailLoaded(id, res),
                                ));
                            }
                        }

                        self.active_filters.page = r.current_page;
                        self.active_filters.seed = r.seed.clone();
                        self.search_results = Some(r);
                        self.error_message = None;

                        return Task::batch(tasks);
                    }
                    Err(e) => {
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
                        let mut filters = self.active_filters.clone();
                        Self::sanitize_filters(&mut filters);
                        filters.page = current + 1;
                        if !self.search_query.trim().is_empty() {
                            filters = filters.with_query(self.search_query.clone());
                        } else {
                            filters.query = None;
                        }
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
                        let mut filters = self.active_filters.clone();
                        Self::sanitize_filters(&mut filters);
                        filters.page = current - 1;
                        if !self.search_query.trim().is_empty() {
                            filters = filters.with_query(self.search_query.clone());
                        } else {
                            filters.query = None;
                        }
                        self.active_filters.page = filters.page;
                        return Task::perform(
                            Self::fetch_initial_wallpapers(self.provider.clone(), filters),
                            Message::SearchCompleted,
                        );
                    }
                }
                Task::none()
            }
            Message::ThumbnailLoaded(id, result) => {
                if let Ok(handle) = result {
                    self.thumbnails.insert(id, handle);
                }
                Task::none()
            }
            Message::FullImageLoaded(id, result) => {
                if let Ok(handle) = result {
                    self.full_images.insert(id, handle);
                }
                Task::none()
            }
            Message::ToggleSelection(id, checked) => {
                if checked {
                    self.selected_wallpapers.insert(id);
                } else {
                    self.selected_wallpapers.remove(&id);
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
                let cols = cols.clamp(2, 8);
                self.preferences.grid_columns = cols;
                let _ = self.db.save_preferences(&self.preferences);
                Task::none()
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
                            if !self.thumbnails.contains_key(&bm.wallpaper_id) {
                                tasks.push(Task::perform(
                                    Self::fetch_thumbnail(
                                        bm.wallpaper_id.clone(),
                                        bm.thumbnail_url.clone(),
                                    ),
                                    |(id, res)| Message::ThumbnailLoaded(id, res),
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
                        self.error_message = None;

                        if !self.full_images.contains_key(&wallpaper.id) {
                            return Task::perform(
                                Self::fetch_full_image(
                                    wallpaper.id.clone(),
                                    wallpaper.full_url.clone(),
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
                Task::none()
            }
            Message::SaveFiltersAsDefault => {
                Self::sanitize_filters(&mut self.active_filters);
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
                    text("Wallsetter").size(25),
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
        if self.should_poll_downloads() {
            iced::time::every(std::time::Duration::from_millis(750)).map(|_| Message::Tick)
        } else {
            iced::Subscription::none()
        }
    }

    pub fn preferences(&self) -> &AppPreferences {
        &self.preferences
    }

    pub fn search_query(&self) -> &str {
        &self.search_query
    }

    pub fn is_searching(&self) -> bool {
        self.is_searching
    }

    pub fn search_results(&self) -> Option<&SearchResult> {
        self.search_results.as_ref()
    }

    pub fn active_filters(&self) -> &SearchFilters {
        &self.active_filters
    }

    pub fn get_thumbnail(&self, id: &str) -> Option<iced::widget::image::Handle> {
        self.thumbnails.get(id).cloned()
    }

    pub fn get_full_image(&self, id: &str) -> Option<iced::widget::image::Handle> {
        self.full_images.get(id).cloned()
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

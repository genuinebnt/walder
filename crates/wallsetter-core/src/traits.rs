use crate::models::*;
use std::future::Future;
use std::path::Path;

/// Trait for wallpaper providers (Wallhaven, Unsplash, etc.)
/// Each provider implements this trait to standardize access.
pub trait Provider: Send + Sync {
    /// Search for wallpapers with the given filters.
    fn search(
        &self,
        filters: &SearchFilters,
    ) -> impl Future<Output = crate::Result<SearchResult>> + Send;

    /// Get detailed information about a single wallpaper.
    fn get_wallpaper(&self, id: &str) -> impl Future<Output = crate::Result<Wallpaper>> + Send;

    /// Get tag information by tag ID.
    fn get_tag(&self, id: u64) -> impl Future<Output = crate::Result<Tag>> + Send;

    /// Get user collections (requires auth).
    fn get_collections(
        &self,
        username: Option<&str>,
    ) -> impl Future<Output = crate::Result<Vec<Collection>>> + Send;

    /// Get wallpapers in a specific collection.
    fn get_collection_wallpapers(
        &self,
        username: &str,
        collection_id: u64,
        page: u32,
    ) -> impl Future<Output = crate::Result<SearchResult>> + Send;

    /// The provider type identifier.
    fn provider_type(&self) -> WallpaperProvider;
}

/// Trait for setting the desktop wallpaper (cross-platform).
pub trait WallpaperSetter: Send + Sync {
    /// Set the desktop wallpaper from a file path.
    fn set_wallpaper(&self, path: &Path) -> crate::Result<()>;

    /// Get the current desktop wallpaper path.
    fn get_current_wallpaper(&self) -> crate::Result<Option<String>>;
}

/// Trait for the download manager.
pub trait Downloader: Send + Sync {
    /// Add a download task and return its ID.
    fn enqueue(
        &self,
        wallpaper_id: String,
        url: String,
        filename: String,
        destination: &Path,
    ) -> impl Future<Output = crate::Result<uuid::Uuid>> + Send;

    /// Cancel a download.
    fn cancel(&self, task_id: uuid::Uuid) -> impl Future<Output = crate::Result<()>> + Send;

    /// Get the current status of all downloads.
    fn get_tasks(&self) -> impl Future<Output = Vec<DownloadTask>> + Send;
}

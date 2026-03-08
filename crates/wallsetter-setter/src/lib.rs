use std::path::Path;
use tracing::info;
use wallsetter_core::*;

/// Cross-platform wallpaper setter.
pub struct DesktopWallpaperSetter;

impl DesktopWallpaperSetter {
    pub fn new() -> Self {
        Self
    }
}

impl Default for DesktopWallpaperSetter {
    fn default() -> Self {
        Self::new()
    }
}

impl WallpaperSetter for DesktopWallpaperSetter {
    fn set_wallpaper(&self, path: &Path) -> wallsetter_core::Result<()> {
        let path_str = path
            .to_str()
            .ok_or_else(|| WallsetterError::Setter("Invalid path encoding".to_string()))?;

        info!("Setting wallpaper to: {path_str}");

        wallpaper::set_from_path(path_str).map_err(|e| WallsetterError::Setter(e.to_string()))?;

        Ok(())
    }

    fn get_current_wallpaper(&self) -> wallsetter_core::Result<Option<String>> {
        match wallpaper::get() {
            Ok(path) => Ok(Some(path)),
            Err(e) => {
                tracing::warn!("Could not get current wallpaper: {e}");
                Ok(None)
            }
        }
    }
}

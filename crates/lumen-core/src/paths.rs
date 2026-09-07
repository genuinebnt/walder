//! Where Lumen keeps things.
//!
//! The app and the CLI are two front ends over one library and one database.
//! They agree on these paths or they do not see each other's work — an earlier
//! CLI resolved its own directory and quietly operated on an empty database of
//! its own.

use std::path::PathBuf;

/// Bundle identifier, and the name of the directories derived from it.
const QUALIFIER: &str = "cc";
const ORGANISATION: &str = "lumen";
const APPLICATION: &str = "Lumen";

/// `~/Library/Application Support/cc.lumen.Lumen` on macOS.
pub fn data_dir() -> PathBuf {
    directories::ProjectDirs::from(QUALIFIER, ORGANISATION, APPLICATION)
        .map(|d| d.data_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// `~/Library/Caches/cc.lumen.Lumen`. Images staged for setting live here.
pub fn cache_dir() -> PathBuf {
    directories::ProjectDirs::from(QUALIFIER, ORGANISATION, APPLICATION)
        .map(|d| d.cache_dir().to_path_buf())
        .unwrap_or_else(|| data_dir().join("cache"))
}

/// The one SQLite file both front ends open.
pub fn db_path() -> PathBuf {
    data_dir().join("lumen.db")
}

/// Where downloads go when nothing else is configured.
pub fn default_download_dir() -> PathBuf {
    directories::UserDirs::new()
        .and_then(|d| d.picture_dir().map(|p| p.join(APPLICATION)))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Turns a configured download directory into an absolute path.
///
/// Empty means "the default", and a leading `~/` is expanded — preferences are
/// written by a human as often as by the app.
pub fn resolve_dir(raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return default_download_dir();
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        if let Some(home) = directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf()) {
            return home.join(rest);
        }
    }
    PathBuf::from(trimmed)
}

/// A `file://` URL for a path, which is what the UI layers want.
pub fn file_url(path: &std::path::Path) -> String {
    url::Url::from_file_path(path)
        .map(|u| u.to_string())
        .unwrap_or_else(|_| path.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_resolves_to_the_default() {
        assert_eq!(resolve_dir("   "), default_download_dir());
    }

    #[test]
    fn tilde_expands() {
        let home = directories::BaseDirs::new().unwrap().home_dir().to_path_buf();
        assert_eq!(resolve_dir("~/Pictures/Elsewhere"), home.join("Pictures/Elsewhere"));
    }

    #[test]
    fn an_absolute_path_is_left_alone() {
        assert_eq!(resolve_dir("/tmp/walls"), PathBuf::from("/tmp/walls"));
    }

    #[test]
    fn the_database_sits_under_the_data_directory() {
        assert!(db_path().starts_with(data_dir()));
        assert_eq!(db_path().file_name().unwrap(), "lumen.db");
    }
}

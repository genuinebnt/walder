//! Finding images on disk.
//!
//! Shared because the app imports folders and the CLI does too, and an index
//! built by one has to look identical to the other.

use std::path::Path;

/// What counts as a wallpaper. Anything macOS can decode and set.
pub const IMAGE_EXTENSIONS: [&str; 7] = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"];

/// One image found under an imported root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoundImage {
    /// Absolute path.
    pub path: String,
    pub filename: String,
    pub bytes: u64,
    /// Pixel size, read from the header. Zero when it could not be read.
    ///
    /// Stored so the app never has to measure again: reading the headers of a
    /// four-thousand-file library takes seven seconds, and doing it at every
    /// launch is seven seconds of the grid laying out at the wrong shapes.
    pub width: u32,
    pub height: u32,
    /// Directory relative to the imported root, empty at the top level. This
    /// is what lets a folder be browsed as a tree rather than one flat list.
    pub subpath: String,
}

/// How deep to walk. A guard against a symlink loop, and against indexing a
/// whole home directory because someone imported `~`.
const MAX_DEPTH: u32 = 6;

/// Walks a folder for images, recursing into subfolders.
///
/// Hidden entries are skipped, which also excludes Lumen's own `.part` files
/// and the `.<name>.lumen.json` sidecars written beside downloads.
pub fn scan_images(root: &Path) -> Vec<FoundImage> {
    fn walk(dir: &Path, root: &Path, depth: u32, out: &mut Vec<FoundImage>) {
        if depth > MAX_DEPTH {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            if path.is_dir() {
                walk(&path, root, depth + 1, out);
                continue;
            }
            let extension = path
                .extension()
                .map(|e| e.to_string_lossy().to_ascii_lowercase())
                .unwrap_or_default();
            if !IMAGE_EXTENSIONS.contains(&extension.as_str()) {
                continue;
            }
            let subpath = path
                .parent()
                .and_then(|parent| parent.strip_prefix(root).ok())
                .map(|rel| rel.to_string_lossy().into_owned())
                .unwrap_or_default();
            let (width, height) = image::image_dimensions(&path).unwrap_or((0, 0));
            out.push(FoundImage {
                path: path.to_string_lossy().into_owned(),
                filename: name,
                bytes: entry.metadata().map(|m| m.len()).unwrap_or(0),
                width,
                height,
                subpath,
            });
        }
    }

    let mut found = Vec::new();
    walk(root, root, 0, &mut found);
    found.sort_by(|a, b| (a.subpath.as_str(), a.filename.as_str())
        .cmp(&(b.subpath.as_str(), b.filename.as_str())));
    found
}

/// The tuple shape the database's sync call takes.
pub fn as_rows(found: &[FoundImage]) -> Vec<(String, String, u64, String, u32, u32)> {
    found
        .iter()
        .map(|f| {
            (f.path.clone(), f.filename.clone(), f.bytes, f.subpath.clone(), f.width, f.height)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("lumen-scan-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn finds_images_and_records_where_they_sit() {
        let root = temp_root("nested");
        std::fs::create_dir_all(root.join("anime")).unwrap();
        std::fs::write(root.join("top.jpg"), b"x").unwrap();
        std::fs::write(root.join("anime/inner.png"), b"yy").unwrap();

        let found = scan_images(&root);
        assert_eq!(found.len(), 2);
        // Sorted by subpath, so the top level comes first.
        assert_eq!(found[0].filename, "top.jpg");
        assert_eq!(found[0].subpath, "");
        assert_eq!(found[0].bytes, 1);
        // Not a real image, so the header cannot be read; zero says so rather
        // than guessing a shape.
        assert_eq!((found[0].width, found[0].height), (0, 0));
        assert_eq!(found[1].filename, "inner.png");
        assert_eq!(found[1].subpath, "anime");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn skips_hidden_files_and_other_types() {
        let root = temp_root("skips");
        std::fs::write(root.join("keep.jpeg"), b"x").unwrap();
        std::fs::write(root.join(".hidden.jpg"), b"x").unwrap();
        std::fs::write(root.join("notes.txt"), b"x").unwrap();
        std::fs::write(root.join("half.jpg.part"), b"x").unwrap();

        let found = scan_images(&root);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].filename, "keep.jpeg");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unreadable_root_yields_nothing_rather_than_failing() {
        assert!(scan_images(std::path::Path::new("/nonexistent/lumen")).is_empty());
    }
}

//! Picking one at random, from wherever you keep them.
//!
//! This is the rotation the app runs on a schedule, available as one command
//! so `cron` or a Shortcut can drive it: the sources are the same ones the
//! app's rotation offers — the download folder, a collection, an imported
//! folder, your favourites, or a live search.

use std::path::PathBuf;
use std::str::FromStr;

use rand::seq::SliceRandom;

use crate::app::App;
use crate::commands::{browse, download, set};
use crate::filters::SearchArgs;
use crate::output;

/// Where a random pick comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// Everything in the download directory, subfolders included.
    Downloads,
    /// Wallpapers you have favourited, that are on disk.
    Favorites,
    /// A named collection.
    Collection(String),
    /// A named imported folder.
    Folder(String),
    /// Any folder on disk.
    Path(PathBuf),
    /// A live Wallhaven search, which downloads the pick.
    Search,
}

impl FromStr for Source {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let value = value.trim();
        if let Some(name) = value.strip_prefix("collection:") {
            return Ok(Self::Collection(name.trim().to_string()));
        }
        if let Some(name) = value.strip_prefix("folder:") {
            return Ok(Self::Folder(name.trim().to_string()));
        }
        if let Some(path) = value.strip_prefix("path:") {
            return Ok(Self::Path(lumen_core::paths::resolve_dir(path)));
        }
        match value.to_lowercase().as_str() {
            "downloads" | "" => Ok(Self::Downloads),
            "favorites" | "favourites" => Ok(Self::Favorites),
            "search" | "online" => Ok(Self::Search),
            other => anyhow::bail!(
                "unknown source \"{other}\" — try downloads, favorites, search, \
                 collection:NAME, folder:NAME or path:DIR"
            ),
        }
    }
}

pub async fn run(
    app: &App,
    source: &Source,
    args: &SearchArgs,
    pages: u32,
    set_it: bool,
    dir: Option<&str>,
) -> anyhow::Result<()> {
    // A live search has no local file until one is downloaded, so it takes a
    // different path from the four that read from disk.
    if *source == Source::Search {
        return from_search(app, args, pages, set_it, dir).await;
    }

    let candidates = local_candidates(app, source)?;
    if candidates.is_empty() {
        // A collection full of wallpapers none of which have been downloaded
        // is a different problem from an empty collection, and the fix is
        // different too.
        let filed = match source {
            Source::Favorites => app.db.get_bookmarked_wallpapers(None)?.len(),
            Source::Collection(name) => {
                app.db.get_collection_wallpapers(app.collection_named(name)?.id)?.len()
            }
            _ => 0,
        };
        if filed > 0 {
            anyhow::bail!(
                "{} holds {filed} wallpapers but none are downloaded — \
                 fetch them with: lumen-cli download <ID>...",
                describe(source)
            );
        }
        anyhow::bail!("nothing to pick from in {}", describe(source));
    }
    let pick = candidates
        .choose(&mut rand::thread_rng())
        .cloned()
        .expect("candidates is not empty");

    if set_it {
        set::apply(app, &pick, None)?;
    }
    if app.json {
        return output::json(&serde_json::json!({
            "picked": pick.to_string_lossy(),
            "from": describe(source),
            "candidates": candidates.len(),
            "set": set_it,
        }));
    }
    println!("{}", pick.display());
    if set_it {
        output::note(format!("Set from {} ({} to choose from).", describe(source), candidates.len()));
    }
    Ok(())
}

/// Every file a local source offers.
pub fn local_candidates(app: &App, source: &Source) -> anyhow::Result<Vec<PathBuf>> {
    let paths = match source {
        Source::Downloads => scan(&app.download_dir),
        Source::Path(dir) => scan(dir),
        Source::Folder(name) => {
            let (id, _, _, _) = app.folder_named(name)?;
            app.db
                .imported_wallpapers(Some(id), false)?
                .into_iter()
                .map(|(_, _, path, ..)| PathBuf::from(path))
                .collect()
        }
        Source::Collection(name) => {
            let folder = app.collection_named(name)?;
            local_files_for(app, &app.db.get_collection_wallpapers(folder.id)?)?
        }
        Source::Favorites => {
            local_files_for(app, &app.db.get_bookmarked_wallpapers(None)?)?
        }
        Source::Search => Vec::new(),
    };
    // A database row for a file that has since been deleted is not a
    // candidate; picking one would set nothing and report success.
    Ok(paths.into_iter().filter(|p| p.is_file()).collect())
}

/// The downloaded copies of a list of wallpapers, skipping any not on disk.
fn local_files_for(
    app: &App,
    wallpapers: &[lumen_core::Wallpaper],
) -> anyhow::Result<Vec<PathBuf>> {
    let records = app.db.get_download_records(2000)?;
    let mut found = Vec::new();
    for wallpaper in wallpapers {
        let filename = App::filename_for(wallpaper);
        let downloaded = app.download_dir.join(&filename);
        if downloaded.is_file() {
            found.push(downloaded);
            continue;
        }
        if let Some(record) = records.iter().find(|r| r.wallpaper_id == wallpaper.id) {
            found.push(PathBuf::from(&record.local_path));
        }
    }
    Ok(found)
}

fn scan(dir: &std::path::Path) -> Vec<PathBuf> {
    lumen_core::scan::scan_images(dir)
        .into_iter()
        .map(|f| PathBuf::from(f.path))
        .collect()
}

async fn from_search(
    app: &App,
    args: &SearchArgs,
    pages: u32,
    set_it: bool,
    dir: Option<&str>,
) -> anyhow::Result<()> {
    let filters = args.to_filters()?;
    // The page cap is what makes "one at random out of the top N" mean
    // something: without it a random pick is drawn from one page of results.
    let (wallpapers, _) = browse::collect(app, &filters, pages, None).await?;
    if wallpapers.is_empty() {
        anyhow::bail!("nothing matched, so there is nothing to pick");
    }
    let pick = wallpapers
        .choose(&mut rand::thread_rng())
        .cloned()
        .expect("wallpapers is not empty");

    let dir = dir
        .map(lumen_core::paths::resolve_dir)
        .unwrap_or_else(|| app.download_dir.clone());
    let downloaded = download::fetch(app, std::slice::from_ref(&pick), &dir, true).await?;
    let Some(first) = downloaded.first() else {
        anyhow::bail!("the download did not finish");
    };

    if set_it {
        set::apply(app, &first.path, Some(&first.wallpaper))?;
    }
    if app.json {
        return output::json(&serde_json::json!({
            "picked": first.path.to_string_lossy(),
            "wallpaperId": first.wallpaper.id,
            "from": format!("search ({} candidates)", wallpapers.len()),
            "set": set_it,
        }));
    }
    println!("{}", first.path.display());
    if set_it {
        output::note(format!("Set from {} candidates.", wallpapers.len()));
    }
    Ok(())
}

fn describe(source: &Source) -> String {
    match source {
        Source::Downloads => "the download folder".into(),
        Source::Favorites => "favourites".into(),
        Source::Collection(name) => format!("collection \"{name}\""),
        Source::Folder(name) => format!("folder \"{name}\""),
        Source::Path(dir) => dir.display().to_string(),
        Source::Search => "a search".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sources_parse() {
        assert_eq!("downloads".parse::<Source>().unwrap(), Source::Downloads);
        assert_eq!("favourites".parse::<Source>().unwrap(), Source::Favorites);
        assert_eq!(
            "collection: Dark ".parse::<Source>().unwrap(),
            Source::Collection("Dark".into())
        );
        assert_eq!(
            "folder:Anime".parse::<Source>().unwrap(),
            Source::Folder("Anime".into())
        );
        assert_eq!("search".parse::<Source>().unwrap(), Source::Search);
    }

    #[test]
    fn a_path_source_expands_a_tilde() {
        let home = directories::BaseDirs::new().unwrap().home_dir().to_path_buf();
        assert_eq!(
            "path:~/Pictures/Walls".parse::<Source>().unwrap(),
            Source::Path(home.join("Pictures/Walls"))
        );
    }

    #[test]
    fn an_unknown_source_names_the_alternatives() {
        let error = "everything".parse::<Source>().unwrap_err().to_string();
        assert!(error.contains("collection:NAME"), "{error}");
    }
}

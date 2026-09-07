//! Lumen from the terminal.
//!
//! The same library and the same database the app uses, driven by flags rather
//! than by clicking. Everything either front end writes — a favourite, an
//! import, a download, what is on the desktop right now — the other one sees.
//!
//! What is missing here is only what needs a window: the crop editor, the
//! menu-bar legibility check, the accent match and the Vision-based duplicate
//! finder all depend on frameworks that need a running app, so they stay in
//! the app.

mod app;
mod commands;
mod filters;
mod output;

use clap::{Parser, Subcommand};

use app::App;
use commands::random::Source;
use filters::SearchArgs;

#[derive(Parser)]
#[command(
    name = "lumen-cli",
    author,
    version,
    about = "Browse, download and set wallpapers from Wallhaven",
    long_about = None,
    propagate_version = true
)]
struct Cli {
    /// Print JSON instead of a table, for scripts.
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Search Wallhaven.
    Search {
        /// Search terms, the same as --query. Wallhaven operators work here:
        /// `#tag`, `@user`, `like:ID`, `-word`, `type:png`.
        terms: Option<String>,
        #[command(flatten)]
        filters: SearchArgs,
        /// How many pages to fetch. The seed is carried between them, so a
        /// random sort does not repeat.
        #[arg(long, default_value_t = 1)]
        pages: u32,
        /// Stop after this many results.
        #[arg(long)]
        limit: Option<usize>,
    },

    /// Everything Wallhaven knows about one wallpaper.
    Show {
        /// Wallpaper id, e.g. 6d3vjl.
        id: String,
    },

    /// Look up a tag by its numeric id.
    Tag { id: u64 },

    /// A user's public collections, and what is in them.
    Uploader {
        /// Wallhaven username, with or without the @.
        username: String,
        /// List this collection rather than the index.
        #[arg(long)]
        collection: Option<u64>,
        #[arg(long, default_value_t = 1)]
        page: u32,
    },

    /// Download wallpapers by id, or a whole search.
    Download {
        /// Wallpaper ids.
        ids: Vec<String>,
        /// Download the results of a search instead of ids.
        #[arg(long)]
        search: bool,
        #[command(flatten)]
        filters: SearchArgs,
        /// Pages of results to consider when downloading a search.
        #[arg(long, default_value_t = 1)]
        pages: u32,
        /// Stop after this many.
        #[arg(long)]
        limit: Option<usize>,
        /// Where to put them. Defaults to the configured download folder.
        #[arg(long)]
        dir: Option<String>,
        /// Skip the Spotlight metadata and the sidecar record.
        #[arg(long)]
        no_metadata: bool,
        /// Set the first one afterwards.
        #[arg(long)]
        set: bool,
    },

    /// What has been downloaded before.
    Downloads {
        #[arg(long, default_value_t = 50)]
        limit: u32,
    },

    /// Put a wallpaper on the desktop, by id or by path.
    Set {
        /// A wallpaper id, or a path to an image.
        target: String,
    },

    /// What the desktop is showing now.
    Current,

    /// Pick one at random and, with --set, put it on the desktop.
    Random {
        /// downloads, favorites, search, collection:NAME, folder:NAME, path:DIR.
        #[arg(long, default_value = "downloads")]
        source: Source,
        #[command(flatten)]
        filters: SearchArgs,
        /// Pages to draw from when the source is a search — the cap that makes
        /// "one at random out of the top N" mean something.
        #[arg(long, default_value_t = 1)]
        pages: u32,
        /// Set it, rather than only naming it.
        #[arg(long)]
        set: bool,
        /// Where a search's pick is downloaded to.
        #[arg(long)]
        dir: Option<String>,
    },

    /// Wallpapers you have favourited.
    Favorites {
        #[command(subcommand)]
        action: FavoriteCommand,
    },

    /// Named collections.
    Collections {
        #[command(subcommand)]
        action: CollectionCommand,
    },

    /// Folders imported from disk.
    Library {
        #[command(subcommand)]
        action: LibraryCommand,
    },

    /// What has been on the desktop.
    History {
        #[arg(long, default_value_t = 20)]
        limit: u32,
    },

    /// Go back to the previous wallpaper.
    Undo,

    /// Standing searches that report what is new.
    Radar {
        #[command(subcommand)]
        action: RadarCommand,
    },

    /// Read or change preferences, shared with the app.
    Config {
        #[command(subcommand)]
        action: ConfigCommand,
    },

    /// A summary of what Lumen is holding.
    Status,
}

#[derive(Subcommand)]
enum FavoriteCommand {
    /// List them.
    List,
    /// Favourite one or more wallpapers.
    Add { ids: Vec<String> },
    /// Un-favourite them.
    Remove { ids: Vec<String> },
}

#[derive(Subcommand)]
enum CollectionCommand {
    /// List collections and their sizes.
    List,
    /// Make a new one.
    Create { name: String },
    /// Delete one. The wallpapers stay.
    Delete { name: String },
    /// What is in one.
    Show { name: String },
    /// File wallpapers into it.
    Add { name: String, ids: Vec<String> },
    /// Take wallpapers out of it.
    Remove { name: String, ids: Vec<String> },
}

#[derive(Subcommand)]
enum LibraryCommand {
    /// Index a folder of images.
    Import { path: String },
    /// The folders that have been imported.
    Folders,
    /// Re-walk every folder, or one of them.
    Rescan { name: Option<String> },
    /// Drop a folder from the index. The images stay on disk.
    Forget { name: String },
    /// What is indexed, in one folder or all of them.
    List {
        name: Option<String>,
        /// Only the ones marked as favourites.
        #[arg(long)]
        favorites: bool,
    },
    /// Mark a local image as a favourite.
    Favorite { path: String },
    /// Unmark it.
    Unfavorite { path: String },
}

#[derive(Subcommand)]
enum RadarCommand {
    /// The standing searches.
    List,
    /// Watch a query.
    Add {
        query: String,
        /// A name for it. Defaults to the query.
        #[arg(long)]
        label: Option<String>,
        /// Ignore matches with fewer favourites than this.
        #[arg(long, default_value_t = 0)]
        min_favorites: u32,
    },
    /// Stop watching one.
    Remove { id: String },
    /// Run them all and report what is new.
    Check,
}

#[derive(Subcommand)]
enum ConfigCommand {
    /// What is configured.
    Show,
    /// Set the Wallhaven API key. Needed for anything but SFW.
    SetApiKey { key: String },
    /// Where downloads go.
    SetDownloadDir { path: String },
    /// How many downloads run at once (1–12).
    SetConcurrency { value: u32 },
}

#[tokio::main]
async fn main() {
    // Errors are reported as one line on stderr, not as a panic backtrace.
    if let Err(error) = run().await {
        eprintln!("lumen-cli: {error}");
        std::process::exit(1);
    }
}

async fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let app = App::open(cli.json)?;

    match cli.command {
        Command::Search { terms, mut filters, pages, limit } => {
            // The positional is the same field as --query; whichever was given
            // wins, and --query wins if somehow both were.
            filters.query = filters.query.or(terms);
            commands::browse::search(&app, &filters, pages, limit).await?
        }
        Command::Show { id } => commands::browse::show(&app, &id).await?,
        Command::Tag { id } => commands::browse::tag(&app, id).await?,
        Command::Uploader { username, collection, page } => {
            commands::browse::uploader(&app, &username, collection, page).await?
        }

        Command::Download {
            ids, search, filters, pages, limit, dir, no_metadata, set,
        } => {
            let metadata = !no_metadata;
            let finished = if search {
                commands::download::by_search(&app, &filters, pages, limit, dir.as_deref(), metadata)
                    .await?
            } else {
                if ids.is_empty() {
                    anyhow::bail!("give some ids, or --search with filters");
                }
                commands::download::by_ids(&app, &ids, dir.as_deref(), metadata).await?
            };
            if set {
                if let Some(first) = finished.first() {
                    commands::set::apply(&app, &first.path, Some(&first.wallpaper))?;
                    output::note(format!("Set {}.", first.path.display()));
                }
            }
            if app.json {
                let listed: Vec<_> = finished
                    .iter()
                    .map(|d| {
                        serde_json::json!({
                            "id": d.wallpaper.id, "path": d.path.to_string_lossy()
                        })
                    })
                    .collect();
                output::json(&listed)?;
            } else {
                for done in &finished {
                    println!("{}", done.path.display());
                }
            }
        }
        Command::Downloads { limit } => commands::download::history(&app, limit)?,

        Command::Set { target } => commands::set::run(&app, &target).await?,
        Command::Current => commands::set::current(&app)?,
        Command::Random { source, filters, pages, set, dir } => {
            commands::random::run(&app, &source, &filters, pages, set, dir.as_deref()).await?
        }

        Command::Favorites { action } => match action {
            FavoriteCommand::List => commands::marks::list_favorites(&app)?,
            FavoriteCommand::Add { ids } => commands::marks::add_favorites(&app, &ids).await?,
            FavoriteCommand::Remove { ids } => commands::marks::remove_favorites(&app, &ids)?,
        },

        Command::Collections { action } => match action {
            CollectionCommand::List => commands::marks::list_collections(&app)?,
            CollectionCommand::Create { name } => commands::marks::create_collection(&app, &name)?,
            CollectionCommand::Delete { name } => commands::marks::delete_collection(&app, &name)?,
            CollectionCommand::Show { name } => commands::marks::show_collection(&app, &name)?,
            CollectionCommand::Add { name, ids } => {
                commands::marks::add_to_collection(&app, &name, &ids).await?
            }
            CollectionCommand::Remove { name, ids } => {
                commands::marks::remove_from_collection(&app, &name, &ids)?
            }
        },

        Command::Library { action } => match action {
            LibraryCommand::Import { path } => commands::library::import(&app, &path)?,
            LibraryCommand::Folders => commands::library::folders(&app)?,
            LibraryCommand::Rescan { name } => commands::library::rescan(&app, name.as_deref())?,
            LibraryCommand::Forget { name } => commands::library::forget(&app, &name)?,
            LibraryCommand::List { name, favorites } => {
                commands::library::wallpapers(&app, name.as_deref(), favorites)?
            }
            LibraryCommand::Favorite { path } => commands::library::favorite(&app, &path, true)?,
            LibraryCommand::Unfavorite { path } => commands::library::favorite(&app, &path, false)?,
        },

        Command::History { limit } => commands::history::list(&app, limit)?,
        Command::Undo => commands::history::undo(&app)?,

        Command::Radar { action } => match action {
            RadarCommand::List => commands::radar::list(&app)?,
            RadarCommand::Add { query, label, min_favorites } => {
                commands::radar::add(&app, &query, label.as_deref(), min_favorites)?
            }
            RadarCommand::Remove { id } => commands::radar::remove(&app, &id)?,
            RadarCommand::Check => commands::radar::check(&app).await?,
        },

        Command::Config { action } => match action {
            ConfigCommand::Show => commands::config::show(&app)?,
            ConfigCommand::SetApiKey { key } => commands::config::set_api_key(&app, &key)?,
            ConfigCommand::SetDownloadDir { path } => {
                commands::config::set_download_dir(&app, &path)?
            }
            ConfigCommand::SetConcurrency { value } => {
                commands::config::set_concurrency(&app, value)?
            }
        },

        Command::Status => commands::config::status(&app)?,
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    /// clap validates the whole command tree here rather than panicking on the
    /// first run of whichever subcommand is malformed. Two variadic
    /// positionals in one subcommand — `download <IDS>...` next to a flattened
    /// query — got as far as a released binary before this existed.
    #[test]
    fn the_command_tree_is_well_formed() {
        Cli::command().debug_assert();
    }

    #[test]
    fn search_takes_its_query_positionally_or_as_a_flag() {
        let positional = Cli::try_parse_from(["lumen-cli", "search", "#landscape"]).unwrap();
        let flag = Cli::try_parse_from(["lumen-cli", "search", "-q", "#landscape"]).unwrap();
        for parsed in [positional, flag] {
            match parsed.command {
                Command::Search { terms, filters, .. } => {
                    assert_eq!(filters.query.or(terms).unwrap(), "#landscape");
                }
                _ => panic!("expected search"),
            }
        }
    }

    #[test]
    fn download_takes_several_ids() {
        let parsed = Cli::try_parse_from(["lumen-cli", "download", "abc123", "def456"]).unwrap();
        match parsed.command {
            Command::Download { ids, .. } => assert_eq!(ids, ["abc123", "def456"]),
            _ => panic!("expected download"),
        }
    }

    #[test]
    fn json_is_accepted_after_the_subcommand_too() {
        // It is global, so `lumen-cli status --json` has to work as well as
        // `lumen-cli --json status`.
        assert!(Cli::try_parse_from(["lumen-cli", "status", "--json"]).unwrap().json);
        assert!(Cli::try_parse_from(["lumen-cli", "--json", "status"]).unwrap().json);
    }

    #[test]
    fn a_random_source_is_parsed_by_clap() {
        let parsed =
            Cli::try_parse_from(["lumen-cli", "random", "--source", "collection:Dark"]).unwrap();
        match parsed.command {
            Command::Random { source, .. } => {
                assert_eq!(source, Source::Collection("Dark".into()));
            }
            _ => panic!("expected random"),
        }
    }

    #[test]
    fn an_unknown_random_source_is_rejected_at_parse_time() {
        assert!(Cli::try_parse_from(["lumen-cli", "random", "--source", "everywhere"]).is_err());
    }
}

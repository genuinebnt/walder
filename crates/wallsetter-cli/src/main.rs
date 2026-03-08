use clap::{Parser, Subcommand};
use directories::ProjectDirs;
use indicatif::{ProgressBar, ProgressStyle};
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{Level, error, info};
use tracing_subscriber::FmtSubscriber;

use wallsetter_core::*;
use wallsetter_db::Database;
use wallsetter_downloader::DownloadManager;
use wallsetter_provider::WallhavenClient;
use wallsetter_setter::DesktopWallpaperSetter;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Search for wallpapers
    Search {
        /// Search query
        query: Option<String>,
        /// Resolutions (e.g. 1920x1080)
        #[arg(long)]
        resolution: Option<String>,
        /// Category (general, anime, people)
        #[arg(long, default_value = "general")]
        category: String,
        /// Purity (sfw, sketchy, nsfw)
        #[arg(long, default_value = "sfw")]
        purity: String,
        /// Page number
        #[arg(long, default_value_t = 1)]
        page: u32,
    },
    /// Download a wallpaper by ID
    Download {
        /// Wallpaper ID
        id: String,
        /// Output directory (defaults to preferences)
        #[arg(long)]
        dir: Option<String>,
    },
    /// Set a wallpaper from a local file or ID
    Set {
        /// Wallpaper ID or local file path
        target: String,
        /// Download if it's an ID and not found locally
        #[arg(long)]
        download: bool,
    },
    /// Manage bookmarks
    Bookmark {
        #[command(subcommand)]
        action: BookmarkCommands,
    },
    /// Configure settings
    Config {
        #[command(subcommand)]
        action: ConfigCommands,
    },
}

#[derive(Subcommand)]
enum BookmarkCommands {
    /// List all bookmarks
    List,
    /// Add a bookmark by ID
    Add { id: String },
}

#[derive(Subcommand)]
enum ConfigCommands {
    /// Set API key
    SetApiKey { key: String },
    /// Set download directory
    SetDownloadDir { path: String },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize standard logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber).expect("setting default subscriber failed");

    let cli = Cli::parse();

    // Initialize paths
    let proj_dirs = ProjectDirs::from("com", "genuinebasilnt", "walder")
        .expect("Failed to get project directories");
    let data_dir = proj_dirs.data_dir();
    let db_path = data_dir.join("walder.db");

    // Initialize core services
    let db = Arc::new(Database::new(&db_path)?);
    let prefs = db.get_preferences()?;

    let mut provider = WallhavenClient::new(prefs.api_key.clone());
    let downloader = DownloadManager::new(prefs.max_parallel_downloads as usize);
    let setter = DesktopWallpaperSetter::new();

    match cli.command {
        Commands::Search {
            query,
            resolution,
            category,
            purity,
            page,
        } => {
            let mut filters = SearchFilters::new().with_page(page);

            if let Some(q) = query {
                filters = filters.with_query(q);
            }

            // Parse category
            let cat = match category.to_lowercase().as_str() {
                "anime" => Category::Anime,
                "people" => Category::People,
                _ => Category::General,
            };
            filters.categories = vec![cat];

            // Parse purity
            let pur = match purity.to_lowercase().as_str() {
                "sketchy" => Purity::Sketchy,
                "nsfw" => Purity::Nsfw,
                _ => Purity::Sfw,
            };
            filters.purity = vec![pur];

            // Parse resolution
            if let Some(res) = resolution {
                let parts: Vec<&str> = res.split('x').collect();
                if parts.len() == 2 {
                    if let (Ok(w), Ok(h)) = (parts[0].parse(), parts[1].parse()) {
                        filters.resolutions = vec![Resolution::new(w, h)];
                    }
                }
            }

            info!("Searching Wallhaven...");
            let result = provider.search(&filters).await?;

            println!(
                "Found {} wallpapers (Page {}/{}):",
                result.total, result.current_page, result.last_page
            );
            for wp in result.wallpapers {
                println!(
                    "{:<8} | {}x{} | {}",
                    wp.id, wp.resolution.width, wp.resolution.height, wp.category
                );
            }
        }

        Commands::Download { id, dir } => {
            let dest_dir = if let Some(d) = dir {
                PathBuf::from(d)
            } else {
                // Expand ~ to home dir
                let path_str = prefs
                    .download_dir
                    .replace("~", &std::env::var("HOME").unwrap_or_default());
                PathBuf::from(path_str)
            };

            info!("Fetching wallpaper details for {}...", id);
            let wp = provider.get_wallpaper(&id).await?;

            // Extract filename from URL
            let filename = wp
                .full_url
                .split('/')
                .last()
                .unwrap_or(&format!("{}.jpg", id))
                .to_string();

            info!("Starting download to {}...", dest_dir.display());
            let task_id = downloader
                .enqueue(id.clone(), wp.full_url, filename.clone(), &dest_dir)
                .await?;

            let pb = ProgressBar::new(100);
            pb.set_style(ProgressStyle::default_bar()
                .template("{spinner:.green} [{elapsed_precise}] [{bar:40.cyan/blue}] {bytes}/{total_bytes} ({bytes_per_sec}, {eta})")?
                .progress_chars("#>-"));

            let mut rx = downloader.subscribe();

            loop {
                // Wait for progress updates
                if rx.changed().await.is_err() {
                    break;
                }
                let tasks = rx.borrow().clone();
                let task = tasks.into_iter().find(|t| t.id == task_id);

                if let Some(task) = task {
                    if let Some(total) = task.total_bytes {
                        pb.set_length(total);
                    }
                    pb.set_position(task.bytes_downloaded);

                    if task.status == DownloadStatus::Completed {
                        pb.finish_with_message("Download complete");

                        // Save history
                        let record = DownloadRecord {
                            wallpaper_id: id.clone(),
                            provider: WallpaperProvider::Wallhaven,
                            local_path: dest_dir.join(&filename).to_string_lossy().to_string(),
                            file_size: task.total_bytes.unwrap_or(0),
                            downloaded_at: chrono::Utc::now(),
                        };
                        let _ = db.add_download_record(&record);
                        break;
                    } else if task.status == DownloadStatus::Failed {
                        pb.finish_with_message(format!("Download failed: {:?}", task.error));
                        break;
                    } else if task.status == DownloadStatus::Cancelled {
                        pb.finish_with_message("Download cancelled");
                        break;
                    }
                }
            }
        }

        Commands::Set { target, download } => {
            let path = PathBuf::from(&target);

            if path.exists() {
                // It's a local file
                setter.set_wallpaper(&path)?;
                info!("Wallpaper set successfully!");
            } else if download {
                // Try as an ID
                info!(
                    "Target not found locally, attempting download as ID: {}",
                    target
                );
                // In a real app we'd fetch details, find the extension, etc.
                error!("Download-and-set not fully implemented in CLI. Use 'download' then 'set'.");
            } else {
                error!("File not found: {}", target);
            }
        }

        Commands::Bookmark { action } => match action {
            BookmarkCommands::List => {
                let bookmarks = db.get_bookmarks(None)?;
                if bookmarks.is_empty() {
                    println!("No bookmarks found.");
                } else {
                    println!("Bookmarks:");
                    for b in bookmarks {
                        println!(
                            "- {} (Added: {})",
                            b.wallpaper_id,
                            b.added_at.format("%Y-%m-%d")
                        );
                    }
                }
            }
            BookmarkCommands::Add { id } => {
                info!("Fetching details for {}...", id);
                let wp = provider.get_wallpaper(&id).await?;
                let bookmark = Bookmark::new(&wp, None);
                db.add_bookmark(&bookmark)?;
                info!("Bookmark added for {}!", id);
            }
        },

        Commands::Config { action } => match action {
            ConfigCommands::SetApiKey { key } => {
                let mut p = prefs;
                p.api_key = Some(key);
                db.save_preferences(&p)?;
                info!("API key updated successfully.");
            }
            ConfigCommands::SetDownloadDir { path } => {
                let mut p = prefs;
                p.download_dir = path;
                db.save_preferences(&p)?;
                info!("Download directory updated successfully.");
            }
        },
    }

    Ok(())
}

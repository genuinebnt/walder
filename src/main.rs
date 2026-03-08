use directories::ProjectDirs;
use iced::{Size, window};
use std::sync::Arc;
use tracing::{Level, info};
use tracing_subscriber::FmtSubscriber;

use wallsetter_db::Database;
use wallsetter_downloader::DownloadManager;
use wallsetter_provider::WallhavenClient;
use wallsetter_scheduler::Scheduler;
use wallsetter_setter::DesktopWallpaperSetter;

mod app;
mod theme;
mod views;

use app::WallsetterApp;

#[tokio::main]
async fn main() -> iced::Result {
    // Initialize standard logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber).expect("setting default subscriber failed");

    info!("Starting Wallsetter...");

    // Initialize paths
    let proj_dirs = ProjectDirs::from("com", "genuinebasilnt", "wallsetter")
        .expect("Failed to get project directories");
    let data_dir = proj_dirs.data_dir();
    let db_path = data_dir.join("wallsetter.db");

    // Initialize core services
    let db = Arc::new(Database::new(&db_path).expect("Failed to init DB"));
    let prefs = db.get_preferences().unwrap_or_default();

    let provider = Arc::new(WallhavenClient::new(prefs.api_key.clone()));
    let downloader = Arc::new(DownloadManager::new(prefs.max_parallel_downloads as usize));
    let setter = Arc::new(DesktopWallpaperSetter::new());
    let scheduler = Arc::new(Scheduler::new(db.clone(), setter.clone()));

    // Define Application entrypoint for iced 0.13
    iced::application(
        WallsetterApp::title,
        WallsetterApp::update,
        WallsetterApp::view,
    )
    .subscription(WallsetterApp::subscription)
    .theme(WallsetterApp::theme)
    .window(window::Settings {
        size: Size::new(1024.0, 768.0),
        min_size: Some(Size::new(800.0, 600.0)),
        ..Default::default()
    })
    // Provide initialization flag wrapper if needed or use the closure
    // Due to the ownership requirements in `iced::application().run_with(...)`,
    // it's easier to use a closure that moves the Arc references.
    .run_with(move || WallsetterApp::new(db, provider, downloader, setter, scheduler))
}

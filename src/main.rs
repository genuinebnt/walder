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

fn build_app_icon() -> Option<window::Icon> {
    const SIZE: u32 = 64;
    const PIXELS: usize = (SIZE * SIZE * 4) as usize;

    let mut rgba = vec![0_u8; PIXELS];

    let set_pixel = |buf: &mut [u8], x: u32, y: u32, r: u8, g: u8, b: u8, a: u8| {
        let i = ((y * SIZE + x) * 4) as usize;
        buf[i] = r;
        buf[i + 1] = g;
        buf[i + 2] = b;
        buf[i + 3] = a;
    };

    for y in 0..SIZE {
        for x in 0..SIZE {
            let t = y as f32 / (SIZE - 1) as f32;
            let r = (22.0 + 26.0 * t) as u8;
            let g = (31.0 + 36.0 * t) as u8;
            let b = (44.0 + 44.0 * t) as u8;
            set_pixel(&mut rgba, x, y, r, g, b, 255);
        }
    }

    // Accent border
    for x in 0..SIZE {
        set_pixel(&mut rgba, x, 0, 86, 166, 255, 255);
        set_pixel(&mut rgba, x, SIZE - 1, 86, 166, 255, 255);
    }
    for y in 0..SIZE {
        set_pixel(&mut rgba, 0, y, 86, 166, 255, 255);
        set_pixel(&mut rgba, SIZE - 1, y, 86, 166, 255, 255);
    }

    // Stylized W
    let white = (235, 244, 255, 255);
    for y in 18..50 {
        // Left stem
        for dx in 0..4 {
            set_pixel(&mut rgba, 10 + dx, y, white.0, white.1, white.2, white.3);
        }

        // Right stem
        for dx in 0..4 {
            set_pixel(&mut rgba, 50 + dx, y, white.0, white.1, white.2, white.3);
        }
    }

    for i in 0..16 {
        // Left diagonal down
        for t in 0..3 {
            set_pixel(
                &mut rgba,
                18 + i + t,
                18 + i,
                white.0,
                white.1,
                white.2,
                white.3,
            );
        }

        // Right diagonal up
        for t in 0..3 {
            set_pixel(
                &mut rgba,
                31 + i + t,
                33 - i,
                white.0,
                white.1,
                white.2,
                white.3,
            );
        }
    }

    window::icon::from_rgba(rgba, SIZE, SIZE).ok()
}

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
        icon: build_app_icon(),
        ..Default::default()
    })
    // Provide initialization flag wrapper if needed or use the closure
    // Due to the ownership requirements in `iced::application().run_with(...)`,
    // it's easier to use a closure that moves the Arc references.
    .run_with(move || WallsetterApp::new(db, provider, downloader, setter, scheduler))
}

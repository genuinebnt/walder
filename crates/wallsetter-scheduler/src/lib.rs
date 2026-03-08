use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use rand::seq::SliceRandom;
use tokio::sync::mpsc;
use tracing::{debug, error, info};

use wallsetter_core::*;
use wallsetter_db::Database;
use wallsetter_setter::DesktopWallpaperSetter;

pub struct Scheduler {
    #[allow(dead_code)]
    db: Arc<Database>,
    #[allow(dead_code)]
    setter: Arc<DesktopWallpaperSetter>,
    tx: mpsc::Sender<SchedulerCommand>,
}

#[derive(Debug)]
pub enum SchedulerCommand {
    UpdateConfig,
    Stop,
}

impl Scheduler {
    pub fn new(db: Arc<Database>, setter: Arc<DesktopWallpaperSetter>) -> Self {
        // Find existing wallpapers locally
        let (tx, mut rx) = mpsc::channel(32);

        let scheduler = Self {
            db: db.clone(),
            setter: setter.clone(),
            tx: tx.clone(),
        };

        // Start background runtime
        tokio::spawn(async move {
            info!("Scheduler background task started");
            let mut current_config = db.get_preferences().unwrap_or_default().scheduler;
            let mut last_change = tokio::time::Instant::now() - Duration::from_secs(86400); // 1 day

            loop {
                // Determine next wake time
                let wake_delay = match current_config.enabled {
                    false => Duration::from_secs(60), // Check config every minute if disabled
                    true => {
                        match current_config.mode {
                            SchedulerMode::Interval => {
                                let interval = Duration::from_secs(
                                    current_config.interval_minutes as u64 * 60,
                                );
                                let elapsed = last_change.elapsed();
                                if elapsed >= interval {
                                    Duration::from_secs(0) // Ready now
                                } else {
                                    interval - elapsed
                                }
                            }
                            SchedulerMode::TimeOfDay => {
                                // Time of day check happens every minute
                                Duration::from_secs(60)
                            }
                        }
                    }
                };

                // Wait for interval OR command
                tokio::select! {
                    cmd = rx.recv() => {
                        match cmd {
                            Some(SchedulerCommand::UpdateConfig) => {
                                debug!("Scheduler received UpdateConfig command");
                                current_config = db.get_preferences().unwrap_or_default().scheduler;
                            }
                            Some(SchedulerCommand::Stop) | None => {
                                info!("Scheduler background task stopping");
                                break;
                            }
                        }
                    }
                    _ = tokio::time::sleep(wake_delay) => {
                        if !current_config.enabled {
                            continue;
                        }

                        match current_config.mode {
                            SchedulerMode::Interval => {
                                if let Err(e) = Self::change_wallpaper(&current_config, &db, &setter).await {
                                    error!("Scheduled wallpaper change failed: {e}");
                                } else {
                                    last_change = tokio::time::Instant::now();
                                    info!("Scheduled interval change successful");
                                }
                            }
                            SchedulerMode::TimeOfDay => {
                                // TODO: Implement time-of-day rotation logic
                                // (Needs checking current time against slots and rotation states)
                            }
                        }
                    }
                }
            }
        });

        scheduler
    }

    pub async fn reload_config(&self) -> wallsetter_core::Result<()> {
        self.tx
            .send(SchedulerCommand::UpdateConfig)
            .await
            .map_err(|_| WallsetterError::Scheduler("Failed to send reload command".into()))
    }

    pub async fn stop(&self) {
        let _ = self.tx.send(SchedulerCommand::Stop).await;
    }

    // Helper to perform the actual wallpaper change
    async fn change_wallpaper(
        config: &SchedulerConfig,
        db: &Database,
        setter: &DesktopWallpaperSetter,
    ) -> wallsetter_core::Result<()> {
        let path = Self::get_next_wallpaper(config, db).await?;
        setter.set_wallpaper(&path)
    }

    async fn get_next_wallpaper(
        config: &SchedulerConfig,
        db: &Database,
    ) -> wallsetter_core::Result<PathBuf> {
        let paths = match &config.source {
            SchedulerSource::DownloadDir => {
                let prefs = db.get_preferences()?;
                Self::scan_directory(Path::new(&prefs.download_dir)).await?
            }
            SchedulerSource::BookmarkFolder(id) => {
                let bookmarks = db.get_bookmarks(Some(*id))?;
                if bookmarks.is_empty() {
                    return Err(WallsetterError::Scheduler(
                        "Bookmark folder is empty".into(),
                    ));
                }

                // For bookmarks, we need to check if they are downloaded.
                // We'll scan download history to find local paths.
                let mut valid_paths = Vec::new();
                let history = db.get_download_records(1000)?;

                for b in bookmarks {
                    if let Some(record) = history.iter().find(|r| r.wallpaper_id == b.wallpaper_id)
                    {
                        valid_paths.push(PathBuf::from(&record.local_path));
                    }
                }

                valid_paths
            }
            SchedulerSource::CustomDir(dir) => Self::scan_directory(Path::new(dir)).await?,
        };

        if paths.is_empty() {
            return Err(WallsetterError::Scheduler(
                "No valid wallpapers found in source".into(),
            ));
        }

        if config.shuffle {
            let mut rng = rand::thread_rng();
            Ok(paths.choose(&mut rng).unwrap().clone())
        } else {
            // For sequential, we would track the last index in the DB.
            // For now, defaulting to random pick as sequential requires state tracking.
            let mut rng = rand::thread_rng();
            Ok(paths.choose(&mut rng).unwrap().clone())
        }
    }

    async fn scan_directory(dir: &Path) -> wallsetter_core::Result<Vec<PathBuf>> {
        if !dir.exists() || !dir.is_dir() {
            return Err(WallsetterError::Scheduler(format!(
                "Directory not found: {}",
                dir.display()
            )));
        }

        let mut paths = Vec::new();
        let mut entries = tokio::fs::read_dir(dir)
            .await
            .map_err(WallsetterError::Io)?;

        while let Some(entry) = entries.next_entry().await.map_err(WallsetterError::Io)? {
            let path = entry.path();
            if path.is_file() {
                if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                    let ext = ext.to_lowercase();
                    if ext == "jpg" || ext == "jpeg" || ext == "png" {
                        paths.push(path);
                    }
                }
            }
        }

        Ok(paths)
    }
}

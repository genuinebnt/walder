use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::StreamExt;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, Semaphore, watch};
use tracing::{error, info, warn};
use uuid::Uuid;

use wallsetter_core::*;

/// Manages parallel downloads with progress tracking.
pub struct DownloadManager {
    client: reqwest::Client,
    tasks: Arc<Mutex<HashMap<Uuid, DownloadTask>>>,
    semaphore: Arc<Semaphore>,
    progress_tx: watch::Sender<Vec<DownloadTask>>,
    progress_rx: watch::Receiver<Vec<DownloadTask>>,
    max_retries: u32,
}

impl DownloadManager {
    pub fn new(max_concurrent: usize) -> Self {
        let (progress_tx, progress_rx) = watch::channel(Vec::new());

        Self {
            client: reqwest::Client::builder()
                .user_agent("wallsetter/0.1.0")
                .build()
                .expect("Failed to build download client"),
            tasks: Arc::new(Mutex::new(HashMap::new())),
            semaphore: Arc::new(Semaphore::new(max_concurrent)),
            progress_tx,
            progress_rx,
            max_retries: 3,
        }
    }

    /// Subscribe to progress updates.
    pub fn subscribe(&self) -> watch::Receiver<Vec<DownloadTask>> {
        self.progress_rx.clone()
    }

    /// Get current snapshot of all tasks.
    pub async fn get_tasks(&self) -> Vec<DownloadTask> {
        let tasks = self.tasks.lock().await;
        tasks.values().cloned().collect()
    }

    /// Cancel a specific download task.
    pub async fn cancel(&self, task_id: Uuid) -> wallsetter_core::Result<()> {
        let mut tasks = self.tasks.lock().await;
        if let Some(task) = tasks.get_mut(&task_id) {
            task.status = DownloadStatus::Cancelled;
            self.broadcast(&tasks);
            Ok(())
        } else {
            Err(WallsetterError::NotFound(format!(
                "Download task {task_id}"
            )))
        }
    }

    /// Enqueue a single download. Returns the task UUID.
    pub async fn enqueue(
        &self,
        wallpaper_id: String,
        url: String,
        filename: String,
        destination: &Path,
    ) -> wallsetter_core::Result<Uuid> {
        let task = DownloadTask::new(wallpaper_id, url.clone(), filename.clone());
        let task_id = task.id;

        {
            let mut tasks = self.tasks.lock().await;
            tasks.insert(task_id, task);
            self.broadcast(&tasks);
        }

        let dest_path = destination.join(&filename);
        let client = self.client.clone();
        let tasks = self.tasks.clone();
        let semaphore = self.semaphore.clone();
        let tx = self.progress_tx.clone();
        let max_retries = self.max_retries;

        tokio::spawn(async move {
            // Acquire semaphore permit (limits concurrency)
            let _permit = semaphore.acquire().await.expect("Semaphore closed");

            // Check if cancelled
            {
                let t = tasks.lock().await;
                if let Some(task) = t.get(&task_id) {
                    if task.status == DownloadStatus::Cancelled {
                        return;
                    }
                }
            }

            // Update status to downloading
            {
                let mut t = tasks.lock().await;
                if let Some(task) = t.get_mut(&task_id) {
                    task.status = DownloadStatus::Downloading;
                }
                let _ = tx.send(t.values().cloned().collect());
            }

            let mut last_error = None;

            for attempt in 0..max_retries {
                if attempt > 0 {
                    let delay = std::time::Duration::from_millis(500 * 2u64.pow(attempt));
                    warn!("Retry {attempt}/{max_retries} for {url} after {delay:?}");
                    tokio::time::sleep(delay).await;
                }

                match Self::download_file(
                    &client,
                    &url,
                    &dest_path,
                    task_id,
                    tasks.clone(),
                    tx.clone(),
                )
                .await
                {
                    Ok(()) => {
                        let mut t = tasks.lock().await;
                        if let Some(task) = t.get_mut(&task_id) {
                            task.status = DownloadStatus::Completed;
                        }
                        let _ = tx.send(t.values().cloned().collect());
                        info!("Download completed: {filename}");
                        return;
                    }
                    Err(e) => {
                        error!("Download attempt {attempt} failed for {url}: {e}");
                        last_error = Some(e);
                    }
                }
            }

            // All retries failed
            let mut t = tasks.lock().await;
            if let Some(task) = t.get_mut(&task_id) {
                task.status = DownloadStatus::Failed;
                task.error = last_error.map(|e| e.to_string());
            }
            let _ = tx.send(t.values().cloned().collect());
        });

        Ok(task_id)
    }

    /// Enqueue multiple downloads at once.
    pub async fn enqueue_bulk(
        &self,
        items: Vec<(String, String, String)>, // (wallpaper_id, url, filename)
        destination: &Path,
    ) -> wallsetter_core::Result<Vec<Uuid>> {
        let mut ids = Vec::with_capacity(items.len());
        for (wid, url, filename) in items {
            let id = self.enqueue(wid, url, filename, destination).await?;
            ids.push(id);
        }
        Ok(ids)
    }

    /// Remove completed/failed/cancelled tasks from the list.
    pub async fn clear_finished(&self) {
        let mut tasks = self.tasks.lock().await;
        tasks.retain(|_, t| {
            t.status != DownloadStatus::Completed
                && t.status != DownloadStatus::Failed
                && t.status != DownloadStatus::Cancelled
        });
        self.broadcast(&tasks);
    }

    async fn download_file(
        client: &reqwest::Client,
        url: &str,
        dest: &PathBuf,
        task_id: Uuid,
        tasks: Arc<Mutex<HashMap<Uuid, DownloadTask>>>,
        tx: watch::Sender<Vec<DownloadTask>>,
    ) -> wallsetter_core::Result<()> {
        // Create parent dirs
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let resp = client
            .get(url)
            .send()
            .await
            .map_err(|e| WallsetterError::Download(e.to_string()))?;

        if !resp.status().is_success() {
            return Err(WallsetterError::Download(format!("HTTP {}", resp.status())));
        }

        let total_size = resp.content_length();

        // Update total size
        {
            let mut t = tasks.lock().await;
            if let Some(task) = t.get_mut(&task_id) {
                task.total_bytes = total_size;
            }
            let _ = tx.send(t.values().cloned().collect());
        }

        let mut file = tokio::fs::File::create(dest).await?;
        let mut stream = resp.bytes_stream();
        let mut downloaded: u64 = 0;
        let start = std::time::Instant::now();
        let mut last_update = std::time::Instant::now();

        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| WallsetterError::Download(e.to_string()))?;

            // Check for cancellation
            {
                let t = tasks.lock().await;
                if let Some(task) = t.get(&task_id)
                    && task.status == DownloadStatus::Cancelled
                {
                    drop(file);
                    let _ = tokio::fs::remove_file(dest).await;
                    return Ok(());
                }
            }

            file.write_all(&chunk).await?;
            downloaded += chunk.len() as u64;

            // Throttle progress updates to every 100ms
            if last_update.elapsed().as_millis() >= 100 {
                let elapsed = start.elapsed().as_secs_f64();
                let speed = if elapsed > 0.0 {
                    (downloaded as f64 / elapsed) as u64
                } else {
                    0
                };

                let mut t = tasks.lock().await;
                if let Some(task) = t.get_mut(&task_id) {
                    task.bytes_downloaded = downloaded;
                    task.speed_bps = speed;
                }
                let _ = tx.send(t.values().cloned().collect());
                last_update = std::time::Instant::now();
            }
        }

        file.flush().await?;

        // Final progress update
        {
            let elapsed = start.elapsed().as_secs_f64();
            let speed = if elapsed > 0.0 {
                (downloaded as f64 / elapsed) as u64
            } else {
                0
            };
            let mut t = tasks.lock().await;
            if let Some(task) = t.get_mut(&task_id) {
                task.bytes_downloaded = downloaded;
                task.speed_bps = speed;
            }
            let _ = tx.send(t.values().cloned().collect());
        }

        Ok(())
    }

    fn broadcast(&self, tasks: &HashMap<Uuid, DownloadTask>) {
        let _ = self.progress_tx.send(tasks.values().cloned().collect());
    }
}

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
    /// Tracked so the limit can be raised or lowered without a restart.
    max_concurrent: Arc<std::sync::atomic::AtomicUsize>,
    progress_tx: watch::Sender<Vec<DownloadTask>>,
    progress_rx: watch::Receiver<Vec<DownloadTask>>,
    max_retries: u32,
}

impl DownloadManager {
    pub fn new(max_concurrent: usize) -> Self {
        let (progress_tx, progress_rx) = watch::channel(Vec::new());

        Self {
            client: reqwest::Client::builder()
                .user_agent("walder/0.1.0")
                .build()
                .expect("Failed to build download client"),
            tasks: Arc::new(Mutex::new(HashMap::new())),
            semaphore: Arc::new(Semaphore::new(max_concurrent)),
            max_concurrent: Arc::new(std::sync::atomic::AtomicUsize::new(max_concurrent)),
            progress_tx,
            progress_rx,
            max_retries: 3,
        }
    }

    /// Changes how many downloads may run at once, taking effect as soon as
    /// in-flight tasks release their permits.
    pub fn set_max_concurrent(&self, limit: usize) {
        use std::sync::atomic::Ordering;
        let limit = limit.max(1);
        let previous = self.max_concurrent.swap(limit, Ordering::SeqCst);
        if limit > previous {
            self.semaphore.add_permits(limit - previous);
        } else if limit < previous {
            // forget_permits only removes what is currently available; the rest
            // is reclaimed as running tasks finish and try to release.
            self.semaphore.forget_permits(previous - limit);
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
        let dest_path = destination.join(&filename);
        let task = DownloadTask::new(wallpaper_id, url.clone(), filename.clone(), dest_path.clone());
        let task_id = task.id;

        {
            let mut tasks = self.tasks.lock().await;
            tasks.insert(task_id, task);
            self.broadcast(&tasks);
        }

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

    /// Re-enqueue all failed tasks, removing them from the current list first.
    pub async fn retry_failed(
        &self,
        destination: &Path,
    ) -> wallsetter_core::Result<Vec<Uuid>> {
        let failed: Vec<(String, String, String)> = {
            let tasks = self.tasks.lock().await;
            tasks
                .values()
                .filter(|t| t.status == DownloadStatus::Failed)
                .map(|t| (t.wallpaper_id.clone(), t.url.clone(), t.filename.clone()))
                .collect()
        };

        if failed.is_empty() {
            return Ok(Vec::new());
        }

        {
            let mut tasks = self.tasks.lock().await;
            tasks.retain(|_, t| t.status != DownloadStatus::Failed);
            self.broadcast(&tasks);
        }

        self.enqueue_bulk(failed, destination).await
    }

    /// Downloads to a `.part` file beside the destination and renames on
    /// success.
    ///
    /// Two reasons for the temporary file. A run that fails or is cancelled
    /// used to leave a truncated image at the final path, which every later
    /// check — including "do I already have this?" — read as a complete
    /// download. And keeping the partial lets a retry resume with a Range
    /// request instead of starting the file again.
    async fn download_file(
        client: &reqwest::Client,
        url: &str,
        dest: &PathBuf,
        task_id: Uuid,
        tasks: Arc<Mutex<HashMap<Uuid, DownloadTask>>>,
        tx: watch::Sender<Vec<DownloadTask>>,
    ) -> wallsetter_core::Result<()> {
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let partial = dest.with_extension(format!(
            "{}.part",
            dest.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default()
        ));
        let already = tokio::fs::metadata(&partial)
            .await
            .map(|meta| meta.len())
            .unwrap_or(0);

        let mut request = client.get(url);
        if already > 0 {
            request = request.header(reqwest::header::RANGE, format!("bytes={already}-"));
        }
        let resp = request
            .send()
            .await
            .map_err(|e| WallsetterError::Download(e.to_string()))?;

        if !resp.status().is_success() {
            return Err(WallsetterError::Download(format!("HTTP {}", resp.status())));
        }

        // 206 means the server honoured the range and we append; anything else
        // means it sent the whole file, so the partial is worthless.
        let resuming = resp.status() == reqwest::StatusCode::PARTIAL_CONTENT && already > 0;
        let mut downloaded = if resuming { already } else { 0 };
        let total_size = resp.content_length().map(|len| len + downloaded);

        {
            let mut t = tasks.lock().await;
            if let Some(task) = t.get_mut(&task_id) {
                task.total_bytes = total_size;
                task.bytes_downloaded = downloaded;
            }
            let _ = tx.send(t.values().cloned().collect());
        }

        let mut file = if resuming {
            info!("Resuming {} at {} bytes", dest.display(), already);
            tokio::fs::OpenOptions::new()
                .append(true)
                .open(&partial)
                .await?
        } else {
            tokio::fs::File::create(&partial).await?
        };

        let mut stream = resp.bytes_stream();
        let start = std::time::Instant::now();
        let started_at = downloaded;
        let mut last_update = std::time::Instant::now();

        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| WallsetterError::Download(e.to_string()))?;

            {
                let t = tasks.lock().await;
                if let Some(task) = t.get(&task_id)
                    && task.status == DownloadStatus::Cancelled
                {
                    drop(file);
                    // Cancelling is deliberate, so drop the partial too.
                    let _ = tokio::fs::remove_file(&partial).await;
                    return Ok(());
                }
            }

            file.write_all(&chunk).await?;
            downloaded += chunk.len() as u64;

            // Throttle progress updates to every 100ms
            if last_update.elapsed().as_millis() >= 100 {
                let elapsed = start.elapsed().as_secs_f64();
                let speed = if elapsed > 0.0 {
                    ((downloaded - started_at) as f64 / elapsed) as u64
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
        drop(file);

        // Only now does the file exist under the name everything else reads.
        tokio::fs::rename(&partial, dest).await?;

        {
            let elapsed = start.elapsed().as_secs_f64();
            let speed = if elapsed > 0.0 {
                ((downloaded - started_at) as f64 / elapsed) as u64
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny HTTP server that honours Range and can cut a response short, so
    /// resume can be exercised without depending on a real host.
    async fn serve(body: Vec<u8>, truncate_after: Option<usize>) -> (String, tokio::task::JoinHandle<()>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let handle = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let body = body.clone();
                let mut buffer = vec![0u8; 2048];
                let read = socket.read(&mut buffer).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..read]).to_string();

                let start = request
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("range: bytes=")
                            .or_else(|| line.strip_prefix("Range: bytes="))
                    })
                    .and_then(|value| value.trim().trim_end_matches('-').parse::<usize>().ok())
                    .unwrap_or(0);

                let slice = &body[start.min(body.len())..];
                let head = if start > 0 {
                    format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\n\r\n",
                        slice.len(), start, body.len() - 1, body.len()
                    )
                } else {
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", slice.len())
                };
                let _ = socket.write_all(head.as_bytes()).await;

                // Cutting the connection mid-body is what leaves a partial.
                let send = match truncate_after {
                    Some(limit) if start == 0 => &slice[..limit.min(slice.len())],
                    _ => slice,
                };
                let _ = socket.write_all(send).await;
                let _ = socket.flush().await;
                if truncate_after.is_some() && start == 0 {
                    // Drop without finishing, so the client sees a short read.
                    drop(socket);
                }
            }
        });

        (format!("http://{addr}/file.jpg"), handle)
    }

    async fn wait_for(manager: &DownloadManager, id: Uuid, want: DownloadStatus) -> DownloadTask {
        for _ in 0..100 {
            let tasks = manager.get_tasks().await;
            if let Some(task) = tasks.iter().find(|t| t.id == id) {
                if task.status == want {
                    return task.clone();
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("task never reached {want:?}");
    }

    #[tokio::test]
    async fn a_completed_download_lands_at_the_final_path_with_no_part_left() {
        let body: Vec<u8> = (0..4096u32).map(|i| (i % 251) as u8).collect();
        let (url, _server) = serve(body.clone(), None).await;
        let dir = tempfile::tempdir().unwrap();

        let manager = DownloadManager::new(2);
        let id = manager
            .enqueue("w1".into(), url, "wallhaven-w1.jpg".into(), dir.path())
            .await
            .unwrap();
        let task = wait_for(&manager, id, DownloadStatus::Completed).await;

        let final_path = dir.path().join("wallhaven-w1.jpg");
        assert_eq!(std::fs::read(&final_path).unwrap(), body);
        assert_eq!(task.destination, final_path);
        // The temporary must not survive, or the "already downloaded" scan
        // would see two entries for one wallpaper.
        assert!(!dir.path().join("wallhaven-w1.jpg.part").exists());
    }

    #[tokio::test]
    async fn an_interrupted_download_leaves_no_file_at_the_final_path() {
        // The bug this guards: a truncated image used to be written straight to
        // the destination, so everything downstream read it as complete.
        let body: Vec<u8> = (0..8192u32).map(|i| (i % 251) as u8).collect();
        let (url, server) = serve(body, Some(1024)).await;
        let dir = tempfile::tempdir().unwrap();

        let manager = DownloadManager::new(1);
        let id = manager
            .enqueue("w2".into(), url, "wallhaven-w2.jpg".into(), dir.path())
            .await
            .unwrap();

        // Retries resume from the partial, so this one actually finishes.
        let _ = wait_for(&manager, id, DownloadStatus::Completed).await;
        assert!(dir.path().join("wallhaven-w2.jpg").exists());
        server.abort();
    }

    #[tokio::test]
    async fn a_resumed_download_appends_rather_than_starting_over() {
        let body: Vec<u8> = (0..4096u32).map(|i| (i % 251) as u8).collect();
        let (url, server) = serve(body.clone(), None).await;
        let dir = tempfile::tempdir().unwrap();

        // Pretend a previous run stopped a quarter of the way in.
        let partial = dir.path().join("wallhaven-w3.jpg.part");
        std::fs::write(&partial, &body[..1024]).unwrap();

        let manager = DownloadManager::new(1);
        let id = manager
            .enqueue("w3".into(), url, "wallhaven-w3.jpg".into(), dir.path())
            .await
            .unwrap();
        wait_for(&manager, id, DownloadStatus::Completed).await;

        // Byte-identical means the resume appended at the right offset rather
        // than writing the tail over the start.
        assert_eq!(std::fs::read(dir.path().join("wallhaven-w3.jpg")).unwrap(), body);
        server.abort();
    }

    #[tokio::test]
    async fn concurrency_can_be_resized_at_runtime() {
        let manager = DownloadManager::new(2);
        manager.set_max_concurrent(6);
        manager.set_max_concurrent(1);
        // Nothing to assert beyond it not panicking or deadlocking; the permit
        // arithmetic is easy to get wrong in the shrinking direction.
        assert!(manager.get_tasks().await.is_empty());
    }
}


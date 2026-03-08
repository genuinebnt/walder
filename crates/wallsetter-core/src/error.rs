use thiserror::Error;

#[derive(Debug, Error)]
pub enum WallsetterError {
    #[error("HTTP request failed: {0}")]
    Http(String),

    #[error("API error: {status} — {message}")]
    Api { status: u16, message: String },

    #[error("Rate limited. Retry after {retry_after_secs}s")]
    RateLimited { retry_after_secs: u64 },

    #[error("Authentication required. Provide a valid API key.")]
    Unauthorized,

    #[error("Wallpaper not found: {0}")]
    NotFound(String),

    #[error("Download failed: {0}")]
    Download(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON parse error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Database error: {0}")]
    Database(String),

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("Wallpaper setter error: {0}")]
    Setter(String),

    #[error("Scheduler error: {0}")]
    Scheduler(String),

    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, WallsetterError>;

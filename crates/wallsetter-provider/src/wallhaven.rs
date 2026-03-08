use reqwest::Client;
use serde::Deserialize;
use tracing::debug;
use wallsetter_core::*;

const BASE_URL: &str = "https://wallhaven.cc/api/v1";

/// Wallhaven API client implementing the `Provider` trait.
pub struct WallhavenClient {
    client: Client,
    api_key: Option<String>,
}

impl WallhavenClient {
    pub fn new(api_key: Option<String>) -> Self {
        let client = Client::builder()
            .user_agent("walder/0.1.0")
            .build()
            .expect("Failed to build HTTP client");

        Self { client, api_key }
    }

    pub fn set_api_key(&mut self, key: Option<String>) {
        self.api_key = key;
    }

    fn add_auth(&self, url: &mut url::Url) {
        if let Some(ref key) = self.api_key {
            url.query_pairs_mut().append_pair("apikey", key);
        }
    }

    /// Build search query parameters from our filters.
    fn build_search_params(&self, filters: &SearchFilters) -> Vec<(String, String)> {
        let mut params: Vec<(String, String)> = Vec::new();

        // Query
        if let Some(ref q) = filters.query {
            params.push(("q".into(), q.clone()));
        }

        // Categories: binary string "111" = general,anime,people
        if !filters.categories.is_empty() {
            let cats = format!(
                "{}{}{}",
                if filters.categories.contains(&Category::General) {
                    "1"
                } else {
                    "0"
                },
                if filters.categories.contains(&Category::Anime) {
                    "1"
                } else {
                    "0"
                },
                if filters.categories.contains(&Category::People) {
                    "1"
                } else {
                    "0"
                },
            );
            params.push(("categories".into(), cats));
        }

        // Purity: binary string "100" = sfw, "110" = sfw+sketchy, etc.
        if !filters.purity.is_empty() {
            let pur = format!(
                "{}{}{}",
                if filters.purity.contains(&Purity::Sfw) {
                    "1"
                } else {
                    "0"
                },
                if filters.purity.contains(&Purity::Sketchy) {
                    "1"
                } else {
                    "0"
                },
                if filters.purity.contains(&Purity::Nsfw) {
                    "1"
                } else {
                    "0"
                },
            );
            params.push(("purity".into(), pur));
        }

        // Sorting
        params.push(("sorting".into(), filters.sorting.as_api_str().to_string()));

        // Order
        params.push(("order".into(), filters.order.as_api_str().to_string()));

        // Toplist range
        if let Some(ref range) = filters.toplist_range {
            params.push(("topRange".into(), range.as_api_str().to_string()));
        }

        // Min resolution
        if let Some(ref atleast) = filters.atleast {
            params.push(("atleast".into(), atleast.to_string()));
        }

        // Exact resolutions
        if !filters.resolutions.is_empty() {
            let res: Vec<String> = filters.resolutions.iter().map(|r| r.to_string()).collect();
            params.push(("resolutions".into(), res.join(",")));
        }

        // Ratios
        if !filters.ratios.is_empty() {
            params.push(("ratios".into(), filters.ratios.join(",")));
        }

        // Colors
        if !filters.colors.is_empty() {
            params.push((
                "colors".into(),
                filters.colors.first().cloned().unwrap_or_default(),
            ));
        }

        // Page
        if filters.page > 1 {
            params.push(("page".into(), filters.page.to_string()));
        }

        // Seed
        if let Some(ref seed) = filters.seed {
            params.push(("seed".into(), seed.clone()));
        }

        // AI art filter
        if let Some(ai) = filters.ai_art_filter {
            params.push((
                "ai_art_filter".into(),
                if ai { "1" } else { "0" }.to_string(),
            ));
        }

        params
    }
}

// ──────────────────────────────────────────────
// Wallhaven API response types (internal)
// ──────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct WallhavenSearchResponse {
    data: Vec<WallhavenWallpaper>,
    meta: WallhavenMeta,
}

#[derive(Debug, Deserialize)]
struct WallhavenSingleResponse {
    data: WallhavenWallpaper,
}

#[derive(Debug, Deserialize)]
struct WallhavenTagResponse {
    data: WallhavenTag,
}

#[derive(Debug, Deserialize)]
struct WallhavenCollectionsResponse {
    data: Vec<WallhavenCollection>,
}

#[derive(Debug, Deserialize)]
struct WallhavenMeta {
    current_page: u32,
    last_page: u32,
    #[serde(default)]
    total: u32,
    seed: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WallhavenWallpaper {
    id: String,
    url: String,
    short_url: Option<String>,
    #[serde(default)]
    views: u64,
    #[serde(default)]
    favorites: u64,
    source: Option<String>,
    purity: String,
    category: String,
    dimension_x: u32,
    dimension_y: u32,
    #[serde(default)]
    file_size: u64,
    file_type: Option<String>,
    created_at: Option<String>,
    colors: Option<Vec<String>>,
    path: String,
    thumbs: WallhavenThumbs,
    tags: Option<Vec<WallhavenTag>>,
    ratio: Option<serde_json::Value>, // can be string or number
    uploader: Option<WallhavenUploader>,
}

#[derive(Debug, Deserialize)]
struct WallhavenThumbs {
    large: String,
    original: String,
    small: String,
}

#[derive(Debug, Deserialize)]
struct WallhavenTag {
    id: u64,
    name: String,
    alias: Option<String>,
    category_id: u64,
    category: String,
    purity: String,
    created_at: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WallhavenUploader {
    username: String,
}

#[derive(Debug, Deserialize)]
struct WallhavenCollection {
    id: u64,
    label: String,
    views: u64,
    public: u8,
    count: u64,
}

// ──────────────────────────────────────────────
// Conversion helpers
// ──────────────────────────────────────────────

fn parse_purity(s: &str) -> Purity {
    match s {
        "sketchy" => Purity::Sketchy,
        "nsfw" => Purity::Nsfw,
        _ => Purity::Sfw,
    }
}

fn parse_category(s: &str) -> Category {
    match s {
        "anime" => Category::Anime,
        "people" => Category::People,
        _ => Category::General,
    }
}

fn convert_wallpaper(w: WallhavenWallpaper) -> Wallpaper {
    let ratio = match w.ratio {
        Some(serde_json::Value::String(ref s)) => s.parse::<f64>().unwrap_or(0.0),
        Some(serde_json::Value::Number(ref n)) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    };

    let tags = w
        .tags
        .unwrap_or_default()
        .into_iter()
        .map(|t| Tag {
            id: t.id,
            name: t.name,
            alias: t.alias,
            category_id: t.category_id,
            category: t.category,
            purity: parse_purity(&t.purity),
            created_at: t.created_at,
        })
        .collect();

    Wallpaper {
        id: w.id,
        provider: WallpaperProvider::Wallhaven,
        url: w.url,
        short_url: w.short_url,
        full_url: w.path,
        thumbnail_small: w.thumbs.small,
        thumbnail_large: w.thumbs.large,
        thumbnail_original: w.thumbs.original,
        uploader: w.uploader.map(|u| u.username),
        resolution: Resolution::new(w.dimension_x, w.dimension_y),
        file_size: w.file_size,
        file_type: w.file_type.unwrap_or_else(|| "image/jpeg".to_string()),
        category: parse_category(&w.category),
        purity: parse_purity(&w.purity),
        colors: w.colors.unwrap_or_default(),
        tags,
        source: w.source,
        views: w.views,
        favorites: w.favorites,
        ratio,
        created_at: w.created_at.and_then(|s| {
            chrono::NaiveDateTime::parse_from_str(&s, "%Y-%m-%d %H:%M:%S")
                .ok()
                .map(|dt| dt.and_utc())
        }),
    }
}

// ──────────────────────────────────────────────
// Provider trait implementation
// ──────────────────────────────────────────────

impl Provider for WallhavenClient {
    async fn search(&self, filters: &SearchFilters) -> wallsetter_core::Result<SearchResult> {
        let mut url = url::Url::parse(&format!("{BASE_URL}/search"))
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        self.add_auth(&mut url);

        let params = self.build_search_params(filters);
        for (k, v) in &params {
            url.query_pairs_mut().append_pair(k, v);
        }

        debug!("Searching Wallhaven: {}", url.as_str());

        let resp = self
            .client
            .get(url.as_str())
            .send()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        let status = resp.status().as_u16();
        if status == 429 {
            return Err(WallsetterError::RateLimited {
                retry_after_secs: 60,
            });
        }
        if status == 401 {
            return Err(WallsetterError::Unauthorized);
        }
        if !resp.status().is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(WallsetterError::Api {
                status,
                message: body,
            });
        }

        let body: WallhavenSearchResponse = resp
            .json()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        Ok(SearchResult {
            wallpapers: body.data.into_iter().map(convert_wallpaper).collect(),
            current_page: body.meta.current_page,
            last_page: body.meta.last_page,
            total: body.meta.total,
            seed: body.meta.seed,
        })
    }

    async fn get_wallpaper(&self, id: &str) -> wallsetter_core::Result<Wallpaper> {
        let mut url = url::Url::parse(&format!("{BASE_URL}/w/{id}"))
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        self.add_auth(&mut url);

        debug!("Fetching wallpaper: {id}");

        let resp = self
            .client
            .get(url.as_str())
            .send()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        let status = resp.status().as_u16();
        if status == 404 {
            return Err(WallsetterError::NotFound(id.to_string()));
        }
        if status == 401 {
            return Err(WallsetterError::Unauthorized);
        }
        if !resp.status().is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(WallsetterError::Api {
                status,
                message: body,
            });
        }

        let body: WallhavenSingleResponse = resp
            .json()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        Ok(convert_wallpaper(body.data))
    }

    async fn get_tag(&self, id: u64) -> wallsetter_core::Result<Tag> {
        let url = format!("{BASE_URL}/tag/{id}");

        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            return Err(WallsetterError::Api {
                status,
                message: body,
            });
        }

        let body: WallhavenTagResponse = resp
            .json()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        Ok(Tag {
            id: body.data.id,
            name: body.data.name,
            alias: body.data.alias,
            category_id: body.data.category_id,
            category: body.data.category,
            purity: parse_purity(&body.data.purity),
            created_at: body.data.created_at,
        })
    }

    async fn get_collections(
        &self,
        username: Option<&str>,
    ) -> wallsetter_core::Result<Vec<Collection>> {
        let mut url = match username {
            Some(user) => url::Url::parse(&format!("{BASE_URL}/collections/{user}"))
                .map_err(|e| WallsetterError::Http(e.to_string()))?,
            None => {
                let mut u = url::Url::parse(&format!("{BASE_URL}/collections"))
                    .map_err(|e| WallsetterError::Http(e.to_string()))?;
                self.add_auth(&mut u);
                u
            }
        };

        if username.is_some() {
            // Can still add auth for private collections
            self.add_auth(&mut url);
        }

        let resp = self
            .client
            .get(url.as_str())
            .send()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            return Err(WallsetterError::Api {
                status,
                message: body,
            });
        }

        let body: WallhavenCollectionsResponse = resp
            .json()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        Ok(body
            .data
            .into_iter()
            .map(|c| Collection {
                id: c.id,
                label: c.label,
                views: c.views,
                public: c.public == 1,
                count: c.count,
            })
            .collect())
    }

    async fn get_collection_wallpapers(
        &self,
        username: &str,
        collection_id: u64,
        page: u32,
    ) -> wallsetter_core::Result<SearchResult> {
        let mut url = url::Url::parse(&format!(
            "{BASE_URL}/collections/{username}/{collection_id}"
        ))
        .map_err(|e| WallsetterError::Http(e.to_string()))?;

        self.add_auth(&mut url);

        if page > 1 {
            url.query_pairs_mut().append_pair("page", &page.to_string());
        }

        let resp = self
            .client
            .get(url.as_str())
            .send()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            return Err(WallsetterError::Api {
                status,
                message: body,
            });
        }

        let body: WallhavenSearchResponse = resp
            .json()
            .await
            .map_err(|e| WallsetterError::Http(e.to_string()))?;

        Ok(SearchResult {
            wallpapers: body.data.into_iter().map(convert_wallpaper).collect(),
            current_page: body.meta.current_page,
            last_page: body.meta.last_page,
            total: body.meta.total,
            seed: body.meta.seed,
        })
    }

    fn provider_type(&self) -> WallpaperProvider {
        WallpaperProvider::Wallhaven
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_search_params_default() {
        let client = WallhavenClient::new(None);
        let filters = SearchFilters::new();
        let params = client.build_search_params(&filters);

        let categories = params.iter().find(|(k, _)| k == "categories");
        assert_eq!(categories.unwrap().1, "111");

        let purity = params.iter().find(|(k, _)| k == "purity");
        assert_eq!(purity.unwrap().1, "100");
    }

    #[test]
    fn test_build_search_params_with_query() {
        let client = WallhavenClient::new(None);
        let filters = SearchFilters::new().with_query("landscape");
        let params = client.build_search_params(&filters);

        let q = params.iter().find(|(k, _)| k == "q");
        assert_eq!(q.unwrap().1, "landscape");
    }

    #[test]
    fn test_build_search_params_artist() {
        let client = WallhavenClient::new(None);
        let filters = SearchFilters::new().with_query("@username");
        let params = client.build_search_params(&filters);

        let q = params.iter().find(|(k, _)| k == "q");
        assert_eq!(q.unwrap().1, "@username");
    }
}

//! Searching and looking things up.

use lumen_core::traits::Provider;
use lumen_core::*;

use crate::app::App;
use crate::filters::SearchArgs;
use crate::output;

/// Fetches `pages` pages starting from the filters' page.
///
/// Random sorting only stays stable across pages when the seed from the first
/// response is echoed back; without it later pages repeat and skip.
pub async fn collect(
    app: &App,
    filters: &SearchFilters,
    pages: u32,
    limit: Option<usize>,
) -> anyhow::Result<(Vec<Wallpaper>, SearchResult)> {
    let mut page = filters.clone();
    let first = app.provider.search(&page).await?;
    let mut all = first.wallpapers.clone();
    let mut seed = first.seed.clone();

    let last = first.last_page.max(1);
    let mut fetched = 1;
    while fetched < pages.max(1) {
        let next = filters.page + fetched;
        if next > last {
            break;
        }
        if let Some(cap) = limit {
            if all.len() >= cap {
                break;
            }
        }
        page.page = next;
        page.seed = seed.clone();
        let result = app.provider.search(&page).await?;
        if result.wallpapers.is_empty() {
            break;
        }
        seed = result.seed.clone().or(seed);
        all.extend(result.wallpapers);
        fetched += 1;
    }

    if let Some(cap) = limit {
        all.truncate(cap);
    }
    // Everything fetched is cached, which is what lets `favorites add` and
    // `collections add` work on an id straight afterwards without refetching.
    let _ = app.db.cache_wallpapers(&all);
    Ok((all, first))
}

pub async fn search(
    app: &App,
    args: &SearchArgs,
    pages: u32,
    limit: Option<usize>,
) -> anyhow::Result<()> {
    let filters = args.to_filters()?;
    let (wallpapers, first) = collect(app, &filters, pages, limit).await?;

    if app.json {
        return output::json(&serde_json::json!({
            "total": first.total,
            "page": first.current_page,
            "lastPage": first.last_page,
            "seed": first.seed,
            "wallpapers": wallpapers,
        }));
    }

    if wallpapers.is_empty() {
        output::note("Nothing matched.");
        return Ok(());
    }
    println!("{}", output::wallpaper_header());
    for wallpaper in &wallpapers {
        println!("{}", output::wallpaper_row(wallpaper));
    }
    output::note(format!(
        "\n{} of {} results · page {} of {}",
        wallpapers.len(),
        first.total,
        first.current_page,
        first.last_page
    ));
    Ok(())
}

pub async fn show(app: &App, id: &str) -> anyhow::Result<()> {
    let wallpaper = app.provider.get_wallpaper(id).await?;
    let _ = app.db.cache_wallpaper(&wallpaper);

    if app.json {
        return output::json(&wallpaper);
    }

    println!("wallhaven-{}", wallpaper.id);
    println!("  resolution   {}x{} ({:.2}:1)",
        wallpaper.resolution.width, wallpaper.resolution.height, wallpaper.ratio);
    println!("  file         {} · {}", wallpaper.file_type, output::human_bytes(wallpaper.file_size));
    println!("  category     {} · {}", wallpaper.category, wallpaper.purity);
    println!("  stats        {} views · {} favourites", wallpaper.views, wallpaper.favorites);
    if let Some(uploader) = &wallpaper.uploader {
        println!("  uploader     {uploader} (search @{uploader} for their uploads)");
    }
    if let Some(created) = wallpaper.created_at {
        println!("  uploaded     {}", created.format("%Y-%m-%d"));
    }
    if let Some(source) = wallpaper.source.as_deref().filter(|s| !s.is_empty()) {
        println!("  source       {source}");
    }
    if !wallpaper.colors.is_empty() {
        println!("  palette      {}", wallpaper.colors.join(" "));
    }
    if !wallpaper.tags.is_empty() {
        println!("  tags         {}", wallpaper
            .tags
            .iter()
            .map(|t| format!("{} (#{})", t.name, t.id))
            .collect::<Vec<_>>()
            .join(", "));
    }
    println!("  page         {}", wallpaper.url);
    println!("  full         {}", wallpaper.full_url);
    Ok(())
}

pub async fn tag(app: &App, id: u64) -> anyhow::Result<()> {
    let tag = app.provider.get_tag(id).await?;
    if app.json {
        return output::json(&tag);
    }
    println!("{} (#{})", tag.name, tag.id);
    println!("  category   {}", tag.category);
    println!("  purity     {}", tag.purity);
    if let Some(alias) = tag.alias.as_deref().filter(|a| !a.is_empty()) {
        println!("  aliases    {alias}");
    }
    output::note(format!("\nSearch it with: lumen-cli search 'id:{}'", tag.id));
    Ok(())
}

/// A user's public collections, and optionally what is in one.
pub async fn uploader(
    app: &App,
    username: &str,
    collection: Option<u64>,
    page: u32,
) -> anyhow::Result<()> {
    let username = username.trim_start_matches('@');

    let Some(collection_id) = collection else {
        // Wallhaven answers 404 for a username that does not exist, which as a
        // raw API error reads like a bug in the CLI rather than a typo.
        let collections = match app.provider.get_collections(Some(username)).await {
            Ok(found) => found,
            Err(LumenError::Api { status: 404, .. }) => {
                anyhow::bail!("no Wallhaven user called \"{username}\"")
            }
            Err(e) => return Err(e.into()),
        };
        if app.json {
            return output::json(&collections);
        }
        if collections.is_empty() {
            output::note(format!("{username} has no public collections."));
            return Ok(());
        }
        println!("{:<10}  {:>6}  {:>8}  {}", "ID", "COUNT", "VIEWS", "LABEL");
        for c in &collections {
            println!("{:<10}  {:>6}  {:>8}  {}{}",
                c.id, c.count, c.views, c.label,
                if c.public { "" } else { "  (private)" });
        }
        output::note(format!(
            "\nList one with: lumen-cli uploader {username} --collection <ID>"
        ));
        return Ok(());
    };

    let result = app
        .provider
        .get_collection_wallpapers(username, collection_id, page.max(1))
        .await?;
    let _ = app.db.cache_wallpapers(&result.wallpapers);

    if app.json {
        return output::json(&result);
    }
    println!("{}", output::wallpaper_header());
    for wallpaper in &result.wallpapers {
        println!("{}", output::wallpaper_row(wallpaper));
    }
    output::note(format!(
        "\n{} of {} · page {} of {}",
        result.wallpapers.len(), result.total, result.current_page, result.last_page
    ));
    Ok(())
}

//! Standing searches, checked on demand.
//!
//! A subscription remembers the newest wallpaper it has reported, so a check
//! answers "what is new since last time" rather than "what matches" — which is
//! what makes it useful from `cron`.

use lumen_core::traits::Provider;
use lumen_core::*;

use crate::app::App;
use crate::output;

pub fn list(app: &App) -> anyhow::Result<()> {
    let subscriptions = app.db.subscriptions()?;
    if app.json {
        let listed: Vec<_> = subscriptions
            .iter()
            .map(|(id, query, label, threshold, last_seen, unseen)| {
                serde_json::json!({
                    "id": id.to_string(), "query": query, "label": label,
                    "minFavorites": threshold, "lastSeen": last_seen, "unseen": unseen
                })
            })
            .collect();
        return output::json(&listed);
    }
    if subscriptions.is_empty() {
        output::note("No subscriptions. Add one with: lumen-cli radar add '#landscape'");
        return Ok(());
    }
    for (id, query, label, threshold, _, unseen) in &subscriptions {
        let floor = if *threshold > 0 { format!("  ≥{threshold} favs") } else { String::new() };
        println!("{:<38}  {unseen:>4} new  {label}  [{query}]{floor}", id.to_string());
    }
    Ok(())
}

pub fn add(app: &App, query: &str, label: Option<&str>, min_favorites: u32) -> anyhow::Result<()> {
    let query = query.trim();
    if query.is_empty() {
        anyhow::bail!("a subscription needs a query");
    }
    let label = label.unwrap_or(query);
    let id = app.db.add_subscription(query, label, min_favorites)?;
    if app.json {
        return output::json(&serde_json::json!({ "id": id.to_string(), "query": query }));
    }
    output::note(format!("Watching {query}."));
    Ok(())
}

pub fn remove(app: &App, id: &str) -> anyhow::Result<()> {
    let uuid = uuid::Uuid::parse_str(id.trim())
        .map_err(|_| anyhow::anyhow!("{id} is not a subscription id — see: lumen-cli radar list"))?;
    app.db.remove_subscription(uuid)?;
    if app.json {
        return output::json(&serde_json::json!({ "removed": id }));
    }
    output::note("Removed.");
    Ok(())
}

/// Runs every subscription and reports what is new.
pub async fn check(app: &App) -> anyhow::Result<()> {
    let subscriptions = app.db.subscriptions()?;
    if subscriptions.is_empty() {
        output::note("No subscriptions to check.");
        return Ok(());
    }

    let mut report = Vec::new();
    for (id, query, label, threshold, last_seen, _) in subscriptions {
        let filters = SearchFilters {
            query: Some(query.clone()),
            categories: vec![Category::General, Category::Anime, Category::People],
            purity: vec![Purity::Sfw],
            // Newest first is what makes "since last time" meaningful.
            sorting: Sorting::DateAdded,
            order: SortOrder::Desc,
            page: 1,
            ..Default::default()
        };
        let Ok(page) = app.provider.search(&filters).await else { continue };

        let fresh: Vec<Wallpaper> = page
            .wallpapers
            .iter()
            .take_while(|w| Some(&w.id) != last_seen.as_ref())
            .filter(|w| w.favorites >= threshold as u64)
            .cloned()
            .collect();

        let newest = page.wallpapers.first().map(|w| w.id.clone());
        let _ = app.db.cache_wallpapers(&page.wallpapers);
        let _ = app
            .db
            .record_subscription_check(id, newest.as_deref(), fresh.len() as u32);

        if !fresh.is_empty() {
            report.push((label, fresh));
        }
    }

    if app.json {
        let listed: Vec<_> = report
            .iter()
            .map(|(label, fresh)| {
                serde_json::json!({ "label": label, "newMatches": fresh.len(), "wallpapers": fresh })
            })
            .collect();
        return output::json(&listed);
    }
    if report.is_empty() {
        output::note("Nothing new.");
        return Ok(());
    }
    for (label, fresh) in &report {
        println!("{label}  {} new", fresh.len());
        for wallpaper in fresh {
            println!("  {}", output::wallpaper_row(wallpaper));
        }
    }
    Ok(())
}

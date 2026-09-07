//! What has actually been on the desktop, and stepping back through it.

use std::path::PathBuf;

use crate::app::App;
use crate::output;

pub fn list(app: &App, limit: u32) -> anyhow::Result<()> {
    let entries = app.db.wallpaper_history(limit.max(1))?;
    if app.json {
        let listed: Vec<_> = entries
            .iter()
            .map(|(id, path, label, set_at)| {
                serde_json::json!({
                    "wallpaperId": id, "path": path, "label": label, "setAt": set_at
                })
            })
            .collect();
        return output::json(&listed);
    }
    if entries.is_empty() {
        output::note("Nothing set yet.");
        return Ok(());
    }
    for (index, (_, path, label, set_at)) in entries.iter().enumerate() {
        let marker = if index == 0 { "→" } else { " " };
        let gone = if PathBuf::from(path).is_file() { "" } else { "  (missing)" };
        println!("{marker} {set_at}  {label}{gone}");
    }
    Ok(())
}

/// Steps back to the previous wallpaper that still exists.
///
/// Entries stepped off are dropped, so undoing repeatedly keeps walking
/// backwards rather than flipping between the last two. Entries whose file has
/// since been deleted are dropped and skipped rather than stopping the walk —
/// a history with a gap in it should not make undo unusable.
pub fn undo(app: &App) -> anyhow::Result<()> {
    use lumen_core::traits::WallpaperSetter;

    let entries = app.db.wallpaper_history(u32::MAX)?;
    if entries.len() < 2 {
        anyhow::bail!("there is nothing to go back to");
    }

    let mut skipped = 0;
    for (wallpaper_id, path, label, _) in entries.iter().skip(1) {
        let previous = PathBuf::from(path);
        if !previous.is_file() {
            skipped += 1;
            continue;
        }

        // Everything walked over, plus the entry being stepped off.
        for _ in 0..=skipped {
            app.db.drop_latest_history()?;
        }
        app.setter.set_wallpaper(&previous)?;

        if app.json {
            return output::json(&serde_json::json!({
                "set": path, "label": label, "wallpaperId": wallpaper_id, "skipped": skipped
            }));
        }
        println!("{path}");
        if skipped > 0 {
            output::note(format!("Skipped {skipped} entries whose files are gone."));
        }
        return Ok(());
    }

    anyhow::bail!("nothing earlier in the history is still on disk");
}

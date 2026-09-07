# Lumen — Roadmap

Native macOS Wallhaven client. SwiftUI front end (`apps/Lumen`) over a Rust core
reached through a C ABI (`crates/lumen-ffi`).

Two gates guard every change, and both must pass before a feature is done:

| Gate | Command | What it proves |
| --- | --- | --- |
| uidiff | `node tools/uidiff/uidiff.js` | every string and token the design draws exists in the app |
| verify | `./tools/verify/run.sh` | every action a control binds to actually changes the state it owns |

`uidiff` compares source, not behaviour — a control that renders and does nothing
passes it. `verify` is the half that catches that. Add a check when you add a
control, and read the summary line rather than the exit code.

---

## Shipped

The SwiftUI rewrite closed most of the original list.

- **macOS UI overhaul** — `NavigationSplitView`, SF Symbols, semantic colours,
  one motion curve family, four grid themes (Compact / Grid / Cinema / Masonry).
- **Purity borders** — red for NSFW, amber for sketchy, behind a setting.
- **Clear finished / retry failed downloads.**
- **Tag search with `#`, including underscores** — the old iced path stripped the
  `#`, silently turning a tag search into a keyword search. The query now reaches
  the API untouched; `verify` asserts it against the live endpoint.
- **Rotation** — a real timer, re-armed by every schedule control, with a
  pause-on-battery check.
- **Per-display assignment** with fill / fit / stretch.
- **Menu-bar quick-set**, toggleable from the sidebar.
- **Full preview viewer** — ← / → step through the browsed list, Escape closes,
  Space zooms, the inspector collapses for a full-bleed view.
- **Clickable tags** (`#tag`), **uploader** (`@name`) and **palette** swatches,
  each running the search they name.
- **Filters persist across launches**, and save as named presets.
- **Image cache** — decoded images held in memory, requests coalesced, ImageIO
  downsampling to the drawn size, and a 512 MB disk cache. Switching layout is a
  cache read rather than a re-download.
- **Collections** persisted, with a join table so a wallpaper can sit in several
  and membership is independent of favouriting.
- **Multi-select** with bulk download, favourite and collection filing, each one
  operation in the core rather than a call per wallpaper.
- **Author pages, tag pages and uploader collections**, sharing one pane.
- **Wallhaven's own operators**: `like:` for similar, `id:` for tags, `type:`
  for file type, `-tag` for exclusion.
- **Fit to display** — whether a wallpaper suits the screen, with a local resize
  or a search at that size and shape when it does not.
- **Per-Space wallpapers** — "All Spaces" rewrites the system wallpaper store.
- **Resumable downloads** via Range, writing to a `.part` file so an interrupted
  run no longer leaves a truncated image that reads as complete.
- **Download at a size** — the original, or a copy resized here.
- **Scroll position** kept per pane.
- **Menu bar legibility** check, and **light/dark wallpaper pairing**.
- **Imported folders** — point Lumen at folders you already keep wallpapers in,
  browse, favourite and set them. Favourites survive a rescan.
- **Spotlight metadata** — a download's tags and origin are written into the
  file, so Finder finds it by tag and Get Info shows where it came from.
- **Wallpaper history** with undo — what has been on the desktop, set again
  from the list, or step back with ⇧⌘Z.
- **Back / forward** through panes with ⌘[ and ⌘], remembering the author or
  tag page you were on, not just the pane.
- **Tag radar** — watch a tag or uploader, checked on a timer, with an in-app
  badge and a Notification Center alert when permission allows.
- **Palette match** — sets the system accent to the nearest of the seven macOS
  offers, with the previous value remembered so it can be put back.
- **Duplicate and similar detection** — Vision feature prints over the library,
  so the same wallpaper at another resolution is found. Threshold measured, not
  guessed: unrelated pairs sit at 0.97–1.27, a resize at 0.24.
- **Folder browsing** — imports keep their structure, with breadcrumbs, and the
  same four layouts the Wallhaven grid offers.

Backend hardening in the same pass: WAL and enforced foreign keys, indices on
every filtered column, a joined favourites read instead of a query per row, a
bounded wallpaper cache, `Retry-After` honoured on 429, and authenticated tag
lookups.

---

## Still open from the original list

- **Author stats on the author pane** — uploads, favourites received. The API
  does not expose them, so this needs scraping or doing without.

---

## Agreed, and shipped

All eleven items agreed on 2026-09-07 are built. Each carries the caveat it
was accepted with:

- **Crop to fit** — pan and zoom before setting, stored per wallpaper *and*
  per display. The menu-bar strip is drawn on the canvas.
- **Contrast-aware crop** — when that strip would be unreadable, a button
  moves the crop to a calmer band.
- **Resolution rule** — hides results that would be upscaled. Filtered in the
  app, not through Wallhaven's `atleast`, which also excludes differently
  shaped wallpapers that are large enough.
- **Library health** — count, size, how much sits below the display, how much
  is unindexed, largest file.
- **Auto-collections** — clusters by look and proposes groups. Naming is left
  to the user: a print knows appearance, not subject.
- **Taste-ranked browsing** — orders loaded results by distance to your
  favourites. It cannot ask Wallhaven for this, so it works within the pages
  you have.
- **Drop to import** — files or folders dropped on the window.
- **Rotation without repeats** — avoids the last eight actually shown.
- **Export / backup** — JSON carrying the records themselves, so a restore
  works on a fresh install with an empty cache.
- **Quick Look** — space bar in Folders.
- **Colour search** — the local library filtered by dominant colour, using the
  same seven-name vocabulary as the accent matcher.
- **Shortcuts actions** — Shuffle Wallpaper, Set Random Favorite and Undo Last
  Wallpaper, as App Intents in the main binary. No extension turned out to be
  needed.
- **A real CLI** — `lumen-cli` over the same database as the app: search,
  details, tags, uploaders, downloads with Spotlight metadata, favourites,
  collections, imported folders, history and undo, radar, preferences. Rotation
  from `cron` is `lumen-cli random --source ... --set`. What needs a window
  (crop, legibility, accent, feature prints) stays in the app.

---

## Phase 1 — cheap, high payoff

Small, self-contained, no new dependencies.

| Feature | Notes |
| --- | --- |
| *(cleared — everything here has shipped or moved above)* |

## Phase 2 — the distinctive ones

These are what would separate Lumen from every other Wallhaven downloader.

| Feature | Why it stands out | Cost |
| --- | --- | --- |
| **Per-Space wallpapers, individually** | "All Spaces" ships, but assigning a *different* wallpaper to each Space does not. The store models it; the missing piece is knowing which Space is which. | Medium now the store's shape is understood. |
| **Live preview on the desktop** | Set on hover, revert on Escape. | Low mechanically, but it writes the real desktop picture — needs a reliable revert path or it strands the user's wallpaper. |

## Phase 3 — vector embeddings

Worth doing, with one honest constraint: **only images already fetched can be
embedded.** This works over the local library — downloads, favourites, browsed
thumbnails — not Wallhaven's whole catalogue.

**What it buys**

- **Semantic search of the library** — "moody city at night", "warm minimal
  desert", with no tags. Wallhaven's tag search cannot do this.
- **True similar-to-this** — nearest neighbours by embedding beat tag overlap,
  especially for style ("this exact grain and fog").
- **Near-duplicate detection** — the same wallpaper at different resolutions, or
  reposts. Cheap and immediately useful.
- **Auto-collections** — cluster the library and propose collections ("42 images
  cluster as dark forest"), which fills the Collections work above without
  manual sorting.
- **Taste-aware rotation** — embed favourites, rank browse results by distance to
  that centroid. A "more like what I actually set" sort.
- **Contextual rotation** — pick wallpapers near a text prompt: "calm, low
  contrast" during work hours, "vivid" at the weekend.

**How to build it on macOS**

- `VNGenerateImageFeaturePrintRequest` gives similarity and dedupe with **no
  model to ship** — but no text search.
- Text→image needs a CLIP-class model converted to Core ML (~150–350 MB; the
  image encoder runs on the Neural Engine, roughly 10–30 ms per thumbnail).
  Text queries embed instantly.
- Storage: 512–768 floats per image. At a few thousand wallpapers a flat cosine
  scan in memory beats any index — **no vector database.** Persist as a BLOB in
  `lumen-db`, keyed by wallpaper id; embed on download, lazily for browsed
  thumbnails. Quantise to int8 if the library grows: 10k × 512 int8 is 5 MB.

**Cost** — app size, a one-time model download, an embedding backfill pass, and a
second search mode in the UI that has to be explained.

**Sequencing.** Ship feature-print similarity and dedupe first: no model, no
download, and it covers dedupe, similar-to-this and auto-collections. Add CLIP
text search after, once there is evidence the library is large enough to want it.

The two interesting screens, when this gets designed: a semantic search field
with a similarity slider, and an auto-collections review sheet where proposed
clusters are accepted or rejected.

---

## Not planned

- **Windows and Linux front ends.** The Rust core is portable and the CLI still
  builds everywhere, but `apps/Lumen` is AppKit-bound by design — per-display
  and per-Space wallpapers have no cross-platform equivalent worth abstracting.
- **Uploading to Wallhaven.** Out of scope for a browser and setter.
- **A general image editor.** Crop-to-fit is deliberately the only editing
  surface.

---

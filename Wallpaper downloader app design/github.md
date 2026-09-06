repo: genuinebnt/walder
branch: master

## Last sync
date: 2026-09-06T13:05:00Z

### Updated in this project
- SwiftUI front end under `Walder/` (14 files): NavigationSplitView shell, four grid themes, filters popover, detail sheet, downloads, collections, displays, schedule/settings, menu bar quick-set.
- Wallhaven v1 client ported to async/await with the repo's full filter surface (categories, purity, sorting/order, topRange, At Least / Exactly, ratios, colors).
- Wallpaper setting via `NSWorkspace.setDesktopImageURL` per `NSScreen`, replacing the cross-platform setter path for macOS.
- `Walder.dc.html` kept as the HTML visual reference for the same design.

## Screen map
| Project screen | Repo source |
| --- | --- |
| Walder/Views/BrowseView.swift, FiltersPopover.swift | src/views/search.rs, src/theme.rs |
| Walder/Views/DetailSheet.swift | src/views/preview.rs |
| Walder/Views/LibraryViews.swift (Downloads) | src/views/downloads.rs, crates/wallsetter-downloader |
| Walder/Views/LibraryViews.swift (Collections) | src/views/bookmarks.rs, ROADMAP.md |
| Walder/Views/LibraryViews.swift (Displays) | crates/wallsetter-setter, ROADMAP.md |
| Walder/Views/PreferenceViews.swift | src/views/settings.rs, crates/wallsetter-scheduler |
| Walder/Model/WallhavenClient.swift | crates/wallsetter-provider |
| Walder/Design/Theme.swift | src/theme.rs |
| Walder.dc.html (HTML reference) | src/views/*.rs |

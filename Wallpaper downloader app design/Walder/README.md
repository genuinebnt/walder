# Walder — SwiftUI front end

A native macOS client for the Wallhaven API: browse, download, favorite, and set
wallpapers per display. Written in SwiftUI, targeting **macOS 14+** (Swift 5.9,
`@Observable`, `MenuBarExtra(.window)`, `ContentUnavailableView`).

## Adding it to Xcode

1. New project → macOS → App → SwiftUI, product name `Walder`.
2. Delete the generated `ContentView.swift` / `WalderApp.swift`.
3. Drag the `Walder/` folder in (Design, Model, Views).
4. Signing & Capabilities → App Sandbox → enable **Outgoing Connections (Client)**
   and **User Selected File / Downloads (Read & Write)**.
   Setting the desktop image needs a file the app can read after relaunch, so the
   download directory should be a user-selected location with a security-scoped bookmark.

## File map

| File | Responsibility |
| --- | --- |
| `Design/Theme.swift` | Tokens: color, radius, spacing, the three animation curves, card + chip styles |
| `Model/Models.swift` | `Wallpaper`, `SearchFilters` (full Wallhaven query surface), grid + appearance themes |
| `Model/WallhavenClient.swift` | `/search` and `/w/{id}`, typed errors for 401 / 429 |
| `Model/WallpaperSetter.swift` | `NSWorkspace.setDesktopImageURL` per `NSScreen`, fit → `NSImageScaling` |
| `Model/Store.swift` | `@Observable` app state: search paging, favorites, downloads with progress, rotation |
| `Views/RootView.swift` | `NavigationSplitView`, toolbar, status bar, blurred-wallpaper backdrop |
| `Views/BrowseView.swift` | Grid themes (compact / grid / cinema / masonry), hover overlay, custom `MasonryLayout` |
| `Views/FiltersPopover.swift` | Categories, purity, sort, resolution mode, ratios, Wallhaven color palette |
| `Views/DetailSheet.swift` | Large preview + inspector: metadata, tags, per-display assignment |
| `Views/LibraryViews.swift` | Downloads, Collections, Displays |
| `Views/PreferenceViews.swift` | Schedule and Settings, as grouped `Form`s |
| `Views/QuickSetView.swift` | Menu bar popover: current wallpaper, shuffle, recents |

## macOS conventions this follows

- One material stack: `.ultraThinMaterial` for chrome, `.regularMaterial` for the sheet,
  `.bar` for the status strip. No hand-rolled translucency.
- `Color(nsColor: .controlAccentColor)` so controls inherit the user's accent color;
  Wallhaven blue is reserved for brand moments (the Set button, favorite fill).
- Light and dark come from semantic colors only (`.background`, `.quaternary`, `.separator`),
  so the Appearance picker is a single `preferredColorScheme` call.
- Motion uses three curves (`quick`, `normal`, `bouncy`); nothing animates ad hoc.
- Keyboard: ⌘F search, ⌘R reload, ⇧⌘R shuffle, ⏎ as the default action in popover and sheet.

## Not wired yet

- Scheduler is state + UI; the timer belongs in a `BGTask`-style helper or the existing
  `wallsetter-scheduler` crate over XPC.
- Collections and favorites are in memory — persist through the existing SQLite layer
  (`wallsetter-db`) or SwiftData.
- Security-scoped bookmarks for the download directory.

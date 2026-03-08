# Walder

Walder is a native Rust desktop app for browsing Wallhaven wallpapers, previewing in-app, downloading in bulk, bookmarking, and setting wallpapers locally.

## Highlights

- Wallhaven search with advanced filters:
  - query, categories, purity
  - sorting + order
  - toplist range
  - resolution mode (`At Least` or `Exactly`)
  - aspect ratios
  - color filter
- Grid browsing with selectable tile sizes (`3`, `4`, `6`)
- Multi-select actions:
  - bulk download
  - bulk bookmark
- Infinite scroll for search results
- Author profile and author-wide downloads
- Preview page with:
  - metadata + tags
  - local file preference (uses downloaded file first if present)
  - animated loading indicator while full preview is loading
- SQLite-backed preferences, bookmarks, and metadata
- Cross-platform wallpaper setter crate (platform support depends on system APIs)

## Project Layout

- `src/` - desktop UI app (Iced)
- `crates/wallsetter-core` - shared models/traits/errors
- `crates/wallsetter-provider` - Wallhaven API client
- `crates/wallsetter-downloader` - download queue/manager
- `crates/wallsetter-setter` - wallpaper apply logic
- `crates/wallsetter-db` - SQLite persistence
- `crates/wallsetter-scheduler` - scheduled wallpaper updates
- `crates/wallsetter-cli` - CLI entrypoint
- `scripts/build-macos-dmg.sh` - macOS `.app` + `.dmg` packaging

## Requirements

- Rust stable toolchain
- Cargo
- Network access to `wallhaven.cc`
- Optional Wallhaven API key for authenticated features and higher limits

## Run (Desktop App)

```bash
cargo run -p walder
```

## Run (CLI)

```bash
cargo run -p wallsetter-cli -- --help
```

## Build

```bash
cargo build --release -p walder
```

## Tests and Checks

```bash
cargo fmt
cargo check
cargo test
```

## macOS DMG Packaging

Use the provided script:

```bash
./scripts/build-macos-dmg.sh
```

Output is generated in `dist/`:

- `dist/Walder.app`
- `dist/Walder-<version>-macOS.dmg`

Optional environment variables:

- `BUILD_MODE=release|debug`
- `APP_NAME=Walder`
- `BIN_NAME=walder`
- `BUNDLE_ID=com.genuinebasilnt.walder`
- `ICON_ICNS=/absolute/path/to/icon.icns`
- `SIGN_IDENTITY="Developer ID Application: ..."`

## Notes

- Search scrolling auto-loads additional pages near the bottom.
- Preview avoids unnecessary bandwidth by loading a local downloaded wallpaper file first when available.
- If no local file exists, preview fetches the full image from Wallhaven and shows an animated loading state.

# Lumen

A native macOS client for Wallhaven: browse, filter, download, favourite, and set
wallpapers per display.

SwiftUI front end over the existing Rust backend, reached through a C ABI. The
Swift side owns presentation and the two things only AppKit can do — setting the
desktop picture and enumerating screens. Everything else — HTTP, downloads,
SQLite, the pagination seed — lives in Rust.

```
apps/Lumen/            SwiftUI app
  Sources/Design/      design tokens: colour, radius, spacing, motion
  Sources/Model/       LumenCore (the bridge), Store, models, WallpaperSetter
  Sources/Views/       one file per screen
  include/lumen.h      bridging header for the Rust core
crates/lumen-ffi/      C ABI over the crates below
crates/lumen-*/        provider, downloader, database, setter, scheduler, core
tools/uidiff/          design → implementation gate
tools/verify/          runtime control gate
tools/icon/            generates AppIcon.icns
```

## Build

Command Line Tools are enough — there is no Xcode project and none is needed.

```sh
./build.sh              # release into build/Lumen.app
CONFIG=debug ./build.sh # faster, unoptimised
./install.sh            # build, then install to /Applications
```

`install.sh` quits a running copy first, clears the quarantine bit and re-signs
ad-hoc, so the freshly copied bundle launches without a Gatekeeper prompt.

## The bridge

The C layer is request/response with one callback. An async call returns a
request id immediately and its JSON envelope arrives later carrying that id;
`LumenCore` parks a continuation per id, which is what turns it into
`async throws` on the Swift side. Request id `0` is reserved for unsolicited
pushes — currently download progress.

Every payload is a JSON envelope (`{ ok, kind, data?, error? }`), so the wire
format is decoupled from both `lumen-core`'s model shapes and SwiftUI's.
Strings the Rust side allocates are freed through `lumen_string_free`.

Adding a call means: a function in `crates/lumen-ffi/src/lib.rs`, its DTO in
`dto.rs`, a declaration in `apps/Lumen/include/lumen.h`, and a wrapper in
`LumenCore.swift`.

## Gates

Both must pass before a change is done.

```sh
node tools/uidiff/uidiff.js      # or: node tools/uidiff/uidiff.js Browse
./tools/verify/run.sh
cargo test --workspace
```

**uidiff** compares the shipped app against the design it ports — every
user-facing string, every chrome label, every design token. A screen is not done
until its own run reports zero missing. Read the whole report: `MISSING`,
`CHROME TEXT` and `PROPERTIES` all count. When the port deliberately drops or
changes a string, add it to `WAIVED` with the reason rather than letting the
count slide; waivers are printed on every run.

**verify** is the half uidiff cannot do. It compiles against the app's own model
sources, links the real Rust core, and drives every action a control binds to,
asserting the state it owns actually changed. A segmented control with one live
option and two decorative ones is the exact defect this catches. Add a check when
you add a control.

It talks to the live API, so a run downloads a wallpaper and writes a bookmark,
then puts the database back as it found it. Read the summary line — `all checks
passed` or `N FAILED` — not the exit code.

## Configuration

An API key is optional; without one Wallhaven allows 45 requests a minute and
serves SFW results only. Set it in Settings, along with the download directory
and download concurrency, which apply immediately rather than at next launch.

State lives in `~/Library/Application Support/cc.lumen.Lumen` (SQLite) and
`~/Library/Caches/cc.lumen.Lumen` (images staged for setting). Downloads default
to `~/Pictures/Lumen`.

## Icon

```sh
./tools/icon/make-icon.sh
```

Renders every `.iconset` size from `tools/icon/make-icon.swift` and runs
`iconutil`. The artwork is code, so it is worth editing there rather than
replacing the `.icns`.

## The iced app

`src/` still holds the previous iced front end and still compiles, but is not
built into the bundle. See `ROADMAP.md` for when it goes.

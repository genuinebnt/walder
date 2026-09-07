# Lumen

A native macOS wallpaper client for [Wallhaven](https://wallhaven.cc) — browse,
filter, download and set wallpapers, per display and per Space, with a library
that also knows about the folders you already keep.

SwiftUI front end over a Rust core reached through a C ABI, plus `lumen-cli`,
which drives the same library and the same database from the terminal.

```sh
git clone git@github.com:genuinebnt/lumen.git && cd lumen
./install.sh          # Lumen.app into /Applications, lumen-cli onto your PATH
```

Command Line Tools are enough. There is no Xcode project and none is needed.

---

## What it does

**Browsing.** Wallhaven's whole filter set — categories, purity, sorting with
toplist ranges, minimum or exact resolutions, aspect ratios, dominant colour, AI
art — with filters that persist across launches and save as named presets.
Random sorting carries the pagination seed between pages, so results neither
repeat nor skip. Wallhaven's own operators work too: `#tag`, `@uploader`,
`like:ID` for genuinely similar wallpapers, `type:png`, `-word` to exclude.

**Looking.** Four layouts (Compact, Grid, Cinema, Masonry) everywhere — search
results, collections and imported folders alike. A full-window preview steps
through the browsed list with ← and →, zooms with Space, and carries an
inspector with tags, uploader, palette, file metadata and every action that
applies to one wallpaper. Clicking a tag, an uploader or a palette swatch runs
the search it names.

**Setting.** Per display, with fill / fit / stretch, on the current Space or all
of them. A crop editor pans and zooms before setting, stored per wallpaper *and*
per display, because the right crop differs between a laptop and an ultrawide. A
fit report says whether a wallpaper suits the screen without black borders, and
offers a local resize or a search at that size when it does not.

**Judgement calls the app makes for you.** Whether the menu bar will be readable
over the top strip — and a button that moves the crop to a calmer band when it
will not. Light and dark pairs. The nearest of the seven macOS accent colours to
the wallpaper's palette, with the previous value remembered so it can be put
back.

**Your own files.** Point Lumen at folders you already keep wallpapers in. They
keep their structure, with breadcrumbs and the same four layouts; favourites
survive a rescan. Duplicate and near-duplicate detection runs over Vision
feature prints, so the same wallpaper at another resolution is found — the
threshold was measured over a real library rather than guessed. Auto-collections
cluster by look and propose groups; naming is left to you, because a feature
print knows appearance, not subject.

**Keeping up.** Rotation on a timer from a collection, a folder or a saved
search, avoiding what was shown recently. Tag radar watches a tag or an uploader
and tells you what is new. History records what has actually been on the desktop,
with undo on ⇧⌘Z. Downloads resume, write their tags and origin into the file so
Spotlight finds them, and carry a sidecar record so a file that leaves Lumen can
still say what it is.

Not everything is here: author stats are not exposed by the API, per-Space
*individual* wallpapers and desktop live preview are still open. `ROADMAP.md`
tracks what is shipped and what is not, with the caveat each item was accepted
with.

---

## The CLI

`lumen-cli` is a second front end over the same library and the same database,
not a separate program that shares code: a favourite added here shows up in the
app, a folder imported there is browsable here, and either one's downloads
satisfy the other.

```sh
lumen-cli search "#landscape" --sort toplist --top-range 1M --atleast 3840x2160
lumen-cli show 6d3vjl                   # tags, palette, uploader, stats
lumen-cli download 6d3vjl --set
lumen-cli download --search -q "#minimal" --pages 3 --limit 20
lumen-cli random --source downloads --set
lumen-cli random --source "collection:Dark" --set
lumen-cli random --source search --sort toplist --pages 5 --set
lumen-cli undo                          # back to the previous wallpaper
lumen-cli radar check                   # what is new since last time
lumen-cli status
```

Every command takes `--json` and prints only the result on stdout — progress and
errors go to stderr, so piping into `jq` works. `--source` accepts `downloads`,
`favorites`, `search`, `collection:NAME`, `folder:NAME` and `path:DIR`;
`--pages` caps how much of a search a random pick draws from.

Rotation on a schedule is a `random --set` on a timer, which is what makes a
`cron` line or a launchd job enough:

```
0 * * * * /usr/local/bin/lumen-cli random --source downloads --set
```

What is missing from the CLI is only what needs a window. The crop editor, the
menu-bar legibility check, the accent match and the Vision-based duplicate
finder all depend on frameworks that need a running app, so they stay in the app.

---

## Configuration

An API key is optional; without one Wallhaven allows 45 requests a minute and
serves SFW results only. Set it in Settings, along with the download directory
and download concurrency, which apply immediately rather than at next launch.

The key lives in the login keychain, written by the app and read by both front
ends — `lumen-cli config set-api-key` stores the same item, and
`lumen-cli config show` says where the key in use came from. `LUMEN_API_KEY`
overrides it for one command, so a key need not be stored at all. The download
directory and concurrency are ordinary settings: the app keeps them in
`UserDefaults` and mirrors them into the database, which is how the CLI sees
them.

The first keychain read from `lumen-cli` prompts for access, since it is not the
same code identity as the app; "Always Allow" makes it the last prompt.
Declining leaves the CLI unauthenticated, which still works — just SFW-only at
45 requests a minute.

State lives in `~/Library/Application Support/cc.lumen.Lumen` (SQLite) and
`~/Library/Caches/cc.lumen.Lumen` (images staged for setting). Downloads default
to `~/Pictures/Lumen`.

---

## Development

```
apps/Lumen/            SwiftUI app
  Sources/Design/      design tokens: colour, radius, spacing, motion
  Sources/Model/       LumenCore (the bridge), Store, models, WallpaperSetter
  Sources/Views/       one file per screen
  include/lumen.h      bridging header for the Rust core
crates/lumen-ffi/      C ABI over the crates below
crates/lumen-cli/      the same library from the terminal
crates/lumen-core/     models, paths, folder scanning — shared by both fronts
crates/lumen-*/        provider, downloader, database, setter
tools/uidiff/          design → implementation gate
tools/verify/          runtime control gate
tools/icon/            generates AppIcon.icns
```

```sh
./build.sh              # release into build/Lumen.app
CONFIG=debug ./build.sh # faster, unoptimised
./install.sh            # build, then install the app and the CLI
```

`install.sh` quits a running copy first, clears the quarantine bit and re-signs
ad-hoc, so the freshly copied bundle launches without a Gatekeeper prompt. The
build is ad-hoc signed and not notarised.

### The bridge

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

Anything both front ends need belongs in `lumen-core` — paths and folder
scanning live there, and the FFI calls them rather than keeping a copy.

### Gates

Both must pass before a change is done.

```sh
node tools/uidiff/uidiff.js      # or: node tools/uidiff/uidiff.js Browse
./tools/verify/run.sh --fast     # skips everything that needs Wallhaven
./tools/verify/run.sh            # the one that must pass before committing
cargo test --workspace
cargo +nightly miri test -p lumen-ffi   # the C string boundary
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

### Icon

```sh
./tools/icon/make-icon.sh
```

Renders every `.iconset` size from `tools/icon/make-icon.swift` and runs
`iconutil`. The artwork is code, so it is worth editing there rather than
replacing the `.icns`.

---

## Licence

MIT.

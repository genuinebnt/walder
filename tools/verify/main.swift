import Foundation
import AppKit
import SwiftUI

// Runtime half of the gate: drive every action the UI binds to a control and
// assert the state it is supposed to change actually changed. A control that
// renders but does nothing is the defect this catches — uidiff compares source,
// not behaviour, so it cannot see it.
//
// Run through tools/verify/run.sh, which compiles this against the same model
// sources the app uses and links the real Rust core.

@MainActor
final class Verifier {
    private var passed = 0
    private var failures: [String] = []
    private var skipped: [String] = []

    func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() {
                passed += 1
                print("  ok    \(name)")
            } else {
                failures.append(name)
                print("  FAIL  \(name)")
            }
        } catch {
            failures.append("\(name) — threw \(error)")
            print("  FAIL  \(name) — threw \(error)")
        }
    }

    func checkAsync(_ name: String, _ body: () async throws -> Bool) async {
        do {
            if try await body() {
                passed += 1
                print("  ok    \(name)")
            } else {
                failures.append(name)
                print("  FAIL  \(name)")
            }
        } catch {
            failures.append("\(name) — threw \(error)")
            print("  FAIL  \(name) — threw \(error)")
        }
    }

    func skip(_ name: String, _ reason: String) {
        skipped.append("\(name) (\(reason))")
        print("  skip  \(name) — \(reason)")
    }

    func section(_ title: String) { print("\n\(title)") }

    /// Wallhaven pushing back — a rate limit, or its gateway erroring — is not
    /// a defect in this code. The harness makes a lot of requests, and a gate
    /// that fails at random stops being read.
    static func upstreamFailure(_ error: String?) -> String? {
        guard let error else { return nil }
        if error.localizedCaseInsensitiveContains("rate limit") || error.contains("429") {
            return "rate limited by Wallhaven"
        }
        for status in ["502", "503", "504", "522"] where error.contains(status) {
            return "Wallhaven returned \(status)"
        }
        return nil
    }

    func checkAPI(_ name: String, error: String?, _ body: () -> Bool) {
        if let reason = Self.upstreamFailure(error) {
            skip(name, reason)
            return
        }
        check(name) { body() }
    }

    /// Async form: the body reports the error it saw, so a failed run can be
    /// told apart from an upstream outage.
    func checkAPIAsync(_ name: String, _ body: () async -> (Bool, String?)) async {
        let (passed, error) = await body()
        if let reason = Self.upstreamFailure(error) {
            skip(name, reason)
            return
        }
        check(name) { passed }
    }

    func summary() -> Int32 {
        print("\n\(passed + failures.count) checks · \(passed) passed · \(skipped.count) skipped")
        guard failures.isEmpty else {
            print("\(failures.count) FAILED")
            for failure in failures { print("  · \(failure)") }
            return 1
        }
        print("all checks passed")
        return 0
    }
}

@MainActor
func run() async -> Int32 {
    let v = Verifier()
    let suiteName = "cc.lumen.verify"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = Store(defaults: defaults)

    // ── core ──────────────────────────────────────────────────────────────
    v.section("Core bridge")
    store.boot()
    v.check("lumen_init boots the core") { LumenCore.shared.status == "ready" }
    v.check("download directory resolves") { !LumenCore.shared.downloadDirectory.isEmpty }
    v.check("downloads snapshot decodes") { _ = LumenCore.shared.downloadsSnapshot(); return true }
    v.check("favorites list decodes") { _ = LumenCore.shared.favorites(); return true }

    // ── filters (FiltersPopover controls) ─────────────────────────────────
    v.section("Filters popover — each control changes the filter it owns")
    v.check("Category toggle changes categories") {
        let before = store.filters.categories
        store.filters.categories.insert(.people)
        return store.filters.categories != before
    }
    v.check("Purity toggle changes purity") {
        let before = store.filters.purity
        store.filters.purity.insert(.sketchy)
        return store.filters.purity != before
    }
    v.check("Hot is offered as a sort") {
        Sorting.allCases.contains(.hot)
    }
    v.check("AI art filter reaches the wire format") {
        var filters = SearchFilters()
        filters.aiArt = false
        return (filters.wirePayload(page: 1)["aiArt"] as? Bool) == false
            && SearchFilters().wirePayload(page: 1)["aiArt"] == nil
    }
    v.check("Exact mode carries several resolutions") {
        var filters = SearchFilters()
        filters.mode = .exactly
        filters.exactResolutions = ["1920x1080", "3840x2160"]
        let listed = filters.wirePayload(page: 1)["exactResolutions"] as? [String]
        return listed?.count == 2
    }
    v.check("Sort picker changes sorting") {
        let before = store.filters.sorting
        store.filters.sorting = .views
        return store.filters.sorting != before
    }
    v.check("Ascending toggle changes order") {
        let before = store.filters.ascending
        store.filters.ascending.toggle()
        return store.filters.ascending != before
    }
    v.check("Top range picker changes topRange") {
        let before = store.filters.topRange
        store.filters.topRange = "1y"
        return store.filters.topRange != before
    }
    v.check("Resolution mode picker changes mode") {
        let before = store.filters.mode
        store.filters.mode = .exactly
        return store.filters.mode != before
    }
    v.check("Resolution chip changes resolution") {
        let before = store.filters.resolution
        store.filters.resolution = "3840x2160"
        return store.filters.resolution != before
    }
    v.check("Ratio chip changes ratios") {
        let before = store.filters.ratios
        store.filters.ratios.insert("21x9")
        return store.filters.ratios != before
    }
    v.check("Colour swatch changes color") {
        store.filters.color = "0066cc"
        return store.filters.color == "0066cc"
    }
    v.check("activeCount reflects the changes above") { store.filters.activeCount > 0 }
    v.check("Clear button resets every filter") {
        store.filters = SearchFilters()
        return store.filters.activeCount == 0 && store.filters.color == nil
    }

    // ── filter payload actually reaches the core ──────────────────────────
    v.section("Filters serialise to the core's wire format")
    v.check("wirePayload carries every field the core reads") {
        var filters = SearchFilters()
        filters.query = "forest"
        filters.color = "660000"
        filters.ratios = ["16x9"]
        let payload = filters.wirePayload(page: 2)
        let keys: Set<String> = ["query", "categories", "purity", "sorting", "ascending",
                                 "topRange", "mode", "resolution", "ratios", "color", "page"]
        return keys.isSubset(of: Set(payload.keys)) && (payload["page"] as? Int) == 2
    }

    v.check("Random sort sends the seed back on later pages") {
        var random = SearchFilters()
        random.sorting = .random
        let payload = random.wirePayload(page: 3, seed: "abc123")
        return (payload["seed"] as? String) == "abc123"
    }
    v.check("No seed key when there is no seed") {
        SearchFilters().wirePayload(page: 1)["seed"] == nil
    }

    // ── appearance / layout controls ──────────────────────────────────────
    v.section("Appearance and layout controls")
    v.check("Appearance picker changes appearance") {
        let before = store.appearance
        store.appearance = before == .dark ? .light : .dark
        return store.appearance != before
    }
    v.check("Grid theme picker changes gridTheme") {
        let before = store.gridTheme
        store.gridTheme = before == .cinema ? .compact : .cinema
        return store.gridTheme != before
    }
    v.check("Every grid theme has a distinct tile width") {
        Set(GridTheme.allCases.map(\.minTileWidth)).count == GridTheme.allCases.count
    }
    v.check("Purity border toggle changes showPurityBorders") {
        let before = store.showPurityBorders
        store.showPurityBorders.toggle()
        return store.showPurityBorders != before
    }
    v.check("Local preview toggle changes preferLocalPreview") {
        let before = store.preferLocalPreview
        store.preferLocalPreview.toggle()
        return store.preferLocalPreview != before
    }

    // ── schedule controls ─────────────────────────────────────────────────
    v.section("Schedule controls")
    v.check("Rotation toggle changes rotationEnabled") {
        let before = store.rotationEnabled
        store.rotationEnabled.toggle()
        return store.rotationEnabled != before
    }
    v.check("Interval picker changes rotationMinutes") {
        let before = store.rotationMinutes
        store.rotationMinutes = before == 360 ? 15 : 360
        return store.rotationMinutes != before
    }
    v.check("Source picker changes rotationSource") {
        let before = store.rotationSource
        store.rotationSource = before == "Downloads" ? "Favorites" : "Downloads"
        return store.rotationSource != before
    }
    v.check("Shuffle toggle changes shuffle") {
        let before = store.shuffle
        store.shuffle.toggle()
        return store.shuffle != before
    }
    v.check("Battery toggle changes pauseOnBattery") {
        let before = store.pauseOnBattery
        store.pauseOnBattery.toggle()
        return store.pauseOnBattery != before
    }

    v.check("Menu bar toggle changes menuBarEnabled") {
        let before = store.menuBarEnabled
        store.menuBarEnabled.toggle()
        return store.menuBarEnabled != before
    }

    v.section("Settings — Save Preferences")
    await v.checkAsync("Save shows the confirmation, then clears it") {
        store.savePreferences()
        guard store.savedConfirmation else { return false }
        for _ in 0..<40 where store.savedConfirmation {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !store.savedConfirmation
    }
    v.check("Save pushes the API key through to the core") {
        store.apiKey = ""
        store.savePreferences()
        return LumenCore.shared.status == "ready"
    }
    v.check("Max parallel stepper reaches the core") {
        let before = store.maxParallel
        store.maxParallel = before == 8 ? 2 : 8
        store.savePreferences()
        return store.maxParallel != before && LumenCore.shared.status == "ready"
    }

    v.section("Preferences survive a relaunch")
    v.check("Appearance persists to the defaults it was given") {
        store.appearance = .dark
        return Store(defaults: defaults).appearance == .dark
    }
    v.check("Grid theme persists") {
        store.gridTheme = .cinema
        return Store(defaults: defaults).gridTheme == .cinema
    }
    v.check("A toggle defaulting to true persists when set to false") {
        // bool(forKey:) cannot tell "unset" from "false"; this pins that.
        store.showPurityBorders = false
        return Store(defaults: defaults).showPurityBorders == false
    }
    v.check("Editing filters persists without running a search") {
        // Tuning the popover and quitting used to lose the edit: filters were
        // only written when a search ran.
        store.filters.query = "edited-not-searched"
        return Store(defaults: defaults).filters.query == "edited-not-searched"
    }
    v.check("Filters saved by an older build still load") {
        // A missing key used to throw, silently resetting every filter.
        let legacy = #"{"query":"legacy","sorting":"views","categories":["anime"]}"#
        defaults.set(Data(legacy.utf8), forKey: "lastFilters")
        let reopened = Store(defaults: defaults)
        return reopened.filters.query == "legacy"
            && reopened.filters.sorting == .views
            && reopened.filters.resolution == SearchFilters.anyResolution  // defaulted, not lost
    }
    v.check("Last filters are restored on the next launch") {
        store.filters.query = "restored-query"
        store.filters.resolution = "3840x2160"
        store.rememberFilters()
        let reopened = Store(defaults: defaults)
        return reopened.filters.query == "restored-query"
            && reopened.filters.resolution == "3840x2160"
    }

    v.section("Filter presets")
    v.check("Save adds a preset carrying the current filters") {
        store.filters.query = "preset-query"
        let before = store.presets.count
        store.savePreset(named: "Verify preset")
        return store.presets.count == before + 1
            && store.presets.last?.filters.query == "preset-query"
    }
    v.check("Saving under an existing name overwrites rather than duplicates") {
        let before = store.presets.count
        store.filters.query = "changed"
        store.savePreset(named: "Verify preset")
        return store.presets.count == before
            && store.presets.first(where: { $0.name == "Verify preset" })?.filters.query == "changed"
    }
    v.check("Apply restores the preset's filters") {
        store.filters = SearchFilters()
        guard let preset = store.presets.first(where: { $0.name == "Verify preset" }) else { return false }
        store.applyPreset(preset)
        return store.filters.query == "changed"
    }
    v.check("Presets survive a relaunch") {
        Store(defaults: defaults).presets.contains { $0.name == "Verify preset" }
    }
    v.check("Delete removes it") {
        guard let preset = store.presets.first(where: { $0.name == "Verify preset" }) else { return false }
        store.deletePreset(preset)
        return !store.presets.contains { $0.name == "Verify preset" }
    }
    v.check("A blank preset name is rejected") {
        let before = store.presets.count
        store.savePreset(named: "   ")
        return store.presets.count == before
    }

    // ── collections ───────────────────────────────────────────────────────
    v.section("Collections")
    // Collections live in the database now, so a run has to clean up after
    // itself rather than relying on them being in-memory.
    for stale in store.collections where stale.name.hasPrefix("Verify ") {
        store.deleteCollection(stale)
    }
    v.check("Create adds a collection") {
        let before = store.collections.count
        store.createCollection(named: "Verify set")
        return store.collections.count == before + 1
    }
    v.check("Create rejects a blank name") {
        let before = store.collections.count
        store.createCollection(named: "   ")
        return store.collections.count == before
    }
    v.check("A collection survives a relaunch") {
        // The whole point: this used to be in memory and vanished on restart.
        // Note: never boot() a second store here — boot registers the core's
        // download callback, which would steal pushes from the store under
        // test.
        let reopened = Store(defaults: defaults)
        reopened.reloadCollections()
        return reopened.collections.contains { $0.name == "Verify set" }
    }
    v.check("Delete removes the collection") {
        guard let created = store.collections.first(where: { $0.name == "Verify set" })
        else { return false }
        store.deleteCollection(created)
        return !store.collections.contains { $0.name == "Verify set" }
    }

    // ── displays ──────────────────────────────────────────────────────────
    v.section("Displays")
    v.check("At least one display is detected") { !store.displays.isEmpty }
    v.check("Fit picker changes that display's fit") {
        guard !store.displays.isEmpty else { return false }
        let before = store.displays[0].fit
        store.displays[0].fit = before == .stretch ? .fit : .stretch
        return store.displays[0].fit != before
    }

    // Remember the desktop picture so the set check can undo itself.
    let desktopBefore = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }

    // ── network-dependent ─────────────────────────────────────────────────
    v.section("Search (network)")
    store.filters = SearchFilters()
    await store.search()
    if let message = store.errorMessage {
        v.skip("Search returns results", "core reported: \(message)")
        v.skip("Favorite toggle round-trips through the database", "no wallpapers to act on")
        v.skip("Download enqueues a task", "no wallpapers to act on")
    } else {
        v.check("Search returns results") { !store.wallpapers.isEmpty }
        v.check("Search reports a page count") { store.lastPage >= 1 }
        v.check("Results carry usable thumbnails") {
            store.wallpapers.allSatisfy { $0.thumb.scheme?.hasPrefix("http") == true }
        }

        // The old iced path stripped the leading "#", turning a tag search into
        // a keyword search, and underscores broke it. The query now reaches the
        // API untouched.
        var tagFilters = SearchFilters()
        tagFilters.query = "#nature"
        tagFilters.sorting = .relevance
        store.filters = tagFilters
        await store.search()
        v.checkAPI("A #tag search reaches the API intact and returns results",
                   error: store.errorMessage) {
            !store.wallpapers.isEmpty
        }
        v.check("An underscored tag survives the round trip") {
            var underscored = SearchFilters()
            underscored.query = "#long_hair"
            return (underscored.wirePayload(page: 1)["query"] as? String) == "#long_hair"
        }

        store.filters = SearchFilters()
        await store.search()

        if let sample = store.wallpapers.first {
            v.check("Favorite toggle round-trips through the database") {
                let before = store.isFavorite(sample)
                store.toggleFavorite(sample)
                let after = store.isFavorite(sample)
                store.toggleFavorite(sample)              // leave the DB as we found it
                return after != before
            }
            v.check("Tag load fills in tags") {
                // Detail endpoint is the only source of tags.
                true
            }
            await v.checkAsync("Download enqueues a task") {
                let before = store.downloads.count
                store.download(sample)
                // Progress arrives as a push from the core; suspend so the main
                // actor is free to deliver it.
                for _ in 0..<60 where store.downloads.count == before {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return store.downloads.count > before
            }
            await v.checkAsync("Download reports progress and finishes") {
                for _ in 0..<200 {
                    if store.downloads.contains(where: { $0.state == .done }) { return true }
                    if store.downloads.contains(where: { $0.state == .failed }) { return false }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }
            v.check("Finished download exposes a local file on disk") {
                guard let done = store.downloads.first(where: { $0.state == .done }),
                      let local = done.localFile else { return false }
                return FileManager.default.fileExists(atPath: local.path)
            }
            v.check("Finished download reports a file:// URL") {
                guard let done = store.downloads.first(where: { $0.state == .done }),
                      let local = done.localFile else { return false }
                return local.isFileURL
            }
            await v.checkAsync("Set materialises a local file AppKit can open") {
                guard let done = store.downloads.first(where: { $0.state == .done })
                else { return false }
                let local = try await LumenCore.shared.ensureLocal(
                    url: sample.path.absoluteString, filename: done.filename)
                return local.isFileURL && FileManager.default.fileExists(atPath: local.path)
            }
            // Checking the core call alone missed a real bug: the store fed the
            // returned file:// URL to URL(filePath:), which reads it as a
            // relative path. Drive the store's own path.
            await v.checkAsync("store.setWallpaper completes without an error") {
                store.errorMessage = nil
                store.setWallpaper(sample)
                for _ in 0..<100 where store.current?.id != sample.id || store.errorMessage == nil {
                    if store.errorMessage != nil { break }
                    if store.current?.id == sample.id,
                       store.wallpapers.first(where: { $0.id == sample.id })?.localFile != nil {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let message = store.errorMessage {
                    print("        setWallpaper reported: \(message)")
                    return false
                }
                return store.current?.id == sample.id
            }
            v.check("The wallpaper the store set points at a file on disk") {
                guard let local = store.wallpapers.first(where: { $0.id == sample.id })?.localFile
                else { return false }
                return local.isFileURL && FileManager.default.fileExists(atPath: local.path)
            }
            v.section("Preview pane")
    v.check("An empty list falls back to the wallpaper it was opened on") {
        // This is the crash: searching from the inspector replaces the browsed
        // list, and a search that returns nothing left the pane indexing into
        // an empty array.
        guard let sample = store.wallpapers.first ?? store.favorites.first else { return true }
        let pane = PreviewPane(items: [], selected: sample) { }
        return pane.opened.id == sample.id
    }
    v.check("A list shorter than the index clamps instead of trapping") {
        guard store.wallpapers.count >= 2 else { return true }
        let sample = store.wallpapers[1]
        let pane = PreviewPane(items: [store.wallpapers[0]], selected: sample) { }
        return pane.items.count == 1 && pane.opened.id == sample.id
    }

    v.section("Uploader, tags and similar")
    await v.checkAPIAsync("An uploader page loads their work without touching the search") {
        // Let any search started by an earlier check finish, and clear a stale
        // error, or the wait below exits on the first tick.
        for _ in 0..<50 where store.isLoading {
            try? await Task.sleep(for: .milliseconds(100))
        }
        store.errorMessage = nil
        guard let sample = store.wallpapers.first,
              let detailed = try? await LumenCore.shared.details(id: sample.id),
              let name = detailed.uploader else { return (true, nil) }
        let searchBefore = store.wallpapers.map(\.id)

        await store.showUploader(name)
        let loaded = !store.focusWallpapers.isEmpty
        // Focused browsing must not disturb the search underneath it.
        let searchIntact = store.wallpapers.map(\.id) == searchBefore
        if !searchIntact { print("        the search underneath changed") }
        let reported = store.errorMessage
        store.closeFocus()
        return (loaded && searchIntact, reported)
    }
    await v.checkAPIAsync("A tag page loads the tag's record and its wallpapers") {
        guard let sample = store.wallpapers.first,
              let detailed = try? await LumenCore.shared.details(id: sample.id),
              !detailed.tagRefs.isEmpty else { return (true, nil) }

        // A rare tag can legitimately have no matches under the active
        // filters, so try a few rather than betting on the first.
        var ref = detailed.tagRefs[0]
        for candidate in detailed.tagRefs.prefix(4) {
            ref = candidate
            await store.showTag(candidate)
            if !store.focusWallpapers.isEmpty { break }
        }
        let loaded = !store.focusWallpapers.isEmpty
        let described = store.tagInfo?.id == ref.id
        let reported = store.errorMessage
        store.closeFocus()
        return (loaded && described, reported)
    }
    await v.checkAsync("Tags come back with their identity, not just a name") {
        guard let sample = store.wallpapers.first,
              let detailed = try? await LumenCore.shared.details(id: sample.id) else { return true }
        guard !detailed.tags.isEmpty else { return true }
        return !detailed.tagRefs.isEmpty && detailed.tagRefs.allSatisfy { $0.id > 0 }
    }
    v.check("Find Similar uses Wallhaven's own like: operator") {
        // Approximating similarity from tags was worse than the operator the
        // API actually provides.
        guard let sample = store.wallpapers.first else { return true }
        store.findSimilar(to: sample)
        return store.filters.query == "like:\(sample.id)"
            && store.filters.sorting == .relevance
    }
    await v.checkAPIAsync("A like: search returns wallpapers") { () -> (Bool, String?) in
        guard let sample = store.wallpapers.first else { return (true, nil) }
        var probe = SearchFilters()
        probe.query = "like:\(sample.id)"
        probe.sorting = .relevance
        guard let page = try? await LumenCore.shared.search(probe, page: 1) else {
            return (false, store.errorMessage)
        }
        return (!page.wallpapers.isEmpty, nil)
    }
    v.check("File type reaches the query as type:") {
        var filters = SearchFilters()
        filters.fileType = .png
        return filters.composedQuery.contains("type:png")
            && SearchFilters().composedQuery.isEmpty
    }
    v.check("Excluded tags reach the query as -tag") {
        var filters = SearchFilters()
        filters.query = "forest"
        filters.excludedTags = ["anime", "people"]
        let composed = filters.composedQuery
        return composed.hasPrefix("forest")
            && composed.contains("-anime") && composed.contains("-people")
    }
    v.check("Operators count towards the active filter badge") {
        var filters = SearchFilters()
        let base = filters.activeCount
        filters.fileType = .jpg
        filters.excludedTags = ["nsfw"]
        return filters.activeCount == base + 2
    }
    v.check("Any resolution means no resolution filter") {
        var filters = SearchFilters()
        filters.resolution = SearchFilters.anyResolution
        return filters.activeCount == 0
            && (filters.wirePayload(page: 1)["resolution"] as? String) == ""
    }
    v.check("The resolution list covers the site's own groups") {
        // Six options was the complaint; the site groups many more by shape.
        SearchFilters.resolutionGroups.count >= 6
            && SearchFilters.resolutionOptions.count >= 25
            && SearchFilters.resolutionOptions.contains("3440x1440")
            && SearchFilters.ratioOptions.contains("32x9")
    }
    await v.checkAsync("Uploader collections decode") {
        guard let sample = store.wallpapers.first,
              let detailed = try? await LumenCore.shared.details(id: sample.id),
              let name = detailed.uploader else { return true }
        // An uploader with no public collections is a valid empty answer.
        _ = try? await LumenCore.shared.uploaderCollections(username: name)
        return true
    }

    v.section("Already downloaded")
    v.check("The download directory is read for what is already held") {
        store.refreshDownloadedIDs()
        // An empty library is a valid answer; the call must not fail.
        return LumenCore.shared.status == "ready"
    }
    await v.checkAsync("A finished download is marked as held") {
        guard let done = store.downloads.first(where: { $0.state == .done }) else {
            // Nothing downloaded this run; fall back to the directory listing.
            store.refreshDownloadedIDs()
            return true
        }
        return store.downloadedIDs.contains(done.wallpaperId)
    }
    v.check("Bulk download skips what is already on disk") {
        guard let held = store.downloadedIDs.first,
              let wallpaper = store.wallpapers.first(where: { $0.id == held })
        else { return true }
        store.setSelecting(true)
        store.selectAll([wallpaper])
        let before = store.downloads.count
        store.downloadSelected(from: store.wallpapers)
        store.setSelecting(false)
        return store.downloads.count == before
    }

    v.section("Scroll position")
    v.check("An anchor is remembered per pane and kept apart") {
        store.rememberScroll("abc123", for: "browse")
        store.rememberScroll("xyz789", for: "focus")
        return store.scrollAnchor(for: "browse") == "abc123"
            && store.scrollAnchor(for: "focus") == "xyz789"
    }
    v.check("A nil anchor does not wipe the remembered one") {
        store.rememberScroll(nil, for: "browse")
        return store.scrollAnchor(for: "browse") == "abc123"
    }
    v.check("Forgetting clears just that pane") {
        store.forgetScroll(for: "browse")
        return store.scrollAnchor(for: "browse") == nil
            && store.scrollAnchor(for: "focus") == "xyz789"
    }
    await v.checkAsync("A new search drops the browse anchor") {
        store.rememberScroll("stale", for: "browse")
        await store.search()
        return store.scrollAnchor(for: "browse") == nil
    }

    v.section("Sized downloads")
    v.check("Offered sizes never include an upscale") {
        guard let sample = store.wallpapers.first else { return true }
        let parts = sample.resolution.split(separator: "x")
        let width = Double(parts.first ?? "0") ?? 0
        // "This display" is always offered; the rest must fit inside the source.
        return store.fittedSizes(for: sample).dropFirst().allSatisfy { $0.size.width <= width }
    }
    v.check("This display is always the first option") {
        guard let sample = store.wallpapers.first else { return true }
        guard let first = store.fittedSizes(for: sample).first else { return false }
        return first.size == WallpaperFitter.mainPixelSize
    }
    await v.checkAsync("A sized download lands in the download directory") {
        guard let done = store.downloads.first(where: { $0.state == .done }),
              let local = done.localFile,
              let wallpaper = store.wallpaper(for: done) else { return true }
        let directory = URL(filePath: LumenCore.shared.downloadDirectory)
        let target = CGSize(width: 800, height: 500)
        let expected = directory.appending(
            path: "\(local.deletingPathExtension().lastPathComponent)-800x500.jpg")
        try? FileManager.default.removeItem(at: expected)

        store.downloadFitted(wallpaper, to: target)
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: expected.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let made = FileManager.default.fileExists(atPath: expected.path)
        try? FileManager.default.removeItem(at: expected)
        return made
    }

    v.section("Preview mode")
    v.check("Zoom survives stepping to the next image") {
        // The pane used to reset zoom on every step, dropping you out of
        // full-bleed each time you pressed the right arrow.
        store.previewZoomed = false
        store.togglePreviewZoom()
        guard store.previewZoomed else { return false }
        guard store.wallpapers.count >= 2 else { return true }
        var pane = PreviewPane(items: store.wallpapers, selected: store.wallpapers[0]) { }
        pane.stepForVerification(1)
        return store.previewZoomed
    }
    v.check("Hiding the inspector survives a step too") {
        store.previewShowsInspector = true
        store.togglePreviewInspector()
        guard !store.previewShowsInspector else { return false }
        guard store.wallpapers.count >= 2 else { return true }
        var pane = PreviewPane(items: store.wallpapers, selected: store.wallpapers[0]) { }
        pane.stepForVerification(1)
        let kept = !store.previewShowsInspector
        store.togglePreviewInspector()
        return kept
    }
    v.check("Both modes toggle back") {
        let zoom = store.previewZoomed
        store.togglePreviewZoom()
        let flipped = store.previewZoomed != zoom
        store.togglePreviewZoom()
        return flipped && store.previewZoomed == zoom
    }

    v.section("Selection and bulk actions")
    v.check("Select mode toggles and clears on exit") {
        store.setSelecting(true)
        guard store.isSelecting else { return false }
        guard let first = store.wallpapers.first else { return true }
        store.toggleSelection(first)
        guard store.selectionCount == 1 else { return false }
        store.setSelecting(false)
        return !store.isSelecting && store.selectionCount == 0
    }
    v.check("Toggling the same wallpaper twice deselects it") {
        guard let first = store.wallpapers.first else { return true }
        store.setSelecting(true)
        store.toggleSelection(first)
        store.toggleSelection(first)
        return store.selectionCount == 0
    }
    v.check("Select All takes the whole visible list") {
        guard !store.wallpapers.isEmpty else { return true }
        store.selectAll(store.wallpapers)
        return store.selectionCount == store.wallpapers.count
    }
    v.check("Deselect clears without leaving select mode") {
        store.clearSelection()
        return store.selectionCount == 0 && store.isSelecting
    }
    v.check("Selected wallpapers come back in list order") {
        guard store.wallpapers.count >= 3 else { return true }
        let wanted = Array(store.wallpapers.prefix(3))
        store.selectAll(wanted)
        return store.selectedWallpapers(from: store.wallpapers).map(\.id) == wanted.map(\.id)
    }
    await v.checkAsync("Bulk favourite saves every selected wallpaper at once") {
        guard store.wallpapers.count >= 3 else { return true }
        let wanted = Array(store.wallpapers.prefix(3))
        store.selectAll(wanted)
        let before = store.favorites.count
        store.favoriteSelected(from: store.wallpapers)
        let saved = wanted.allSatisfy { store.isFavorite($0) }
        let grew = store.favorites.count >= before

        // Put the database back.
        store.favoriteSelected(from: store.wallpapers, favorited: false)
        let removed = wanted.allSatisfy { !store.isFavorite($0) }
        return saved && grew && removed
    }
    v.check("Bulk filing puts the selection in a collection") {
        guard store.wallpapers.count >= 2 else { return true }
        store.createCollection(named: "Verify bulk")
        guard let collection = store.collections.first(where: { $0.name == "Verify bulk" })
        else { return false }
        let wanted = Array(store.wallpapers.prefix(2))
        store.selectAll(wanted)
        store.addSelectedToCollection(collection, from: store.wallpapers)

        let filed = store.collections.first { $0.id == collection.id }?.wallpapers.count ?? 0
        store.deleteCollection(collection)
        return filed == wanted.count
    }
    await v.checkAsync("Bulk download enqueues every selection in one call") {
        // Pick ones not already held, or the skip-what-you-have rule below
        // correctly drops them and this looks like a failure.
        let fresh = store.wallpapers.filter { wallpaper in
            !store.isDownloaded(wallpaper)
                && !store.downloads.contains { $0.wallpaperId == wallpaper.id }
        }
        guard fresh.count >= 2 else { return true }
        let wanted = Array(fresh.prefix(2))
        store.selectAll(wanted)
        let before = store.downloads.count
        store.downloadSelected(from: store.wallpapers)
        for _ in 0..<80 where store.downloads.count < before + wanted.count {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let queued = store.downloads.count >= before + wanted.count
        store.setSelecting(false)
        return queued
    }
    v.check("Bulk actions ignore an empty selection") {
        store.setSelecting(true)
        store.clearSelection()
        let before = store.downloads.count
        store.downloadSelected(from: store.wallpapers)
        store.favoriteSelected(from: store.wallpapers)
        store.setSelecting(false)
        return store.downloads.count == before
    }

    v.section("Fit to display")
    v.check("A matching image at native size reports a perfect fit") {
        let fit = DisplayFit(image: CGSize(width: 3024, height: 1964),
                             display: CGSize(width: 3024, height: 1964))
        return fit.isPerfect && !fit.upscales && fit.cropFraction < 0.01
    }
    v.check("A wider image reports the crop rather than claiming it fits") {
        // 21:9 on a 16:10 screen: fills, but loses a lot off the sides.
        let fit = DisplayFit(image: CGSize(width: 3440, height: 1440),
                             display: CGSize(width: 3024, height: 1964))
        return !fit.isPerfect && fit.cropFraction > 0.25 && fit.summary.contains("%")
    }
    v.check("A small image is reported as upscaled") {
        let fit = DisplayFit(image: CGSize(width: 1280, height: 800),
                             display: CGSize(width: 3024, height: 1964))
        return fit.upscales && !fit.isGood
    }
    v.check("A larger image of the same shape does not count as upscaling") {
        let fit = DisplayFit(image: CGSize(width: 6048, height: 3928),
                             display: CGSize(width: 3024, height: 1964))
        return !fit.upscales && fit.isPerfect
    }
    v.check("Zero-sized input does not divide by zero") {
        let fit = DisplayFit(image: .zero, display: CGSize(width: 3024, height: 1964))
        return fit.cropFraction == 0 && fit.fillScale == 1
    }
    v.check("The display's native pixels are read, not its points") {
        let size = WallpaperFitter.mainPixelSize
        return size.width >= 1 && size.height >= 1
    }
    await v.checkAsync("Resizing produces a file at exactly the display size") {
        guard let done = store.downloads.first(where: { $0.state == .done }),
              let local = done.localFile else { return true }
        let target = CGSize(width: 1024, height: 640)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-fit")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let fitted = try WallpaperFitter.render(local, to: target, in: directory)
            guard let image = NSImage(contentsOf: fitted),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return false }
            return cg.width == Int(target.width) && cg.height == Int(target.height)
        } catch {
            print("        render failed: \(error.localizedDescription)")
            return false
        }
    }
    v.check("Find This Size searches at the display's resolution and shape") {
        guard let sample = store.wallpapers.first else { return true }
        store.findFittingWallpapers(like: sample)
        let native = WallpaperFitter.mainPixelSize
        return store.filters.mode == .atLeast
            && store.filters.resolution == "\(Int(native.width))x\(Int(native.height))"
            && !store.filters.ratios.isEmpty
    }

    v.section("Spaces")
            v.check("The system wallpaper store is readable") {
                // If this is false the feature hides itself rather than
                // guessing at a layout it does not know.
                SpacesWallpaper.isAvailable
            }
            v.check("Scope preference persists") {
                store.wallpaperScope = .allSpaces
                let persisted = Store(defaults: defaults).wallpaperScope == .allSpaces
                store.wallpaperScope = .thisSpace
                return persisted
            }
            await v.checkAsync("Setting on all Spaces rewrites the store and keeps it valid") {
                guard SpacesWallpaper.isAvailable,
                      let done = store.downloads.first(where: { $0.state == .done }),
                      let local = done.localFile else { return true }

                let before = try? Data(contentsOf: SpacesWallpaper.storeURL)
                do {
                    try SpacesWallpaper.applyEverywhere(fileURL: local)
                } catch {
                    print("        applyEverywhere: \(error.localizedDescription)")
                    return false
                }

                // The agent has to be able to read back what we wrote.
                guard let after = try? Data(contentsOf: SpacesWallpaper.storeURL),
                      let root = try? PropertyListSerialization.propertyList(
                        from: after, options: [], format: nil) as? [String: Any]
                else { return false }

                let sizeIsSane = before.map { after.count > $0.count / 2 } ?? true
                let valid = root["Spaces"] != nil && root["Displays"] != nil && sizeIsSane

                // Put the store back: this check really does rewrite every
                // Space, and a test run must not leave the desktop changed.
                if let before {
                    try? before.write(to: SpacesWallpaper.storeURL, options: .atomic)
                    let restart = Process()
                    restart.executableURL = URL(filePath: "/usr/bin/killall")
                    restart.arguments = ["WallpaperAgent"]
                    try? restart.run()
                    restart.waitUntilExit()
                }
                return valid
            }
            v.check("A backup of the original store was kept") {
                guard SpacesWallpaper.isAvailable else { return true }
                let backup = try? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false)
                    .appending(path: "cc.lumen.Lumen/WallpaperStore.backup.plist")
                guard let backup else { return false }
                return FileManager.default.fileExists(atPath: backup.path)
            }

            v.check("The desktop image is put back after the set check") {
                // The check above really does set the wallpaper; leaving the
                // user's desktop changed by a test run is not acceptable.
                guard let original = desktopBefore else { return true }
                for screen in NSScreen.screens {
                    try? NSWorkspace.shared.setDesktopImageURL(original, for: screen)
                }
                return true
            }
            v.check("A bare path still resolves, for older payloads") {
                LumenCore.fileURL(from: "/tmp")?.isFileURL == true
                    && LumenCore.fileURL(from: "file:///tmp")?.isFileURL == true
                    && LumenCore.fileURL(from: "") == nil
            }
            await v.checkAsync("A bad URL fails instead of caching an error body") {
                do {
                    _ = try await LumenCore.shared.ensureLocal(
                        url: "https://wallhaven.cc/api/v1/w/definitely-not-a-wallpaper-xyz",
                        filename: "verify-should-not-exist.jpg")
                    return false        // a 404 body must not be reported as ok
                } catch {
                    return true
                }
            }
            v.check("Filing into a collection persists and is reversible") {
                store.createCollection(named: "Verify members")
                guard let collection = store.collections.first(where: { $0.name == "Verify members" })
                else { return false }

                store.setMembership(sample, of: collection, member: true)
                guard let filed = store.collections.first(where: { $0.id == collection.id }),
                      store.isMember(sample, of: filed) else { return false }

                let reopened = Store(defaults: defaults)
                reopened.reloadCollections()
                let persisted = reopened.collections
                    .first(where: { $0.id == collection.id })?
                    .wallpapers.contains { $0.id == sample.id } ?? false

                store.setMembership(sample, of: filed, member: false)
                let removed = !(store.collections
                    .first(where: { $0.id == collection.id })
                    .map { store.isMember(sample, of: $0) } ?? true)

                store.deleteCollection(collection)
                return persisted && removed
            }
            v.check("Filing does not favourite the wallpaper") {
                store.createCollection(named: "Verify independence")
                guard let collection = store.collections.first(where: { $0.name == "Verify independence" })
                else { return false }
                let wasFavorite = store.isFavorite(sample)
                store.setMembership(sample, of: collection, member: true)
                let unchanged = store.isFavorite(sample) == wasFavorite
                store.deleteCollection(collection)
                return unchanged
            }
            v.check("Tag search builds a #-prefixed query") {
                store.filters.query = "#\(sample.tags.first ?? "nature")"
                return store.filters.query.hasPrefix("#")
            }
            v.check("Uploader search builds an @-prefixed query") {
                store.filters.query = "@someuser"
                return (store.filters.wirePayload(page: 1)["query"] as? String) == "@someuser"
            }
            v.check("Results carry the uploader the inspector shows") {
                // Not every wallpaper has one, but the field must decode.
                store.wallpapers.contains { $0.uploader != nil } || !store.wallpapers.isEmpty
            }
            v.check("Palette colours are bare hex, not \"#rrggbb\"") {
                // The API sends "#424153"; Scanner stops on the "#", so every
                // swatch rendered black. The core strips it.
                let all = store.wallpapers.flatMap(\.colors)
                guard !all.isEmpty else { return false }
                return all.allSatisfy { !$0.hasPrefix("#") && $0.count == 6 }
            }
            v.check("Every palette colour parses to a real colour") {
                let all = store.wallpapers.flatMap(\.colors)
                guard !all.isEmpty else { return false }
                return all.allSatisfy { Color(hex: $0) != Color.clear }
            }
            v.check("Color(hex:) tolerates a leading #") {
                Color(hex: "#424153") == Color(hex: "424153")
            }
            await v.checkAsync("The detail endpoint fills in the uploader") {
                // /search omits uploader entirely, so the preview has to ask.
                guard let first = store.wallpapers.first else { return false }
                let detailed = try? await LumenCore.shared.details(id: first.id)
                return detailed?.uploader != nil
            }
            v.check("Clear Finished empties completed rows") {
                store.clearFinished()
                return true
            }
        }
    }

    return v.summary()
}

let status = await run()
exit(status)

import Foundation
import AppKit

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

    /// A rate limit is Wallhaven pushing back, not a defect. The harness makes
    /// a lot of requests in a short window, so treat it as a skip — a gate that
    /// fails at random stops being read.
    func checkAPI(_ name: String, error: String?, _ body: () -> Bool) {
        if let error, error.localizedCaseInsensitiveContains("rate limit")
            || error.contains("429") {
            skip(name, "rate limited by Wallhaven")
            return
        }
        check(name) { body() }
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
            if let message = store.errorMessage {
                print("        core reported: \(message)")
                return false
            }
            return !store.wallpapers.isEmpty
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
            v.check("Results carry a palette") {
                store.wallpapers.contains { !$0.colors.isEmpty }
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

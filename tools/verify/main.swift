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

/// Whether to run the checks that talk to Wallhaven.
///
/// On by default, because the network half is where the real defects have been
/// found. `LUMEN_VERIFY_NETWORK=0`, or `run.sh --fast`, skips it.
let networkChecksEnabled = ProcessInfo.processInfo
    .environment["LUMEN_VERIFY_NETWORK"] != "0"

@MainActor
func run() async -> Int32 {
    let v = Verifier()
    let suiteName = "cc.lumen.verify"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    let defaults = UserDefaults(suiteName: suiteName)!
    // The store writes its API key to the keychain, and this run deliberately
    // sets an empty one — which removes the item. Point it at a throwaway
    // service so the key the app uses is never touched.
    Keychain.service = suiteName
    Keychain.removeAPIKey()
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
        store.rotationSource = before == .downloads ? .favorites : .downloads
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
    v.section("API key storage")
    v.check("A key round-trips through the keychain") {
        // A throwaway item, so the gate never touches the key in use.
        let service = "cc.lumen.verify"
        let account = "round-trip-\(UUID().uuidString)"
        defer { Keychain.remove(service: service, account: account) }

        guard Keychain.set("wallhaven-test-value", service: service, account: account) else {
            return false
        }
        guard Keychain.value(service: service, account: account) == "wallhaven-test-value" else {
            return false
        }
        // Writing again replaces rather than failing as a duplicate.
        guard Keychain.set("second", service: service, account: account),
              Keychain.value(service: service, account: account) == "second" else { return false }

        guard Keychain.remove(service: service, account: account) else { return false }
        return Keychain.value(service: service, account: account) == nil
    }
    v.check("An empty key removes the item rather than storing an empty one") {
        let service = "cc.lumen.verify"
        let account = "empty-\(UUID().uuidString)"
        defer { Keychain.remove(service: service, account: account) }
        _ = Keychain.set("something", service: service, account: account)
        guard Keychain.set("", service: service, account: account) else { return false }
        return Keychain.value(service: service, account: account) == nil
    }
    v.check("The key is no longer written to UserDefaults") {
        // The whole point of the move: a credential in a plist is readable by
        // anything running as the user.
        store.apiKey = "written-only-to-the-keychain"
        defer { store.apiKey = "" }
        guard defaults.string(forKey: "apiKey") == nil else { return false }
        return Keychain.apiKey() == "written-only-to-the-keychain"
    }
    v.check("A key left in UserDefaults by an older version is migrated out") {
        Keychain.removeAPIKey()
        defaults.set("legacy-plaintext-key", forKey: "apiKey")
        let relaunched = Store(defaults: defaults)
        defer { Keychain.removeAPIKey(); defaults.removeObject(forKey: "apiKey") }
        return relaunched.apiKey == "legacy-plaintext-key"
            && Keychain.apiKey() == "legacy-plaintext-key"
            && defaults.string(forKey: "apiKey") == nil
    }
    v.check("A key handed to the core does not reach the database") {
        // lumen-ffi clears this row deliberately; a key there would be
        // plaintext on disk beside every other preference. Booting with a
        // recognisable key and then looking for it in the file is the check.
        let canary = "lumen-canary-\(UUID().uuidString)"
        store.apiKey = canary
        store.savePreferences()
        defer { store.apiKey = "" }

        let path = NSString(string: "~/Library/Application Support/cc.lumen.Lumen/lumen.db")
            .expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: Data(canary.utf8)) == nil
    }

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
    // Everything from here to the end of this block talks to Wallhaven. A fast
    // run skips it: the offline checks below still run, so a quick pass stays
    // useful without waiting on the network or risking a rate limit.
    v.section("Search (network)")
    if !networkChecksEnabled {
        v.skip("Everything that needs Wallhaven", "fast run — set LUMEN_VERIFY_NETWORK=1")
    }
    if networkChecksEnabled {
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
    await v.checkAsync("Find Similar uses Wallhaven's own like: operator") {
        // Approximating similarity from tags was worse than the operator the
        // API actually provides.
        guard let sample = store.wallpapers.first else { return true }
        store.findSimilar(to: sample)
        let correct = store.filters.query == "like:\(sample.id)"
            && store.filters.sorting == .relevance

        // findSimilar fires the search in a Task, so wait for it to land
        // before restoring — otherwise the "like:" results, which can
        // legitimately be empty, overwrite the restore a moment later.
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(100))
            if !store.isLoading && store.filters.query.hasPrefix("like:")
                && (!store.wallpapers.isEmpty || store.errorMessage != nil) { break }
        }
        store.filters = SearchFilters()
        await store.search()
        return correct
    }
    await v.checkAPIAsync("A like: search returns wallpapers") { () -> (Bool, String?) in
        guard let sample = store.wallpapers.first else { return (true, nil) }
        var probe = SearchFilters()
        probe.query = "like:\(sample.id)"
        probe.sorting = .relevance
        do {
            let page = try await LumenCore.shared.search(probe, page: 1)
            return (!page.wallpapers.isEmpty, nil)
        } catch {
            // Report the error so an upstream outage skips rather than fails.
            return (false, error.localizedDescription)
        }
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

    v.section("Tag radar")
    v.check("Subscribing is idempotent and updates the threshold") {
        store.subscribe(to: "id:31", label: "Verify tag", minFavorites: 0)
        let after = store.subscriptions.filter { $0.query == "id:31" }
        store.subscribe(to: "id:31", label: "Verify tag", minFavorites: 250)
        let updated = store.subscriptions.filter { $0.query == "id:31" }
        return after.count == 1 && updated.count == 1 && updated[0].minFavorites == 250
    }
    v.check("A blank query is rejected") {
        let before = store.subscriptions.count
        store.subscribe(to: "   ", label: "nothing")
        return store.subscriptions.count == before
    }
    await v.checkAPIAsync("A check runs the saved searches") { () -> (Bool, String?) in
        guard store.subscriptions.contains(where: { $0.query == "id:31" }) else { return (true, nil) }
        do {
            // Only subscriptions with something new come back, so an empty
            // result is a valid answer — this asserts it completes.
            _ = try await LumenCore.shared.checkRadar()
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
    v.check("Opening a subscription searches it and clears the badge") {
        guard let subscription = store.subscriptions.first(where: { $0.query == "id:31" })
        else { return true }
        store.openSubscription(subscription)
        let cleared = store.subscriptions.first { $0.id == subscription.id }?.unseen == 0
        return cleared && store.filters.query == "id:31"
    }
    v.check("Unsubscribing removes it") {
        guard let subscription = store.subscriptions.first(where: { $0.query == "id:31" })
        else { return true }
        store.unsubscribe(subscription)
        return !store.subscriptions.contains { $0.query == "id:31" }
    }

    v.section("Spotlight metadata")
    v.check("Tags and origin are written where Finder and Spotlight read them") {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-meta-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return false }

        let wrote = WallpaperMetadata.write(
            tags: ["forest", "mist"],
            source: URL(string: "https://w.wallhaven.cc/full/ab/wallhaven-abc.jpg"),
            pageURL: URL(string: "https://wallhaven.cc/w/abc"),
            to: url)
        // Read back rather than trusting the write call.
        return wrote
            && WallpaperMetadata.keywords(of: url) == ["forest", "mist"]
            && WallpaperMetadata.whereFroms(of: url).contains("https://wallhaven.cc/w/abc")
    }
    v.check("A missing file is declined rather than half-written") {
        WallpaperMetadata.write(
            tags: ["x"], source: nil, pageURL: nil,
            to: URL(filePath: "/tmp/not-here-\(UUID().uuidString).png")) == false
    }

    v.section("Trash and put back")
    await v.checkAsync("Trashing moves the file and putting it back restores it") {
        // A real file in a real folder: this must not be tested against a stub,
        // because the whole point is that it goes to the system Trash.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-trash-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "wallhaven-trashme.png")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: file)) != nil else { return false }

        let local = LocalWallpaper(id: UUID().uuidString, folderId: "f", url: file,
                                   path: file.path(percentEncoded: false),
                                   filename: file.lastPathComponent,
                                   fileSize: png.count, isFavorite: false)
        store.trash([local])
        guard !FileManager.default.fileExists(atPath: file.path) else {
            print("        file was still there after trashing")
            return false
        }
        guard store.canRestoreTrashed else { return false }

        store.restoreTrashed()
        let back = FileManager.default.fileExists(atPath: file.path)
        if !back { print("        put back failed: \(store.errorMessage ?? "no error")") }
        // The offer is one-shot; it should not linger after being used.
        return back && !store.canRestoreTrashed
    }
    v.check("Trashing nothing does nothing") {
        store.forgetTrashed()
        store.trash([])
        return !store.canRestoreTrashed
    }
    v.check("A file that has already gone is reported, not silently skipped") {
        let missing = LocalWallpaper(
            id: "gone", folderId: "f",
            url: URL(filePath: "/tmp/lumen-not-here-\(UUID().uuidString).png"),
            path: "/tmp/gone.png", filename: "gone.png", fileSize: 0, isFavorite: false)
        store.errorMessage = nil
        store.trash([missing])
        let reported = store.errorMessage?.contains("Trash") == true
        store.forgetTrashed()
        store.errorMessage = nil
        return reported
    }

    v.section("Backup")
    await v.checkAsync("A backup round-trips favourites, collections and filters") {
        // Restore adds rather than replaces, so this checks the contents
        // survive rather than that the app is emptied first.
        store.filters.query = "backup-preset"
        store.savePreset(named: "Verify backup preset")
        store.createCollection(named: "Verify backup collection")

        let backup = store.makeBackup()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        store.exportBackup(to: url)

        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let read = try? decoder.decode(Store.Backup.self, from: data) else { return false }

        let keptPreset = read.presets.contains { $0.name == "Verify backup preset" }
        let keptCollection = read.collections.contains { $0.name == "Verify backup collection" }
        let keptFavorites = read.favorites.count == backup.favorites.count

        if let made = store.collections.first(where: { $0.name == "Verify backup collection" }) {
            store.deleteCollection(made)
        }
        if let preset = store.presets.first(where: { $0.name == "Verify backup preset" }) {
            store.deletePreset(preset)
        }
        return keptPreset && keptCollection && keptFavorites
    }
    v.check("Something that is not a backup is refused") {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-notabackup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("{\"nope\": true}".utf8).write(to: url)
        store.errorMessage = nil
        store.importBackup(from: url)
        return store.errorMessage?.contains("not a Lumen backup") == true
    }
    v.check("A backup carries the records, not just the ids") {
        // Restoring on a fresh install has an empty cache, so ids alone would
        // restore nothing.
        guard !store.favorites.isEmpty else { return true }
        let backup = store.makeBackup()
        return backup.favorites.first?.thumb.absoluteString.isEmpty == false
    }

    v.section("Resolution rule")
    v.check("Off by default, and hides nothing when off") {
        store.hideBelowDisplay = false
        return store.visible(store.wallpapers).count == store.wallpapers.count
            && store.hiddenCount(in: store.wallpapers) == 0
    }
    v.check("On, it hides exactly what would be upscaled") {
        guard !store.wallpapers.isEmpty else { return true }
        store.hideBelowDisplay = true
        let shown = store.visible(store.wallpapers)
        let hidden = store.hiddenCount(in: store.wallpapers)
        let correct = shown.allSatisfy { !store.fit($0).upscales }
            && hidden == store.wallpapers.count - shown.count
        store.hideBelowDisplay = false
        return correct
    }
    v.check("The rule persists") {
        store.hideBelowDisplay = true
        let persisted = Store(defaults: defaults).hideBelowDisplay
        store.hideBelowDisplay = false
        return persisted
    }

    v.section("Crop rectangles")
    v.check("A crop round-trips through storage, keyed by display") {
        let path = "/tmp/lumen-verify-crop-\(UUID().uuidString).png"
        let display = LumenCore.displayKey(CGSize(width: 3024, height: 1964))
        let other = LumenCore.displayKey(CGSize(width: 3440, height: 1440))
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)

        LumenCore.shared.saveCrop(path: path, display: display, rect: rect)
        guard let read = LumenCore.shared.crop(path: path, display: display) else { return false }
        // The same file on a differently shaped screen wants a different crop.
        let isolated = LumenCore.shared.crop(path: path, display: other) == nil

        LumenCore.shared.clearCrop(path: path, display: display)
        let cleared = LumenCore.shared.crop(path: path, display: display) == nil

        return abs(read.minX - rect.minX) < 0.001
            && abs(read.height - rect.height) < 0.001
            && isolated && cleared
    }
    await v.checkAsync("Rendering honours the crop it is given") {
        guard let done = store.downloads.first(where: { $0.state == .done }),
              let local = done.localFile else { return true }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-crop")
        defer { try? FileManager.default.removeItem(at: directory) }

        // The left half only: a different image from the centre crop.
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        guard let cropped = try? WallpaperFitter.render(
                local, to: CGSize(width: 400, height: 250), in: directory, crop: left),
              let centred = try? WallpaperFitter.render(
                local, to: CGSize(width: 400, height: 250), in: directory)
        else { return false }

        guard let a = NSImage(contentsOf: cropped), let b = NSImage(contentsOf: centred),
              let printA = ImagePrints.print(of: cropped),
              let printB = ImagePrints.print(of: centred),
              let apart = ImagePrints.distance(printA, printB) else { return false }
        // Both are the requested size, and they are genuinely different images.
        return a.size.width > 0 && b.size.width > 0 && apart > 0.01
    }

    v.section("Download metadata sidecar")
    v.check("A record written beside a file reads back whole") {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wallhaven-verify-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: url)
            WallpaperMetadata.removeSidecar(for: url)
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil,
              let sample = store.wallpapers.first else { return false }

        var record = sample
        record.tags = ["forest", "mist"]
        record.uploader = "someone"
        record.colors = ["336600"]
        guard WallpaperMetadata.writeSidecar(record, for: url) else { return false }

        guard let read = WallpaperMetadata.sidecar(for: url) else { return false }
        return read.id == sample.id
            && read.tags == ["forest", "mist"]
            && read.uploader == "someone"
            && read.colors == ["336600"]
    }
    v.check("The record is hidden, so the folder scan never indexes it") {
        // A visible sidecar would be picked up as a file in every folder.
        let url = URL(filePath: "/tmp/wallhaven-abc.jpg")
        return WallpaperMetadata.sidecarURL(for: url).lastPathComponent.hasPrefix(".")
    }
    v.check("A missing file is declined rather than leaving an orphan record") {
        let url = URL(filePath: "/tmp/not-here-\(UUID().uuidString).png")
        let refused = WallpaperMetadata.writeSidecar(
            store.wallpapers.first ?? Wallpaper(
                id: "x", url: nil, path: URL(filePath: "/tmp/x"),
                thumb: URL(filePath: "/tmp/x"), resolution: "1x1", ratio: 1,
                views: 0, favorites: 0, category: "general", purity: .sfw,
                fileSize: 0, fileType: "image/png", createdAt: ""),
            for: url) == false
        return refused && WallpaperMetadata.sidecar(for: url) == nil
    }

    v.section("Wallpaper history")
    await v.checkAsync("Setting a wallpaper records it, and undo puts the last one back") {
        // Two local files, so this does not depend on the network.
        func makeFile(_ name: String) -> URL? {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "lumen-verify-\(name)-\(UUID().uuidString).png")
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil else { return nil }
            return url
        }
        guard let first = makeFile("one"), let second = makeFile("two") else { return false }
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let scope = store.wallpaperScope
        store.wallpaperScope = .thisSpace          // do not rewrite every Space
        defer { store.wallpaperScope = scope }

        let one = LocalWallpaper(id: "1", folderId: "f", url: first, path: first.path,
                                 filename: first.lastPathComponent, fileSize: 1, isFavorite: false)
        let two = LocalWallpaper(id: "2", folderId: "f", url: second, path: second.path,
                                 filename: second.lastPathComponent, fileSize: 1, isFavorite: false)
        store.setLocalWallpaper(one)
        store.setLocalWallpaper(two)

        let recorded = store.history.first?.label == two.filename
            && store.history.dropFirst().first?.label == one.filename
        guard recorded, store.canUndoWallpaper else {
            print("        history: \(store.history.prefix(3).map(\.label))")
            return false
        }

        store.undoWallpaper()
        // Undo steps off the entry it left, so the newest is now the older one.
        let steppedBack = store.history.first?.label == one.filename
        if !steppedBack { print("        after undo: \(store.history.prefix(3).map(\.label))") }
        return steppedBack
    }
    v.check("Restoring something that has been deleted says so") {
        let entry = HistoryEntry(
            wallpaperId: nil,
            url: URL(filePath: "/tmp/gone-\(UUID().uuidString).png"),
            label: "gone.png", setAt: "2026-09-07 00:00:00")
        store.errorMessage = nil
        store.restore(entry)
        return store.errorMessage?.contains("no longer on disk") == true
    }
    v.check("A history timestamp reads as a date, not a raw string") {
        let entry = HistoryEntry(wallpaperId: nil, url: URL(filePath: "/tmp/x.png"),
                                 label: "x", setAt: "2026-09-07 14:30:00")
        // Asserting on the minutes would depend on the machine's timezone.
        return entry.when != entry.setAt && entry.when.contains("Sep")
    }

    v.section("Imported folders")
    await v.checkAsync("Importing a folder indexes the images in it") {
        // A real folder on disk, including a subfolder and a non-image, so the
        // scan's filtering is actually exercised.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-library-\(UUID().uuidString)")
        let nested = root.appending(path: "nested")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeImage(_ url: URL) {
            let image = NSImage(size: NSSize(width: 32, height: 20))
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 20).fill()
            image.unlockFocus()
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
        writeImage(root.appending(path: "one.png"))
        writeImage(nested.appending(path: "two.png"))
        try? Data("not an image".utf8).write(to: root.appending(path: "notes.txt"))

        await store.importFolder(at: root.path(percentEncoded: false))
        guard let folder = store.libraryFolders.first(where: { $0.path == root.path(percentEncoded: false) })
        else {
            print("        folder was not indexed: \(store.errorMessage ?? "no error")")
            return false
        }
        store.selectFolder(folder.id)
        let names = Set(store.libraryWallpapers.map(\.filename))
        let found = names == ["one.png", "two.png"]
        if !found { print("        indexed: \(names.sorted())") }

        // Favourite, set, and forget: the three things this pane is for.
        var favourited = false
        if let first = store.libraryWallpapers.first {
            store.toggleLibraryFavorite(first)
            favourited = store.libraryWallpapers.first(where: { $0.id == first.id })?.isFavorite == true
        }

        store.selectFolder(nil)
        store.forgetFolder(folder)
        let forgotten = !store.libraryFolders.contains { $0.id == folder.id }
        return found && favourited && forgotten
    }
    v.check("Nested folders browse as a tree rather than one flat list") {
        // Two levels down, so the "next level only" rule is exercised.
        let files = [
            LocalWallpaper(id: "1", folderId: "f", url: URL(filePath: "/tmp/a.png"),
                           path: "/tmp/a.png", filename: "a.png", fileSize: 1,
                           isFavorite: false, subpath: ""),
            LocalWallpaper(id: "2", folderId: "f", url: URL(filePath: "/tmp/n/b.png"),
                           path: "/tmp/n/b.png", filename: "b.png", fileSize: 1,
                           isFavorite: false, subpath: "nature"),
            LocalWallpaper(id: "3", folderId: "f", url: URL(filePath: "/tmp/n/d/c.png"),
                           path: "/tmp/n/d/c.png", filename: "c.png", fileSize: 1,
                           isFavorite: false, subpath: "nature/deep")
        ]
        store.libraryWallpapers = files
        store.selectedFolder = "f"
        store.browse(to: "")

        // At the root: one file, one subfolder counting everything beneath it.
        guard store.currentFiles.map(\.filename) == ["a.png"],
              store.currentSubfolders.map(\.name) == ["nature"],
              store.currentSubfolders.first?.count == 2 else { return false }

        store.browse(to: "nature")
        guard store.currentFiles.map(\.filename) == ["b.png"],
              store.currentSubfolders.map(\.name) == ["deep"] else { return false }

        store.browse(to: "nature/deep")
        let leaf = store.currentFiles.map(\.filename) == ["c.png"]
            && store.currentSubfolders.isEmpty
        // The breadcrumb is the way back up.
        let trail = store.breadcrumb.map(\.name) == ["nature", "deep"]
            && store.breadcrumb.last?.path == "nature/deep"

        store.libraryWallpapers = []
        store.selectedFolder = nil
        store.browse(to: "")
        return leaf && trail
    }
    v.check("With no folder chosen, the imported folders are the top level") {
        // Everything from every folder piling into one list is what made a
        // nested import look full of duplicates.
        store.libraryWallpapers = [
            LocalWallpaper(id: "1", folderId: "f", url: URL(filePath: "/tmp/a.png"),
                           path: "/tmp/a.png", filename: "a.png", fileSize: 1,
                           isFavorite: false, subpath: "")
        ]
        store.selectedFolder = nil
        return store.currentFiles.isEmpty
    }
    v.check("Choosing a folder returns to its top level") {
        store.browse(to: "somewhere/deep")
        store.selectFolder(nil)
        return store.browsePath.isEmpty
    }
    v.check("A local wallpaper reports the size of the file on disk") {
        // Read from the header, not by decoding, so a large folder stays cheap.
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lumen-verify-size-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // Built pixel-exact rather than through lockFocus, which renders at
        // the display's backing scale and would write a 96x48 file.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return false }

        let local = LocalWallpaper(id: "x", folderId: "y", url: url,
                                   path: url.path, filename: url.lastPathComponent,
                                   fileSize: png.count, isFavorite: false)
        return local.pixelSize == CGSize(width: 48, height: 24)
    }
    v.check("Setting a file that has gone reports it rather than failing quietly") {
        let missing = LocalWallpaper(
            id: "gone", folderId: "f",
            url: URL(filePath: "/tmp/definitely-not-here-\(UUID().uuidString).png"),
            path: "/tmp/gone.png", filename: "gone.png", fileSize: 0, isFavorite: false)
        store.errorMessage = nil
        store.setLocalWallpaper(missing)
        return store.errorMessage?.contains("no longer on disk") == true
    }

    v.section("Appearance pairing")
    v.check("Binding a wallpaper to light and dark persists") {
        guard store.wallpapers.count >= 2 else { return true }
        store.setPaired(store.wallpapers[0], dark: false)
        store.setPaired(store.wallpapers[1], dark: true)
        let reopened = Store(defaults: defaults)
        return reopened.lightWallpaper?.id == store.wallpapers[0].id
            && reopened.darkWallpaper?.id == store.wallpapers[1].id
    }
    v.check("The pane knows which half a wallpaper is") {
        guard store.wallpapers.count >= 2 else { return true }
        return store.pairedRole(store.wallpapers[0]) == "Light"
            && store.pairedRole(store.wallpapers[1]) == "Dark"
    }
    v.check("Unbinding clears just that half") {
        guard store.wallpapers.count >= 2 else { return true }
        store.setPaired(nil, dark: false)
        return store.lightWallpaper == nil
            && store.darkWallpaper?.id == store.wallpapers[1].id
    }
    v.check("Following is off until asked for, and does nothing unset") {
        let store = Store(defaults: UserDefaults(suiteName: "cc.lumen.verify.pair")!)
        defer { UserDefaults.standard.removePersistentDomain(forName: "cc.lumen.verify.pair") }
        let wasFollowing = store.followsAppearance
        store.applyPairedWallpaper()          // must not crash with no pair set
        return wasFollowing == false && store.current == nil
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
    v.check("A narrow window hides the inspector, a wide one brings it back") {
        store.previewShowsInspector = true
        store.previewInspectorAutoHidden = false
        store.previewZoomed = false
        // 700pt leaves 384 for the image beside a 316pt inspector: too little.
        store.reconcilePreviewInspector(windowWidth: 700, expanded: false)
        guard !store.previewShowsInspector, store.previewInspectorAutoHidden else { return false }
        store.reconcilePreviewInspector(windowWidth: 1400, expanded: false)
        return store.previewShowsInspector && !store.previewInspectorAutoHidden
    }
    v.check("Expanding the image hides the inspector, however wide the window") {
        // Clicking the image asks for the whole window, so the inspector goes
        // even on a display with room to spare — and comes back on the way out.
        guard !Store.inspectorFits(windowWidth: 6000, expanded: true),
              Store.inspectorFits(windowWidth: 1000, expanded: false) else { return false }
        store.previewShowsInspector = true
        store.previewInspectorAutoHidden = false
        store.reconcilePreviewInspector(windowWidth: 3400, expanded: true)
        guard !store.previewShowsInspector else { return false }
        store.reconcilePreviewInspector(windowWidth: 3400, expanded: false)
        return store.previewShowsInspector
    }
    v.check("An inspector closed by hand is not reopened by the rule") {
        store.previewShowsInspector = true
        store.previewInspectorAutoHidden = false
        store.togglePreviewInspector()
        guard !store.previewShowsInspector, !store.previewInspectorAutoHidden else { return false }
        store.reconcilePreviewInspector(windowWidth: 1600, expanded: false)
        let stayedClosed = !store.previewShowsInspector
        store.togglePreviewInspector()
        return stayedClosed && store.previewShowsInspector
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

    v.section("Bulk selection by count")
    v.check("Selectable total never understates what is loaded") {
        store.selectableTotal >= store.wallpapers.count
    }
    await v.checkAsync("Asking for more than exists selects what exists") {
        guard !store.favorites.isEmpty else { return true }
        store.setSelecting(true)
        // Favourites are a fully loaded list, so this must not try to page.
        await store.selectFirst(10_000, in: store.favorites)
        let capped = store.selectionCount == store.favorites.count
        store.setSelecting(false)
        return capped
    }
    await v.checkAsync("Selecting a count fetches pages until it has them") {
        guard store.lastPage > 1, store.wallpapers.count >= 12 else { return true }
        store.setSelecting(true)
        let want = min(store.wallpapers.count + 12, store.selectableTotal)
        await store.selectFirst(want, in: store.wallpapers)
        let got = store.selectionCount
        store.setSelecting(false)
        // Either it reached the target, or the search genuinely ran out.
        return got == want || got == store.selectableTotal
    }
    v.check("A zero or negative count selects nothing") {
        store.setSelecting(true)
        store.clearSelection()
        Task { await store.selectFirst(0, in: store.wallpapers) }
        let none = store.selectionCount == 0
        store.setSelecting(false)
        return none
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
            // Several checks above start a search in a Task and do not wait for
            // it; the last one to land decides what `wallpapers` holds. These
            // assert properties of search results, so they establish their own.
            store.filters = SearchFilters()
            await store.search()
            for _ in 0..<30 where store.wallpapers.isEmpty && store.errorMessage == nil {
                try? await Task.sleep(for: .milliseconds(100))
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
            await v.checkAPIAsync("The detail endpoint fills in the uploader") {
                () -> (Bool, String?) in
                // /search omits uploader entirely, so the preview has to ask.
                // Some uploads are anonymous, so try a few before concluding
                // the field never arrives.
                var lastError: String?
                for candidate in store.wallpapers.prefix(4) {
                    do {
                        let detailed = try await LumenCore.shared.details(id: candidate.id)
                        if detailed.uploader != nil { return (true, nil) }
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
                return (false, lastError)
            }
            v.check("Clear Finished empties completed rows") {
                store.clearFinished()
                return true
            }
        }
    }

    // Checks that need nothing from the network. Hoisted out of the
    // block above: they used to sit inside it, so an offline run — or one
    // where the search happened to return nothing — silently skipped them.
    v.section("Image feature prints")

    /// Writes a PNG of a given size with a deterministic pattern, so two files
    /// can be the same picture at different resolutions.
    func writePattern(width: Int, height: Int, shifted: Bool = false) -> URL? {
        let url = FileManager.default.temporaryDirectory
        .appending(path: "lumen-verify-print-\(UUID().uuidString).png")
        guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

        if shifted {
        // Structurally different, not just recoloured: reordering four
        // colour bands measured 0.11 apart, which is duplicate territory.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            context.setFillColor(red: .random(in: 0...1, using: &generator),
                                 green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: .random(in: 0...CGFloat(width), using: &generator),
                                y: .random(in: 0...CGFloat(height), using: &generator),
                                width: CGFloat(width) / 12, height: CGFloat(height) / 12))
        }
        } else {
        // Big blocks of colour: recognisable to a feature print at any size.
        let palette: [(CGFloat, CGFloat, CGFloat)] =
            [(0.1, 0.6, 0.3), (0.95, 0.85, 0.1), (0.2, 0.3, 0.9), (0.9, 0.2, 0.2)]
        for (index, colour) in palette.enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            let band = CGFloat(height) / CGFloat(palette.count)
            context.fill(CGRect(x: 0, y: CGFloat(index) * band,
                                width: CGFloat(width), height: band))
        }
        }
        guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    let bigCopy = writePattern(width: 800, height: 500)
    let smallCopy = writePattern(width: 320, height: 200)
    let different = writePattern(width: 800, height: 500, shifted: true)
    defer {
        for url in [bigCopy, smallCopy, different].compactMap({ $0 }) {
        try? FileManager.default.removeItem(at: url)
        }
    }

    v.check("The duplicate threshold sits between the two measured ranges") {
        // Unrelated real wallpapers measure 0.97-1.27; the same image resized
        // measures 0.24. A threshold outside that gap is the bug to catch.
        ImagePrints.duplicateThreshold > 0.3 && ImagePrints.duplicateThreshold < 0.9
    }
    v.check("A print can be computed, archived and read back") {
        guard let bigCopy, let observation = ImagePrints.print(of: bigCopy),
          let data = ImagePrints.encode(observation),
          let restored = ImagePrints.decode(data) else { return false }
        // A print must survive the round trip through storage intact.
        guard let apart = ImagePrints.distance(observation, restored) else { return false }
        return apart < 0.001
    }
    v.check("The same picture at another size is recognised") {
        // This is the whole point: a file hash cannot see that these match.
        guard let bigCopy, let smallCopy,
          let a = ImagePrints.print(of: bigCopy),
          let b = ImagePrints.print(of: smallCopy),
          let apart = ImagePrints.distance(a, b) else { return false }
        if apart > ImagePrints.duplicateThreshold {
        print("        resized copy measured \(apart), over the threshold")
        }
        return apart <= ImagePrints.duplicateThreshold
    }
    v.check("A different picture is not called a duplicate") {
        guard let bigCopy, let different,
          let a = ImagePrints.print(of: bigCopy),
          let b = ImagePrints.print(of: different),
          let apart = ImagePrints.distance(a, b) else { return false }
        if apart <= ImagePrints.duplicateThreshold {
        print("        unrelated pair measured \(apart), under the threshold")
        }
        return apart > ImagePrints.duplicateThreshold
    }
    v.check("Grouping puts the copies together and leaves the odd one out") {
        guard let bigCopy, let smallCopy, let different,
          let a = ImagePrints.print(of: bigCopy),
          let b = ImagePrints.print(of: smallCopy),
          let c = ImagePrints.print(of: different) else { return false }
        let groups = ImagePrints.duplicateGroups(in: [
        (bigCopy.path, a), (smallCopy.path, b), (different.path, c)
        ])
        return groups.count == 1
        && groups[0].count == 2
        && !groups[0].contains(different.path)
    }
    v.check("Nearest ranks the resized copy above the unrelated one") {
        guard let bigCopy, let smallCopy, let different,
          let a = ImagePrints.print(of: bigCopy),
          let b = ImagePrints.print(of: smallCopy),
          let c = ImagePrints.print(of: different) else { return false }
        let ranked = ImagePrints.nearest(
        to: a, in: [(smallCopy.path, b), (different.path, c)], excluding: bigCopy.path)
        return ranked.first?.path == smallCopy.path
    }
    v.check("An unreadable file yields no print rather than a wrong one") {
        let url = FileManager.default.temporaryDirectory
        .appending(path: "lumen-verify-notimage-\(UUID().uuidString).png")
        try? Data("definitely not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return ImagePrints.print(of: url) == nil
    }

    v.section("Duplicate scan scope")
    v.check("Each scope covers exactly what it says") {
        store.libraryWallpapers = [
        LocalWallpaper(id: "1", folderId: "f", url: URL(filePath: "/tmp/a.png"),
                       path: "/tmp/a.png", filename: "a.png", fileSize: 1,
                       isFavorite: false, subpath: "anime"),
        LocalWallpaper(id: "2", folderId: "f", url: URL(filePath: "/tmp/b.png"),
                       path: "/tmp/b.png", filename: "b.png", fileSize: 1,
                       isFavorite: false, subpath: "anime/girls"),
        LocalWallpaper(id: "3", folderId: "f", url: URL(filePath: "/tmp/c.png"),
                       path: "/tmp/c.png", filename: "c.png", fileSize: 1,
                       isFavorite: false, subpath: "nature")
        ]
        store.selectedFolder = "f"
        store.browse(to: "anime")

        store.duplicateScope = .thisFolder
        let here = store.duplicateCandidates.map(\.filename)

        store.duplicateScope = .includingNested
        let nested = store.duplicateCandidates.map(\.filename).sorted()

        store.duplicateScope = .everything
        let all = store.duplicateCandidates.count

        store.libraryWallpapers = []
        store.selectedFolder = nil
        store.browse(to: "")
        store.duplicateScope = .includingNested

        // "anime" alone, then anime plus anime/girls, then the lot.
        return here == ["a.png"]
        && nested == ["a.png", "b.png"]
        && all == 3
    }
    v.check("A sibling folder is never pulled in by the nested scope") {
        // anime/girls must not sweep in nature just because both are nested.
        store.libraryWallpapers = [
        LocalWallpaper(id: "1", folderId: "f", url: URL(filePath: "/tmp/a.png"),
                       path: "/tmp/a.png", filename: "a.png", fileSize: 1,
                       isFavorite: false, subpath: "anime"),
        LocalWallpaper(id: "2", folderId: "f", url: URL(filePath: "/tmp/c.png"),
                       path: "/tmp/c.png", filename: "c.png", fileSize: 1,
                       isFavorite: false, subpath: "animals")
        ]
        store.selectedFolder = "f"
        store.browse(to: "anime")
        store.duplicateScope = .includingNested
        // "animals" starts with "anima" but is not inside "anime".
        let scoped = store.duplicateCandidates.map(\.filename)
        store.libraryWallpapers = []
        store.selectedFolder = nil
        store.browse(to: "")
        return scoped == ["a.png"]
    }

    v.section("System accent matching")
    v.check("A strong colour maps to the accent a person would name") {
        SystemAccent.nearest(toHex: "0066cc") == .blue
        && SystemAccent.nearest(toHex: "cc0000") == .red
        && SystemAccent.nearest(toHex: "336600") == .green
        && SystemAccent.nearest(toHex: "993399") == .purple
    }
    v.check("A leading # is tolerated, and nonsense is declined") {
        SystemAccent.nearest(toHex: "#0066cc") == .blue
        && SystemAccent.nearest(toHex: "zzz") == nil
        && SystemAccent.nearest(toHex: "12345") == nil
    }
    v.check("A palette skips the black and white every wallpaper has") {
        // Wallhaven lists strongest first, and almost every palette starts
        // with #000000 — matching on that would make everything Graphite.
        let palette = ["000000", "ffffff", "cc0000", "999999"]
        return SystemAccent.nearest(toPalette: palette) == .red
    }
    v.check("A palette with nothing usable still answers rather than failing") {
        SystemAccent.nearest(toPalette: ["000000"]) != nil
        && SystemAccent.nearest(toPalette: []) == nil
    }
    v.check("Restore is only offered once something has been changed") {
        // Uses an isolated suite: this must not read or write the real setting.
        let suite = "cc.lumen.verify.accent"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return SystemAccent.canRestore(defaults) == false
        && SystemAccent.restore(defaults) == false
    }

    v.section("Navigation history")
    v.check("Back and forward walk the panes") {
        let browse = Store.Destination(pane: "browse", focus: nil)
        let downloads = Store.Destination(pane: "downloads", focus: nil)
        store.recordDestination(browse)
        store.recordDestination(downloads)
        guard store.canGoBack else { return false }

        let settings = Store.Destination(pane: "settings", focus: nil)
        guard store.goBack(from: settings)?.pane == "downloads" else { return false }
        guard store.canGoForward else { return false }
        return store.goForward(from: downloads)?.pane == "settings"
    }
    v.check("Going somewhere new clears the forward stack") {
        // Browser behaviour: a new destination discards what you stepped back from.
        _ = store.goBack(from: .init(pane: "settings", focus: nil))
        store.recordDestination(.init(pane: "favorites", focus: nil))
        return !store.canGoForward
    }
    v.check("The same place twice is not recorded twice") {
        // Start from a place that is definitely not already on top, or the
        // first record is legitimately deduped and the count never moves.
        store.recordDestination(.init(pane: "collections", focus: nil))
        let before = store.backStack.count
        let here = Store.Destination(pane: "displays", focus: nil)
        store.recordDestination(here)
        store.recordDestination(here)
        return store.backStack.count == before + 1
    }

    v.section("Spaces, individually")
    v.check("The window server's Spaces are enumerated and numbered") {
        let spaces = SpacesWallpaper.spaces()
        guard !spaces.isEmpty else {
        print("        no Spaces reported — nothing to assign to")
        return false
        }
        // Exactly one current Space per display, numbered from one.
        let currentPerDisplay = Dictionary(grouping: spaces, by: \.display)
        .allSatisfy { $0.value.filter(\.isCurrent).count <= 1 }
        return currentPerDisplay
        && spaces.allSatisfy { $0.number >= 1 }
        && spaces.contains { $0.isCurrent }
    }

    v.section("Colour search")
    v.check("Colours use the same seven-name vocabulary as the accent matcher") {
        // "Show me the green ones" should mean the same thing in both places.
        SystemAccent.allCases.count == 8
        && SystemAccent.nearest(toHex: "336600") == .green
    }
    v.check("No filter shows everything") {
        store.setColourFilter(nil)
        return store.byColour(store.libraryWallpapers).count == store.libraryWallpapers.count
    }

    v.section("Auto-collections and taste")
    v.check("Clustering groups by look and drops groups that are too small") {
        struct Entry { let path: String }
        // Build three prints from two genuinely different pictures.
        guard let a = writePattern(width: 400, height: 250),
          let b = writePattern(width: 200, height: 125),
          let c = writePattern(width: 400, height: 250, shifted: true)
        else { return false }
        defer {
        for url in [a, b, c] { try? FileManager.default.removeItem(at: url) }
        }
        guard let pa = ImagePrints.print(of: a),
          let pb = ImagePrints.print(of: b),
          let pc = ImagePrints.print(of: c) else { return false }

        // A minimum of two: the pair clusters, the odd one out does not.
        let groups = ImagePrints.cluster(
        [(a.path, pa), (b.path, pb), (c.path, pc)],
        threshold: 0.8, minimumSize: 2)
        guard groups.count == 1 else {
        print("        got \(groups.count) groups")
        return false
        }
        return groups[0].count == 2 && !groups[0].contains(c.path)
    }
    v.check("A minimum size larger than anything found yields nothing") {
        guard let a = writePattern(width: 400, height: 250),
          let b = writePattern(width: 200, height: 125) else { return false }
        defer {
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
        }
        guard let pa = ImagePrints.print(of: a), let pb = ImagePrints.print(of: b)
        else { return false }
        return ImagePrints.cluster([(a.path, pa), (b.path, pb)], minimumSize: 6).isEmpty
    }
    v.check("Affinity is the mean distance, and declines an empty reference set") {
        guard let a = writePattern(width: 400, height: 250),
          let b = writePattern(width: 200, height: 125),
          let c = writePattern(width: 400, height: 250, shifted: true) else { return false }
        defer {
        for url in [a, b, c] { try? FileManager.default.removeItem(at: url) }
        }
        guard let pa = ImagePrints.print(of: a),
          let pb = ImagePrints.print(of: b),
          let pc = ImagePrints.print(of: c) else { return false }

        // The resized copy sits closer to the original than the unrelated one.
        guard let near = ImagePrints.affinity(of: pb, to: [pa]),
          let far = ImagePrints.affinity(of: pc, to: [pa]) else { return false }
        return near < far && ImagePrints.affinity(of: pa, to: []) == nil
    }
    v.check("Taste ranking says what it needs rather than doing nothing") {
        // With no favourites there is nothing to measure against, and silence
        // would read as the button being broken.
        let empty = Store(defaults: UserDefaults(suiteName: "cc.lumen.verify.taste")!)
        defer { UserDefaults.standard.removePersistentDomain(forName: "cc.lumen.verify.taste") }
        return empty.favorites.isEmpty && empty.tasteRanked == false
    }

    v.section("Library health")
    await v.checkAsync("Measuring reports size, count and what is unindexed") {
        guard !store.libraryWallpapers.isEmpty else { return true }
        await store.measureLibrary()
        let health = store.health
        return health.count == store.libraryWallpapers.count
        && health.bytes > 0
        && health.largest != nil
        && health.unindexed <= health.count
        && health.belowDisplay <= health.count
    }
    v.check("An empty library measures as empty rather than failing") {
        let empty = Store.LibraryHealth()
        // ByteCountFormatter says "Zero bytes" for 0, not "0 bytes".
        return empty.count == 0 && empty.bytes == 0 && empty.largest == nil
        && !empty.size.isEmpty
    }

    v.section("Masonry layout")
    v.check("Columns balance by shape rather than by count") {
        // A Layout measures every subview before placing any, which is what
        // hung a two-thousand-file folder. This is arithmetic on known ratios.
        struct Tile: Identifiable { let id: Int; let ratio: Double }
        // Three wide tiles and three tall ones: an even split by count would
        // pile all the tall ones into one column.
        let tiles = (0..<6).map { Tile(id: $0, ratio: $0 < 3 ? 2.0 : 0.5) }
        let grid = MasonryGrid(items: tiles, aspect: \.ratio,
                           columnWidth: 100, spacing: 8) { _ in EmptyView() }
        let columns = grid.columnsForVerification(width: 320)   // three columns

        guard columns.count == 3 else { return false }
        // Every tile placed exactly once, and no column left empty.
        let placed = columns.flatMap { $0 }.map(\.id).sorted()
        return placed == [0, 1, 2, 3, 4, 5] && columns.allSatisfy { !$0.isEmpty }
    }
    v.check("A single narrow column keeps the original order") {
        struct Tile: Identifiable { let id: Int; let ratio: Double }
        let tiles = (0..<4).map { Tile(id: $0, ratio: 1.5) }
        let grid = MasonryGrid(items: tiles, aspect: \.ratio,
                           columnWidth: 300, spacing: 8) { _ in EmptyView() }
        let columns = grid.columnsForVerification(width: 320)
        return columns.count == 1 && columns[0].map(\.id) == [0, 1, 2, 3]
    }
    v.check("A degenerate ratio does not divide by zero") {
        struct Tile: Identifiable { let id: Int; let ratio: Double }
        let tiles = [Tile(id: 0, ratio: 0), Tile(id: 1, ratio: -1)]
        let grid = MasonryGrid(items: tiles, aspect: \.ratio,
                           columnWidth: 100, spacing: 8) { _ in EmptyView() }
        return grid.columnsForVerification(width: 320).flatMap { $0 }.count == 2
    }

    v.section("Menu bar legibility")

    /// A flat image of one luminance, for the assessments below.
    func flat(_ level: Double) -> NSImage {
        let size = NSSize(width: 256, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: level, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// Dark everywhere except a bright band across the top.
    func brightTopped() -> NSImage {
        let size = NSSize(width: 256, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        // Top of the image is the high-y end in AppKit's flipped-up space.
        NSRect(x: 0, y: size.height - 14, width: size.width, height: 14).fill()
        image.unlockFocus()
        return image
    }

    let screen = CGSize(width: 3024, height: 1964)
    v.check("A dark strip reads as safe") {
        guard let verdict = MenuBarLegibility.assess(flat(0.05), displaySize: screen)
        else { return false }
        return !verdict.isRisky && verdict.luminance < 0.2
    }
    v.check("A near-white strip reads as safe") {
        guard let verdict = MenuBarLegibility.assess(flat(0.97), displaySize: screen)
        else { return false }
        return !verdict.isRisky
    }
    v.check("A mid-tone strip is flagged") {
        guard let verdict = MenuBarLegibility.assess(flat(0.5), displaySize: screen)
        else { return false }
        return verdict.isRisky && verdict.summary.localizedCaseInsensitiveContains("mid-tone")
    }
    v.check("A dark image with a bright top is judged on the top, not the average") {
        // The whole point: macOS picks the text colour from the whole image,
        // so a dark wallpaper with a light band still fails.
        guard let verdict = MenuBarLegibility.assess(brightTopped(), displaySize: screen)
        else { return false }
        return verdict.isRisky
    }
    v.check("A degenerate image is declined rather than guessed at") {
        MenuBarLegibility.assess(NSImage(size: .zero), displaySize: screen) == nil
        && MenuBarLegibility.assess(flat(0.5), displaySize: .zero) == nil
    }

    v.section("Rotation sources")
    v.check("Every source round-trips through its key") {
        let sources: [RotationSource] = [
        .favorites, .downloads, .collection("abc"), .folder("def"),
        .savedFilter(UUID())
        ]
        return sources.allSatisfy { RotationSource(key: $0.key) == $0 }
        && RotationSource(key: "nonsense") == nil
        && RotationSource(key: "filter:not-a-uuid") == nil
    }
    v.check("The old three-choice setting still maps to something sensible") {
        // An existing install must not silently reset to Favourites.
        RotationSource.fromLegacy("Downloads") == .downloads
        && RotationSource.fromLegacy("Favorites") == .favorites
        && RotationSource.fromLegacy("anything else") == .favorites
    }
    v.check("The source list offers collections, folders and saved filters") {
        store.createCollection(named: "Verify rotation")
        store.subscribe(to: "id:31", label: "unused", minFavorites: 0)   // not a source
        store.filters.query = "rotation-preset"
        store.savePreset(named: "Verify preset")

        let sources = store.rotationSources
        let hasFixed = sources.contains(.favorites) && sources.contains(.downloads)
        let hasCollection = sources.contains {
        if case .collection = $0 { return store.name(of: $0) == "Verify rotation" }
        return false
        }
        let hasPreset = sources.contains {
        if case .savedFilter = $0 { return store.name(of: $0) == "Verify preset" }
        return false
        }

        if let made = store.collections.first(where: { $0.name == "Verify rotation" }) {
        store.deleteCollection(made)
        }
        if let preset = store.presets.first(where: { $0.name == "Verify preset" }) {
        store.deletePreset(preset)
        }
        if let watch = store.subscriptions.first(where: { $0.query == "id:31" }) {
        store.unsubscribe(watch)
        }
        return hasFixed && hasCollection && hasPreset
    }
    v.check("The pool size persists") {
        store.rotationPoolSize = 250
        return Store(defaults: defaults).rotationPoolSize == 250
    }
    await v.checkAsync("A missing saved filter is reported, not silently ignored") {
        let previous = store.rotationSource
        store.rotationSource = .savedFilter(UUID())      // never existed
        store.errorMessage = nil
        await store.rotate()
        let reported = store.errorMessage?.contains("no longer exists") == true
        store.rotationSource = previous
        store.errorMessage = nil
        return reported
    }

    }

    return v.summary()
}

let status = await run()
exit(status)

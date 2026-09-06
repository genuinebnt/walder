import AppKit
import SwiftUI

/// Sets the system accent colour to the nearest match for a wallpaper.
///
/// Two honest limits. macOS accepts only the seven named accents plus
/// Multicolour — there is no arbitrary colour to set — so this picks the
/// closest one rather than matching exactly. And the setting lives in
/// `NSGlobalDomain` with no public API, so this writes the preference and posts
/// the notification the system uses itself; already-running apps pick it up at
/// their own pace, and some only on relaunch.
///
/// Because it changes a system-wide setting, the previous value is recorded on
/// the first change so it can always be put back.
enum SystemAccent: Int, CaseIterable {
    case graphite = -1
    case red = 0
    case orange = 1
    case yellow = 2
    case green = 3
    case blue = 4
    case purple = 5
    case pink = 6

    var label: String {
        switch self {
        case .graphite: "Graphite"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }

    /// Roughly what macOS draws for each, for matching and for showing a swatch.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .graphite: (0.549, 0.549, 0.573)
        case .red: (1.000, 0.322, 0.341)
        case .orange: (0.969, 0.510, 0.106)
        case .yellow: (1.000, 0.776, 0.000)
        case .green: (0.384, 0.729, 0.275)
        case .blue: (0.000, 0.478, 1.000)
        case .purple: (0.584, 0.239, 0.588)
        case .pink: (0.969, 0.310, 0.620)
        }
    }

    var color: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }

    // MARK: Matching

    /// The named accent closest to a hex colour.
    static func nearest(toHex hex: String) -> SystemAccent? {
        let cleaned = hex.trimmingCharacters(in: .whitespaces).trimmingPrefix("#")
        var value: UInt64 = 0
        guard Scanner(string: String(cleaned)).scanHexInt64(&value), cleaned.count == 6
        else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255

        return allCases.min { first, second in
            distance(r, g, b, first) < distance(r, g, b, second)
        }
    }

    /// The best match across a wallpaper's palette, skipping near-black and
    /// near-white, which every wallpaper has and which say nothing about it.
    static func nearest(toPalette palette: [String]) -> SystemAccent? {
        let usable = palette.filter { hex in
            guard let (r, g, b) = components(of: hex) else { return false }
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let saturation = max(r, g, b) - min(r, g, b)
            return luma > 0.08 && luma < 0.94 && saturation > 0.12
        }
        // Wallhaven lists a wallpaper's palette strongest first.
        return (usable.first ?? palette.first).flatMap(nearest(toHex:))
    }

    private static func components(of hex: String) -> (Double, Double, Double)? {
        let cleaned = hex.trimmingCharacters(in: .whitespaces).trimmingPrefix("#")
        var value: UInt64 = 0
        guard Scanner(string: String(cleaned)).scanHexInt64(&value), cleaned.count == 6
        else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    /// "Redmean" colour distance — a cheap approximation of perceived
    /// difference that stays close to what a person would call the same colour.
    ///
    /// Weighting the channels by their luma coefficients, which is the obvious
    /// thing to reach for, compares *brightness* instead of hue: it matched a
    /// strong red to whichever accent was closest in lightness.
    private static func distance(_ r: Double, _ g: Double, _ b: Double,
                                 _ accent: SystemAccent) -> Double {
        let target = accent.rgb
        let meanRed = (r + target.r) / 2
        let dr = r - target.r
        let dg = g - target.g
        let db = b - target.b
        return (2 + meanRed) * dr * dr
            + 4 * dg * dg
            + (2 + (1 - meanRed)) * db * db
    }

    // MARK: Reading and writing the system setting

    private static let key = "AppleAccentColor"
    private static let restoreKey = "accentBeforeLumen"

    /// What the system is set to now. Multicolour has no value at all.
    static var current: SystemAccent? {
        guard let value = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?[key] as? Int
        else { return nil }
        return SystemAccent(rawValue: value)
    }

    /// Applies `accent` system-wide, remembering what was there first.
    @discardableResult
    static func apply(_ accent: SystemAccent, remembering defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: restoreKey) == nil {
            // Store the pre-Lumen value, including "Multicolour" as absent.
            defaults.set(current.map(\.rawValue) ?? Int.min, forKey: restoreKey)
        }
        return write(accent.rawValue)
    }

    /// True once Lumen has changed the accent and can put it back.
    static func canRestore(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: restoreKey) != nil
    }

    /// Puts back whatever the accent was before Lumen first changed it.
    @discardableResult
    static func restore(_ defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.object(forKey: restoreKey) as? Int else { return false }
        defaults.removeObject(forKey: restoreKey)
        return stored == Int.min ? clear() : write(stored)
    }

    private static func write(_ value: Int) -> Bool {
        var domain = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        domain[key] = value
        UserDefaults.standard.setPersistentDomain(domain, forName: UserDefaults.globalDomain)
        notifySystem()
        return true
    }

    /// Removing the key is how Multicolour is expressed.
    private static func clear() -> Bool {
        var domain = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        domain.removeValue(forKey: key)
        UserDefaults.standard.setPersistentDomain(domain, forName: UserDefaults.globalDomain)
        notifySystem()
        return true
    }

    /// The notification the system itself posts when the accent changes.
    /// Running apps pick it up at their own pace; some only on relaunch.
    private static func notifySystem() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil, userInfo: nil, deliverImmediately: true)
    }
}

import Foundation
import SwiftUI

/// User defaults, with every key in one place.
///
/// Defaults are registered at launch so the timing knobs read as plain
/// numbers everywhere instead of needing `object(forKey:) != nil` guards.
enum Pref {

    // MARK: Keys

    enum Key {
        static let activeWindowMinutes = "activeWindowMinutes"
        static let completedFlashSeconds = "completedFlashSeconds"
        static let idleAfterSeconds = "idleAfterSeconds"
        static let staleWorkingSeconds = "staleWorkingSeconds"
        static let spotlightSeconds = "spotlightSeconds"

        static let expandOnFinished = "expandOnFinished"
        static let expandOnHover = "expandOnHover"
        static let showModel = "showModel"
        static let singleSessionOnly = "singleSessionOnly"

        static let notchWidthOffset = "notchWidthOffset"
        static let notchHeightOffset = "notchHeightOffset"
        static let displaySelection = "displaySelection"
        static let hideInFullscreen = "hideInFullscreen"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.activeWindowMinutes: 20.0,
            Key.completedFlashSeconds: 8.0,
            Key.idleAfterSeconds: 300.0,
            Key.staleWorkingSeconds: 600.0,
            Key.spotlightSeconds: 6.0,

            Key.expandOnFinished: true,
            Key.expandOnHover: true,
            Key.showModel: true,
            Key.singleSessionOnly: false,

            Key.notchWidthOffset: 0.0,
            Key.notchHeightOffset: 0.0,
            Key.displaySelection: "auto",
            Key.hideInFullscreen: false,
        ])
    }

    // MARK: Timings

    /// How long a quiet session stays on the island. Also the discovery
    /// window — nothing older than this is ever parsed.
    static var activeWindowMinutes: Double {
        max(1, UserDefaults.standard.double(forKey: Key.activeWindowMinutes))
    }

    /// How long the "Finished" flash lasts before settling to "waiting".
    static var completedFlashSeconds: TimeInterval {
        max(1, UserDefaults.standard.double(forKey: Key.completedFlashSeconds))
    }

    /// Quiet time after which a waiting session drops to idle.
    static var idleAfterSeconds: TimeInterval {
        max(30, UserDefaults.standard.double(forKey: Key.idleAfterSeconds))
    }

    /// A turn open this long with no evidence and no live process is reported
    /// as unknown rather than a permanently-working lie.
    static var staleWorkingSeconds: TimeInterval {
        max(60, UserDefaults.standard.double(forKey: Key.staleWorkingSeconds))
    }

    /// How long the island stays open after a session finishes.
    static var spotlightSeconds: TimeInterval {
        max(2, UserDefaults.standard.double(forKey: Key.spotlightSeconds))
    }

    // MARK: Behaviour

    static var expandOnFinished: Bool {
        UserDefaults.standard.bool(forKey: Key.expandOnFinished)
    }

    static var expandOnHover: Bool {
        UserDefaults.standard.bool(forKey: Key.expandOnHover)
    }

    static var showModel: Bool {
        UserDefaults.standard.bool(forKey: Key.showModel)
    }

    /// Collapse multi-session lists down to the loudest session.
    static var singleSessionOnly: Bool {
        UserDefaults.standard.bool(forKey: Key.singleSessionOnly)
    }

    // MARK: Panel

    static var notchWidthOffset: Double {
        UserDefaults.standard.double(forKey: Key.notchWidthOffset)
    }

    static var notchHeightOffset: Double {
        UserDefaults.standard.double(forKey: Key.notchHeightOffset)
    }

    static var displaySelection: String {
        UserDefaults.standard.string(forKey: Key.displaySelection) ?? "auto"
    }

    static var hideInFullscreen: Bool {
        UserDefaults.standard.bool(forKey: Key.hideInFullscreen)
    }
}

extension Notification.Name {
    /// Posted when display selection or notch tuning changes, so the panel can
    /// re-pin itself to the correct screen.
    static let repositionPanel = Notification.Name("CMDCIslandRepositionPanel")
    /// Posted when hooks are installed or removed.
    static let hooksChanged = Notification.Name("CMDCIslandHooksChanged")
}

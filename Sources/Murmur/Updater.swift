import AppKit
#if !APPSTORE
import Sparkle
#endif

/// Self-update for the DMG build (Sparkle 2 with its standard UI).
///
/// Works only when the bundle carries a feed URL and an EdDSA public key (`SUFeedURL`, `SUPublicEDKey`,
/// written by build.sh). The Mac App Store build is compiled with `-DAPPSTORE`: Sparkle is neither
/// imported nor embedded there, and `isAvailable` is always false, so no update UI appears.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    /// Whether the build can update itself at all; the "Check for Updates…" item is shown only then.
    private(set) var isAvailable = false

    #if !APPSTORE
    private var controller: SPUStandardUpdaterController?

    /// Starts the updater: scheduled background checks (daily by default) plus the menu command.
    func start() {
        guard controller == nil, Self.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        isAvailable = true
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        // Menu bar app: bring ourselves forward so Sparkle's window isn't hidden behind the active app.
        (NSApp.delegate as? AppDelegate)?.closePanel()
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    private static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }
    #else
    func start() {}
    var canCheckForUpdates: Bool { false }
    var automaticallyChecks: Bool { get { false } set {} }
    func checkForUpdates() {}
    #endif
}

#if !APPSTORE
/// Murmur lives in the menu bar (`.accessory`, no Dock icon), so an update alert would easily get lost
/// behind other windows. While Sparkle shows an update, the app temporarily becomes a regular app:
/// it gets a Dock icon (with a badge for scheduled checks) and shows up in ⌘Tab.
/// This is Sparkle's recommended "gentle reminders" pattern for background apps.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            if !userInitiated {
                NSApp.dockTile.badgeLabel = "1"
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            NSApp.dockTile.badgeLabel = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
#endif

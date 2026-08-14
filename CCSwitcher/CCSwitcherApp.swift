import SwiftUI

private let launchLog = FileLog("Launch")

/// Owns the app-wide objects and performs launch bootstrapping.
///
/// These used to live on `CCSwitcherApp` as `@StateObject`s, with bootstrapping
/// driven by the keepalive window's `onAppear`. That made the menu bar icon
/// depend on a SwiftUI window actually appearing — and when macOS starts the app
/// as a login item, that window sometimes never does. The process then stays
/// alive with no status item and no refresh, which is indistinguishable from
/// "it didn't launch at all" (observed on two of three reboots; the app logged
/// its startup lines and then went silent for the rest of the day).
/// `applicationDidFinishLaunching` has no such dependency.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let updateChecker = UpdateChecker()
    let statusItemController = StatusItemController()

    private var didBootstrap = false

    override init() {
        // Apply saved language preference before any UI loads
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        if lang != "auto" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App starts as agent/accessory due to LSUIElement
        launchLog.info("[applicationDidFinishLaunching] bootstrapping")
        bootstrap()
    }

    /// Installs the status item and starts usage tracking. Idempotent, so the
    /// keepalive window can call it again as a safety net without side effects.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Sparkle's SPUStandardUpdaterController(startingUpdater: true) schedules
        // its own background update checks; no need to call checkForUpdates here.
        _ = updateChecker

        statusItemController.install(
            appState: appState,
            config: MenuBarConfig.shared,
            locale: Self.currentLocale
        )
        launchLog.info("[bootstrap] status item installed")

        // Kick off background usage tracking immediately upon app start
        let interval = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 300
        Task { @MainActor in
            await appState.refresh()
            appState.startAutoRefresh(interval: interval)
        }
    }

    static var currentLocale: Locale {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        return lang == "auto" ? .autoupdatingCurrent : Locale(identifier: lang)
    }
}

@main
struct CCSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuBarConfig = MenuBarConfig.shared
    @AppStorage("appLanguage") private var appLanguage = "auto"

    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CCSwitcherKeepalive") {
            HiddenWindowView()
                .onAppear {
                    // Logged so a failed launch can be diagnosed from the log alone:
                    // this line tells us whether the window ever appeared. (SwiftUI
                    // fires it twice; bootstrap() is idempotent.)
                    launchLog.info("[keepaliveWindow] onAppear")
                    // Safety net only — bootstrapping normally happened at launch,
                    // long before any window existed. Never make this the only path.
                    appDelegate.bootstrap()
                }
                .onChange(of: appLanguage) { _, _ in
                    appDelegate.statusItemController.updateLocale(currentLocale)
                }
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.updateChecker)
                .environmentObject(menuBarConfig)
                .environment(\.locale, currentLocale)
        }
    }

    private var currentLocale: Locale {
        appLanguage == "auto" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }
}

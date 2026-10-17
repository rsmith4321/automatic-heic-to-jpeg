// Automatic HEIC to JPEG: a menu bar app that moves AirDrops out of Downloads
// into a folder you choose and turns HEIC photos into JPEGs.
import SwiftUI

#if !DOCSHOTS
@main
#endif
struct AutomaticHEICtoJPEGApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel("Automatic HEIC to JPEG")
        }
        .menuBarExtraStyle(.window)
    }

    var menuBarSymbol: String {
        switch model.status {
        case .watching: return "photo.badge.arrow.down"
        case .paused, .notSetUp: return "photo"
        case .needsAccess, .destinationMissing: return "photo.badge.exclamationmark"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if model.setupDone {
            model.launch()
        } else {
            Windows.shared.showWelcome()
        }
    }
}

/// The Welcome and Settings windows, as plain AppKit windows hosting SwiftUI so
/// they can open at launch and come to the front from the menu bar panel.
@MainActor
final class Windows: NSObject {
    static let shared = Windows()
    private var welcome: NSWindow?
    private var settings: NSWindow?

    func showWelcome() {
        if welcome == nil {
            welcome = make(WelcomeView(), title: "Welcome")
        }
        present(welcome!)
    }

    func closeWelcome() {
        welcome?.close()
    }

    func showSettings() {
        if settings == nil {
            settings = make(SettingsView(), title: "Automatic HEIC to JPEG Settings")
        }
        AppModel.shared.refreshLoginStatus()
        present(settings!)
    }

    private func make<V: View>(_ view: V, title: String) -> NSWindow {
        let host = NSHostingController(rootView: view.environmentObject(AppModel.shared))
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// Renders the README screenshots off screen (nothing appears on your display):
// the menu bar panel and the Settings window, in light and dark. The photos in
// them are drawn here, so no personal pictures end up in docs/.
// Run Tools/docshots.sh.
import AppKit
import SwiftUI

/// Draws as the key window so switches and buttons use their active colours.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Switches also check that the app is active; this app never is (it draws off screen).
extension NSApplication {
    @objc var docShotsIsActive: Bool { true }
    static func pretendActive() {
        if let a = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
           let b = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.docShotsIsActive)) {
            method_exchangeImplementations(a, b)
        }
    }
}

@main
struct DocShots {
    static let out = URL(fileURLWithPath: CommandLine.arguments[1])
    static let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("docshots-\(UUID().uuidString)")

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApplication.pretendActive()
        NSApp.applicationIconImage = NSImage(contentsOf: URL(fileURLWithPath: "Resources/AppIcon.icns"))
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let model = AppModel.shared
        model.useDestination = true
        model.destinationPath = NSHomeDirectory() + "/Desktop/AirDrop"
        let now = Date()
        let samples: [(String, String, ActivityEntry.Kind, Double, [NSColor])] = [
            ("IMG_4821.HEIC \u{2192} IMG_4821.jpg", "Converted \u{00B7} original in the Trash", .converted, 40,
             [.systemOrange, .systemPink, .systemPurple]),
            ("IMG_4820.HEIC \u{2192} IMG_4820.jpg", "Converted \u{00B7} original in the Trash", .converted, 44,
             [.systemTeal, .systemBlue, .systemIndigo]),
            ("IMG_4819.HEIC \u{2192} IMG_4819.jpg", "Converted \u{00B7} original in the Trash", .converted, 50,
             [.systemYellow, .systemGreen, .systemTeal]),
            ("Boarding pass.pdf", "Moved to AirDrop", .moved, 60 * 25, []),
            ("IMG_4790.HEIC \u{2192} IMG_4790.jpg", "Converted \u{00B7} original in the Trash", .converted, 60 * 60 * 3,
             [.systemBlue, .systemCyan, .white]),
        ]
        let entries = samples.enumerated().map { i, s in
            ActivityEntry(date: now.addingTimeInterval(-s.3), kind: s.2, title: s.0, detail: s.1,
                          path: s.4.isEmpty ? nil : samplePhoto(i, colors: s.4).path)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // let the settings observer settle first
        model.showSample(status: .watching, activity: entries, earlier: 0)

        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let panel = snapshot(PanelView().environmentObject(model), titled: nil, appearance: appearance)
            save(framed(panel, corner: 12, dark: appearance == .darkAqua), "panel\(suffix).png")
            let settings = snapshot(SettingsView().environmentObject(model), titled: "Automatic HEIC to JPEG Settings", appearance: appearance)
            save(framed(settings, corner: 0, dark: appearance == .darkAqua), "settings\(suffix).png")
        }
        model.setupDone = false
        let welcome = snapshot(WelcomeView().environmentObject(model), titled: "Welcome", appearance: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)
        save(framed(welcome, corner: 0, dark: false), "welcome.png")
        try? FileManager.default.removeItem(at: work)
    }

    /// A small landscape-ish picture: a gradient sky, a sun and hills.
    static func samplePhoto(_ n: Int, colors: [NSColor]) -> URL {
        let size = NSSize(width: 240, height: 180)
        let image = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: colors)!.draw(in: r, angle: -90)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150 - CGFloat(n * 18), y: 110, width: 40, height: 40)).fill()
            let hill = NSBezierPath()
            hill.move(to: .zero)
            hill.curve(to: NSPoint(x: 240, y: 40), controlPoint1: NSPoint(x: 80, y: 110 - CGFloat(n * 10)), controlPoint2: NSPoint(x: 160, y: 20))
            hill.line(to: NSPoint(x: 240, y: 0)); hill.close()
            NSColor.black.withAlphaComponent(0.35).setFill(); hill.fill()
            return true
        }
        let url = work.appendingPathComponent("sample-\(n).jpg")
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: url)
        return url
    }

    @MainActor static func snapshot<V: View>(_ view: V, titled title: String?, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        // Off-screen windows never become key; draw controls as if they were.
        let host = NSHostingController(rootView: view.environment(\.controlActiveState, .key))
        let window: NSWindow
        if let title {
            window = KeyWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = title
        } else {
            window = KeyWindow(contentViewController: host)
            window.styleMask = [.borderless]
            window.backgroundColor = .windowBackgroundColor
        }
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))   // never on screen
        host.view.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (thumbnails load asynchronously).
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()
        let view = title == nil ? host.view : (window.contentView?.superview ?? host.view)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Puts a capture on a soft backdrop with rounded corners and a shadow.
    static func framed(_ rep: NSBitmapImageRep, corner: CGFloat, dark: Bool) -> NSBitmapImageRep {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let pad: CGFloat = 40
        let size = NSSize(width: rep.size.width + pad * 2, height: rep.size.height + pad * 2)
        let outRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        outRep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        let bg = NSRect(origin: .zero, size: size)
        (dark ? NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.27, alpha: 1), NSColor(calibratedRed: 0.24, green: 0.15, blue: 0.27, alpha: 1)])!
              : NSGradient(colors: [NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.97, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.72, alpha: 1)])!)
            .draw(in: bg, angle: -40)
        let r = NSRect(x: pad, y: pad, width: rep.size.width, height: rep.size.height)
        let radius = corner > 0 ? corner : 10
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        rep.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return outRep
    }

    static func save(_ rep: NSBitmapImageRep, _ name: String) {
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        print("Wrote docs/\(name)")
    }
}

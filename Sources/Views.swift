// The menu bar panel, Settings and the first-run Welcome window.
import ImageIO
import ServiceManagement
import SwiftUI

// MARK: - Menu bar panel

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            notices
            Divider()
            ActivityList()
            Divider()
            footer
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic HEIC to JPEG").font(.headline)
                StatusLine()
            }
            Spacer()
        }
    }

    @ViewBuilder private var notices: some View {
        switch model.status {
        case .notSetUp:
            Notice(symbol: "hand.wave", tint: .accentColor,
                   text: "Finish setting up to start handling AirDrops.") {
                Button("Set Up\u{2026}") { Windows.shared.showWelcome() }.buttonStyle(.borderedProminent)
            }
        case .needsAccess(let url):
            AccessNotice(folder: url)
        case .destinationMissing(let url):
            Notice(symbol: "externaldrive.badge.xmark", tint: .orange,
                   text: "\(AppModel.displayPath(url.path)) isn't available. AirDrops stay in Downloads until it's back.") {
                Button("Choose Another Folder\u{2026}") { model.chooseDestination() }
                Button("Try Again") { model.retry() }
            }
        default:
            EmptyView()
        }
        if model.status == .watching && model.earlier > 0 && !model.earlierDismissed {
            Notice(symbol: "tray.full", tint: .accentColor,
                   text: "\(model.earlier) \(model.earlier == 1 ? "AirDrop" : "AirDrops") from before setup \(model.earlier == 1 ? "is" : "are") still in Downloads.") {
                Button("Process Now") { model.processEarlier() }.buttonStyle(.borderedProminent)
                Button("Leave Them") { model.earlierDismissed = true }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Toggle("Convert HEIC", isOn: $model.convert)
                .toggleStyle(.checkbox)
                .help("Turn HEIC photos into JPEGs")
            Spacer()
            IconButton(symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause") {
                model.paused.toggle()
            }
            IconButton(symbol: "folder", help: "Open \(model.useDestination ? AppModel.displayPath(model.outputFolder.path) : "Downloads")") {
                model.openOutputFolder()
            }
            IconButton(symbol: "gearshape", help: "Settings") { Windows.shared.showSettings() }
            IconButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
        }
    }
}

struct StatusLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var color: Color {
        switch model.status {
        case .watching: return .green
        case .paused, .notSetUp: return .gray
        case .needsAccess, .destinationMissing: return .orange
        }
    }

    private var text: String {
        switch model.status {
        case .watching:
            return model.useDestination ? "AirDrops go to \(AppModel.displayPath(model.outputFolder.path))" : "Watching Downloads for AirDrops"
        case .paused: return "Paused"
        case .notSetUp: return "Not set up yet"
        case .needsAccess: return "Needs folder access"
        case .destinationMissing: return "Folder unavailable"
        }
    }
}

struct AccessNotice: View {
    @EnvironmentObject var model: AppModel
    let folder: URL

    var body: some View {
        Notice(symbol: "lock.trianglebadge.exclamationmark", tint: .orange,
               text: "macOS isn't letting the app use \(AppModel.displayPath(folder.path)). Turn it on under Privacy & Security \u{2192} Files & Folders \u{2192} Automatic HEIC to JPEG, then try again.") {
            Button("Open Privacy Settings") { model.openPrivacySettings() }.buttonStyle(.borderedProminent)
            Button("Try Again") { model.retry() }
        }
    }
}

struct Notice<Buttons: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack { buttons }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .background(hover ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

struct ActivityList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.activity.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "airplayaudio").font(.title2).foregroundStyle(.tertiary)
                Text("Nothing yet").font(.callout).foregroundStyle(.secondary)
                Text("AirDrop a photo to this Mac and it shows up here.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 20)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { model.clearActivity() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                    ForEach(model.activity) { ActivityRow(entry: $0) }
                }
                .padding(.bottom, 6)
            }
            .frame(height: min(CGFloat(model.activity.count) * 46 + 36, 300))
        }
    }
}

struct ActivityRow: View {
    @EnvironmentObject var model: AppModel
    let entry: ActivityEntry
    @State private var hover = false

    var body: some View {
        Button { model.reveal(entry) } label: {
            HStack(spacing: 10) {
                Thumbnail(path: entry.path, kind: entry.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(entry.detail).font(.caption).foregroundStyle(entry.kind == .failed || entry.kind == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text(entry.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
        .help(entry.detail + (entry.path == nil ? "" : "\nClick to show in Finder"))
    }
}

struct Thumbnail: View {
    let path: String?
    let kind: ActivityEntry.Kind
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
                Image(systemName: kind == .failed ? "exclamationmark.triangle" : kind == .moved ? "doc" : "photo")
                    .foregroundStyle(kind == .failed ? .orange : .secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: path) { image = await Self.load(path) }
    }

    static func load(_ path: String?) async -> NSImage? {
        guard let path else { return nil }
        return await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 96]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: 34, height: 34))
        }.value
    }
}

// MARK: - Shared settings controls

struct DestinationPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Put AirDrops in", selection: $model.useDestination) {
            Text("A folder of my choice").tag(true)
            Text("Leave them in Downloads").tag(false)
        }
        .pickerStyle(.radioGroup)
        if model.useDestination {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 18, height: 18)
                Text(AppModel.displayPath(model.destinationPath)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose\u{2026}") { model.chooseDestination() }
            }
        }
    }
}

struct ConversionControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Toggle("Convert HEIC photos to JPEG", isOn: $model.convert)
        Picker("Originals", selection: $model.originals) {
            ForEach(OriginalsMode.allCases) { Text($0.label).tag($0) }
        }
        .disabled(!model.convert)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                DestinationPicker()
            } header: {
                Text("AirDrops")
            } footer: {
                Text("AirDrop always saves into Downloads. Only files that arrived by AirDrop are moved; downloads from your browser stay put.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Photos") {
                ConversionControls()
                LabeledContent("JPEG quality") {
                    HStack {
                        Slider(value: $model.quality, in: 0.6...1.0, step: 0.05).frame(width: 160)
                        Text("\(Int((model.quality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.convert)
                Toggle(isOn: $model.convertOtherHEIC) {
                    Text("Also convert HEIC files that reach Downloads another way")
                    Text("For example from Messages or a website. These are converted in place, in Downloads.")
                }
                .disabled(!model.convert)
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin || model.loginNeedsApproval },
                                                     set: { model.setLaunchAtLogin($0) }))
                if model.loginNeedsApproval {
                    HStack {
                        Text("macOS needs you to allow it in Login Items.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppServiceHelper.openLoginItems() }.controlSize(.small)
                    }
                }
                LabeledContent("Earlier AirDrops") {
                    Button("Process AirDrops Already in Downloads") { model.processEarlier() }
                        .disabled(model.status != .watching || model.earlier == 0)
                }
                if model.earlier > 0 {
                    Text("\(model.earlier) waiting from before setup.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if case .needsAccess(let url) = model.status {
                Section("Access") {
                    Text("macOS isn't letting the app use \(AppModel.displayPath(url.path)).")
                    HStack {
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                        Button("Try Again") { model.retry() }
                    }
                }
            }

            Section {
                HStack {
                    Button("Show Log") { NSWorkspace.shared.open(model.logURL) }
                        .disabled(!FileManager.default.fileExists(atPath: model.logURL.path))
                    Spacer()
                    Text("Everything happens on this Mac. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum SMAppServiceHelper {
    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Welcome window

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var openAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.setupDone ? "You're all set" : "Welcome to Automatic HEIC to JPEG").font(.title2.weight(.semibold))
                    Text("AirDrops land in your Downloads folder. This app moves them where you want and turns HEIC photos into JPEGs, automatically.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            if model.setupDone { afterSetup } else { setup }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section { DestinationPicker() }
                Section { ConversionControls() }
                Section { Toggle("Open at login", isOn: $openAtLogin) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.secondary)
                Text("macOS will ask whether the app may use your Downloads folder\(model.useDestination && model.destinationPath.contains("/Desktop") ? " and your Desktop" : ""). Click Allow. Only files that arrived by AirDrop are touched, and everything stays on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 4)

            HStack {
                Spacer()
                Button("Start") { model.finishSetup(launchAtLogin: openAtLogin) }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(20)
        }
    }

    private var afterSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.status {
            case .needsAccess(let url):
                AccessNotice(folder: url).padding(.horizontal, -10)
            case .watching where model.earlier > 0:
                Text("\(model.earlier) \(model.earlier == 1 ? "AirDrop that arrived" : "AirDrops that arrived") before now \(model.earlier == 1 ? "is" : "are") still in Downloads. Handle \(model.earlier == 1 ? "it" : "them") the same way?")
                HStack {
                    Button("Leave Them") { model.earlierDismissed = true; Windows.shared.closeWelcome() }
                    Spacer()
                    Button("Process Them Now") { model.processEarlier(); Windows.shared.closeWelcome() }
                        .keyboardShortcut(.defaultAction)
                }
            default:
                Text("New AirDrops will be handled as they arrive. The app lives in your menu bar.")
                HStack {
                    Spacer()
                    Button("Done") { Windows.shared.closeWelcome() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
    }
}

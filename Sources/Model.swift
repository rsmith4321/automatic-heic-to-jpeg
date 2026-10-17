// Settings, state and the folder watcher. The watcher runs Processor passes on
// a background queue whenever the watched folder changes, and publishes the
// results to the menu bar panel.
import AppKit
import Combine
import ServiceManagement

enum Status: Equatable {
    case notSetUp, watching, paused
    case needsAccess(URL)        // macOS refused access to Downloads or the destination
    case destinationMissing(URL) // for example an unplugged drive
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let defaults = UserDefaults.standard

    // MARK: Settings (saved in the app's preferences)

    @Published var useDestination: Bool { didSet { save("useDestination", useDestination) } }
    @Published var destinationPath: String { didSet { save("destinationPath", destinationPath) } }
    @Published var convert: Bool { didSet { save("convertHEIC", convert) } }
    @Published var originals: OriginalsMode { didSet { save("originals", originals.rawValue) } }
    @Published var quality: Double { didSet { save("jpegQuality", quality) } }
    @Published var convertOtherHEIC: Bool { didSet { save("convertOtherHEIC", convertOtherHEIC) } }
    @Published var paused: Bool { didSet { save("paused", paused) } }
    @Published var setupDone: Bool { didSet { save("setupDone", setupDone) } }

    // MARK: State

    @Published private(set) var status = Status.notSetUp
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var earlier = 0
    /// "Leave them" on the earlier-AirDrops notice; Settings still offers the action.
    @Published var earlierDismissed: Bool { didSet { save("earlierDismissed", earlierDismissed) } }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    static let defaultDestination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/AirDrop").path

    /// AirDrop always saves into ~/Downloads. The hidden "WatchFolder" default
    /// exists for testing against a scratch folder.
    var watchFolder: URL {
        if let custom = defaults.string(forKey: "WatchFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL
    }

    var destinationURL: URL? {
        guard useDestination else { return nil }
        let url = URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        return sameFolder(url, watchFolder) ? nil : url
    }

    /// The folder "Open folder" shows: the destination, or Downloads.
    var outputFolder: URL { destinationURL ?? watchFolder }

    private var watchingSince: Date? {
        get { defaults.object(forKey: "watchingSince") as? Date }
        set { defaults.set(newValue, forKey: "watchingSince") }
    }

    private let queue = DispatchQueue(label: "automatic-heic-to-jpeg.scan")
    private let processor = Processor()           // used only on `queue`
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var heartbeat: Timer?
    private var pending: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Automatic HEIC to JPEG.log")

    private init() {
        defaults.register(defaults: [
            "useDestination": true, "destinationPath": Self.defaultDestination, "convertHEIC": true,
            "originals": OriginalsMode.trash.rawValue, "jpegQuality": 0.95, "convertOtherHEIC": false,
            "paused": false, "setupDone": false, "launchAtLoginWanted": true,
        ])
        useDestination = defaults.bool(forKey: "useDestination")
        destinationPath = defaults.string(forKey: "destinationPath") ?? Self.defaultDestination
        convert = defaults.bool(forKey: "convertHEIC")
        originals = OriginalsMode(rawValue: defaults.string(forKey: "originals") ?? "") ?? .trash
        quality = min(1, max(0.5, defaults.double(forKey: "jpegQuality")))
        convertOtherHEIC = defaults.bool(forKey: "convertOtherHEIC")
        paused = defaults.bool(forKey: "paused")
        setupDone = defaults.bool(forKey: "setupDone")
        earlierDismissed = defaults.bool(forKey: "earlierDismissed")
        if let data = defaults.data(forKey: "activity"), let saved = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            activity = saved
        }

        // Any settings change: rescan with the new options.
        Publishers.MergeMany(
            $useDestination.map { _ in () }.eraseToAnyPublisher(), $destinationPath.map { _ in () }.eraseToAnyPublisher(),
            $convert.map { _ in () }.eraseToAnyPublisher(), $originals.map { _ in () }.eraseToAnyPublisher(),
            $convertOtherHEIC.map { _ in () }.eraseToAnyPublisher(), $paused.map { _ in () }.eraseToAnyPublisher())
            .dropFirst(6)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.restart() }
            .store(in: &bag)
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    // MARK: Lifecycle

    func launch() {
        guard setupDone else { status = .notSetUp; return }
        if watchingSince == nil { watchingSince = Date() }
        // An app that was never registered reports .notFound, not .notRegistered.
        // .requiresApproval means the user switched it off in System Settings: leave that alone.
        let login = SMAppService.mainApp.status
        if defaults.bool(forKey: "launchAtLoginWanted") && (login == .notRegistered || login == .notFound) {
            setLaunchAtLogin(true)
        }
        restart()
    }

    /// Finishes first-run setup. Only AirDrops that arrive from now on are
    /// handled automatically; older ones wait for "Process earlier AirDrops".
    func finishSetup(launchAtLogin wanted: Bool) {
        watchingSince = Date()
        setupDone = true
        setLaunchAtLogin(wanted)
        restart()
    }

    func restart() {
        stopWatching()
        guard setupDone else { status = .notSetUp; return }
        guard !paused else { status = .paused; return }
        status = .watching
        startWatching()
        runScan(processEarlier: false, probe: true)
    }

    private func startWatching() {
        let path = watchFolder.path
        let fd = open(path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleScan(after: 1) }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
            watchedPath = path
        }
        // A slow heartbeat catches anything the folder events miss, and retries
        // after a permission or drive problem.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.source == nil { self.restart() } else { self.scheduleScan(after: 0) }
            }
        }
    }

    private func stopWatching() {
        source?.cancel(); source = nil; watchedPath = nil
        heartbeat?.invalidate(); heartbeat = nil
        pending?.cancel(); pending = nil
    }

    private func options() -> ProcessOptions {
        ProcessOptions(watchFolder: watchFolder, destination: destinationURL, convert: convert, originals: originals,
                       quality: quality, convertOtherHEIC: convertOtherHEIC, since: watchingSince)
    }

    func scheduleScan(after delay: Double) {
        guard setupDone, !paused else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runScan(processEarlier: false) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runScan(processEarlier: Bool, probe: Bool = false) {
        let opts = options()
        let processor = processor
        queue.async { [weak self] in
            let result = processor.scan(opts, processEarlier: processEarlier, probe: probe)
            DispatchQueue.main.async { self?.apply(result, processEarlier: processEarlier) }
        }
    }

    private func apply(_ result: ScanResult, processEarlier: Bool) {
        if let problem = result.watchProblem ?? result.destinationProblem {
            switch problem {
            case .noAccess(let url): status = .needsAccess(url)
            case .missing(let url): status = .destinationMissing(url)
            }
        } else if !paused {
            status = .watching
        }
        if !processEarlier { earlier = result.earlier }
        if !result.entries.isEmpty { record(result.entries) }
        if result.settling || processEarlier { scheduleScan(after: 2) }
    }

    /// The one-time action for AirDrops that were already in Downloads before setup.
    func processEarlier() {
        guard setupDone else { return }
        earlier = 0
        runScan(processEarlier: true)
    }

    func retry() { restart() }

    // MARK: Activity

    private func record(_ entries: [ActivityEntry]) {
        activity = Array((entries.reversed() + activity).prefix(20))
        if let data = try? JSONEncoder().encode(activity) { defaults.set(data, forKey: "activity") }
        let stamp = ISO8601DateFormatter()
        let lines = entries.map { "\(stamp.string(from: $0.date)) [\($0.kind.rawValue)] \($0.title): \($0.detail)\n" }.joined()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile(); handle.write(Data(lines.utf8)); try? handle.close()
        } else {
            try? Data(lines.utf8).write(to: logURL)
        }
    }

    func clearActivity() {
        activity = []
        defaults.removeObject(forKey: "activity")
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        defaults.set(on, forKey: "launchAtLoginWanted")
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            record([ActivityEntry(kind: .warning, title: "Open at login", detail: "Couldn't \(on ? "turn on" : "turn off"): \(error.localizedDescription)")])
        }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    // MARK: Helpers for the UI

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputFolder)
    }

    func reveal(_ entry: ActivityEntry) {
        guard let path = entry.path else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(outputFolder)
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where AirDrops should go."
        panel.directoryURL = URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath).deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
            useDestination = true
        }
    }

    /// "~/Desktop/AirDrop" style, for display.
    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

#if DOCSHOTS
extension AppModel {
    /// Sample state for the README screenshots (Tools/docshots.sh only).
    func showSample(status: Status, activity: [ActivityEntry], earlier: Int) {
        self.status = status
        self.launchAtLogin = true
        self.activity = activity
        self.earlier = earlier
    }
}
#endif

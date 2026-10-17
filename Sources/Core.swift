// The file handling, with no UI: finds AirDropped files in a folder, moves them
// to the destination and turns HEIC photos into JPEGs. The app runs it on a
// background queue; Tools/selftest exercises it against temporary folders.
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What to do with a HEIC once its JPEG exists. Nothing is ever deleted
/// permanently: "trash" uses the Trash, so Finder's Put Back still works.
enum OriginalsMode: String, CaseIterable, Identifiable {
    case trash, keepBeside, keepInSubfolder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .trash: return "Move the original to the Trash"
        case .keepBeside: return "Keep the original beside the JPEG"
        case .keepInSubfolder: return "Keep the original in an \u{201C}Originals\u{201D} folder"
        }
    }
}

struct ProcessOptions {
    /// The folder AirDrop saves into (~/Downloads).
    var watchFolder: URL
    /// Where AirDrops go; nil leaves them in the watch folder.
    var destination: URL?
    var convert = true
    var originals = OriginalsMode.trash
    var quality = 0.95
    /// Also convert HEIC files that reach the watch folder some other way (in place).
    var convertOtherHEIC = false
    /// Only items that arrived at or after this date; nil means every item.
    var since: Date?
}

struct ActivityEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case converted, moved, warning, failed }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var title: String
    var detail: String
    /// The resulting file, for "Show in Finder".
    var path: String?
    /// Where the original went (the Trash, or wherever it was kept).
    var originalPath: String? = nil
}

enum ScanProblem: Equatable {
    /// macOS refused to let us read the folder (Files and Folders privacy).
    case noAccess(URL)
    case missing(URL)
}

struct ScanResult {
    var entries: [ActivityEntry] = []
    /// Something may still be arriving; scan again shortly.
    var settling = false
    /// Items that arrived before `since` and are waiting for "Process earlier".
    var earlier = 0
    var watchProblem: ScanProblem?
    var destinationProblem: ScanProblem?
}

enum FileTags {
    static let quarantine = "com.apple.quarantine"
    /// Set on files we have dealt with but left in the watch folder, so they are not handled twice.
    static let handled = "io.github.rsmith4321.automatic-heic-to-jpeg.handled"

    static func get(_ name: String, _ url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    static func set(_ name: String, _ value: String, _ url: URL) {
        _ = value.withCString { setxattr(url.path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    /// The quarantine tag is "flags;hex Unix time;agent;uuid". AirDrop's agent is
    /// "sharingd"; browsers and other apps write their own names.
    static func quarantine(_ url: URL) -> (agent: String, date: Date?)? {
        guard let value = get(quarantine, url) else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count > 2 else { return nil }
        let date = UInt64(fields[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return (String(fields[2]), date)
    }

    static func isAirDrop(_ url: URL) -> Bool { quarantine(url)?.agent == "sharingd" }
}

func sameFolder(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
}

func isHEIC(_ url: URL) -> Bool { ["heic", "heif", "hif"].contains(url.pathExtension.lowercased()) }

final class Processor: @unchecked Sendable {   // used from one serial queue
    private let fm = FileManager.default
    /// Size and modification date at the previous scan, to tell when a file has stopped growing.
    private var lastSeen: [String: (size: Int, modified: Date)] = [:]

    func scan(_ o: ProcessOptions, processEarlier: Bool = false, probe: Bool = false) -> ScanResult {
        var result = ScanResult()
        if probe, let problem = probeDestination(o) {
            result.destinationProblem = problem
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                      .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .creationDateKey]
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: o.watchFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            result.watchProblem = Self.problem(for: error, at: o.watchFolder)
            return result
        }

        var ready: [URL] = []
        var seenNow: [String: (size: Int, modified: Date)] = [:]
        for url in items {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            if ["download", "crdownload", "part", "partial"].contains(ext) { continue }
            guard needsAction(url, o) else { continue }

            let arrived = v.addedToDirectoryDate ?? FileTags.quarantine(url)?.date ?? v.creationDate ?? .distantPast
            if let since = o.since, arrived < since.addingTimeInterval(-1) {
                if !processEarlier { result.earlier += 1; continue }
            }
            // Wait until the item has stopped changing: same size and date as
            // the last scan, and untouched for two seconds.
            let size = v.fileSize ?? Self.folderSize(url)
            let modified = v.contentModificationDate ?? .distantPast
            seenNow[url.path] = (size, modified)
            let prev = lastSeen[url.path]
            let stable = prev?.size == size && prev?.modified == modified && Date().timeIntervalSince(modified) > 2
            if stable || processEarlier && Date().timeIntervalSince(modified) > 2 { ready.append(url) } else { result.settling = true }
        }
        lastSeen = seenNow
        guard !ready.isEmpty else { return result }

        if let dest = o.destination {
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                guard fm.isWritableFile(atPath: dest.path) else { throw CocoaError(.fileWriteNoPermission) }
            } catch {
                // Leave everything where it is until the destination works again.
                result.destinationProblem = Self.problem(for: error, at: dest)
                return result
            }
        }
        for url in ready.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            result.entries.append(handle(url, o))
            lastSeen[url.path] = nil
        }
        return result
    }

    /// Creates and reads the destination up front, so macOS asks for access
    /// at setup rather than in the middle of the first AirDrop.
    func probeDestination(_ o: ProcessOptions) -> ScanProblem? {
        guard let dest = o.destination else { return nil }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            _ = try fm.contentsOfDirectory(atPath: dest.path)
            return nil
        } catch {
            return Self.problem(for: error, at: dest)
        }
    }

    /// Whether this item is ours to deal with under the current settings.
    func needsAction(_ url: URL, _ o: ProcessOptions) -> Bool {
        if FileTags.get(FileTags.handled, url) != nil { return false }
        if FileTags.isAirDrop(url) {
            return o.destination != nil || (o.convert && isHEIC(url))
        }
        return o.convertOtherHEIC && o.convert && isHEIC(url) && Self.isRegularFile(url)
    }

    func handle(_ url: URL, _ o: ProcessOptions) -> ActivityEntry {
        let airDrop = FileTags.isAirDrop(url)
        let name = url.lastPathComponent
        let targetDir = airDrop ? (o.destination ?? o.watchFolder) : o.watchFolder
        let place = sameFolder(targetDir, o.watchFolder) ? "Downloads" : targetDir.lastPathComponent

        if o.convert && isHEIC(url) && Self.isRegularFile(url) {
            let base = url.deletingPathExtension().lastPathComponent
            let jpeg = freeURL(in: targetDir, base: base, ext: "jpg")
            switch convert(url, to: jpeg, quality: o.quality) {
            case .failure(let reason):
                if airDrop && !sameFolder(targetDir, o.watchFolder), let moved = try? moveAside(url, to: targetDir) {
                    return ActivityEntry(kind: .failed, title: name, detail: "Couldn't convert (\(reason)); moved as is to \(place)", path: moved.path)
                }
                FileTags.set(FileTags.handled, "convert-failed", url)
                return ActivityEntry(kind: .failed, title: name, detail: "Couldn't convert (\(reason)); left as is", path: url.path)
            case .success:
                break
            }
            let jpegNote = "\(name) \u{2192} \(jpeg.lastPathComponent)"
            switch o.originals {
            case .trash:
                do {
                    var trashed: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                    return ActivityEntry(kind: .converted, title: jpegNote, detail: "Converted \u{00B7} original in the Trash",
                                         path: jpeg.path, originalPath: trashed?.path)
                } catch {
                    FileTags.set(FileTags.handled, "kept", url)
                    return ActivityEntry(kind: .warning, title: jpegNote, detail: "Converted, but the original couldn't go to the Trash: \(error.localizedDescription)", path: jpeg.path)
                }
            case .keepBeside, .keepInSubfolder:
                let keepDir = o.originals == .keepInSubfolder ? targetDir.appendingPathComponent("Originals") : targetDir
                let where_ = o.originals == .keepInSubfolder ? "in Originals" : "beside it"
                if sameFolder(keepDir, url.deletingLastPathComponent()) {
                    FileTags.set(FileTags.handled, "kept", url)
                    return ActivityEntry(kind: .converted, title: jpegNote, detail: "Converted \u{00B7} original kept \(where_)",
                                         path: jpeg.path, originalPath: url.path)
                }
                do {
                    try fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
                    let kept = try moveAside(url, to: keepDir)
                    return ActivityEntry(kind: .converted, title: jpegNote, detail: "Converted \u{00B7} original kept \(where_)",
                                         path: jpeg.path, originalPath: kept.path)
                } catch {
                    FileTags.set(FileTags.handled, "kept", url)
                    return ActivityEntry(kind: .warning, title: jpegNote, detail: "Converted; the original stayed in Downloads (\(error.localizedDescription))", path: jpeg.path)
                }
            }
        }

        // Not converting: an AirDrop that only needs to move.
        do {
            let moved = try moveAside(url, to: targetDir)
            return ActivityEntry(kind: .moved, title: name, detail: "Moved to \(place)", path: moved.path)
        } catch {
            return ActivityEntry(kind: .failed, title: name, detail: "Couldn't move: \(error.localizedDescription)", path: url.path)
        }
    }

    enum ConvertResult { case success, failure(String) }

    /// Writes the JPEG under a hidden temporary name first and only renames it
    /// into place once ImageIO reads it back, so a failure never leaves a half file.
    func convert(_ source: URL, to target: URL, quality: Double) -> ConvertResult {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            return .failure("not a readable image")
        }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        defer { try? fm.removeItem(at: temp) }
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return .failure("can't write to \(target.deletingLastPathComponent().lastPathComponent)")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        props[kCGImageDestinationPreserveGainMap] = true   // keeps iPhone HDR photos HDR
        CGImageDestinationAddImageFromSource(dest, src, index, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return .failure("ImageIO couldn't encode it") }
        guard let check = CGImageSourceCreateWithURL(temp as CFURL, nil),
              CGImageSourceGetType(check) as String? == UTType.jpeg.identifier,
              CGImageSourceCreateImageAtIndex(check, 0, nil) != nil
        else { return .failure("the JPEG didn't read back") }
        do {
            try fm.moveItem(at: temp, to: target)
        } catch {
            return .failure(error.localizedDescription)
        }
        copyDates(from: source, to: target)
        return .success
    }

    @discardableResult
    func moveAside(_ url: URL, to dir: URL) throws -> URL {
        let ext = url.pathExtension
        let target = freeURL(in: dir, base: url.deletingPathExtension().lastPathComponent, ext: ext)
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// A name in `dir` that is not taken: "IMG_1.jpg", "IMG_1 2.jpg", "IMG_1 3.jpg"...
    func freeURL(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            return ext.isEmpty ? u : u.appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    func copyDates(from source: URL, to target: URL) {
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        if let created = attrs[.creationDate] { dates[.creationDate] = created }
        if let modified = attrs[.modificationDate] { dates[.modificationDate] = modified }
        try? fm.setAttributes(dates, ofItemAtPath: target.path)
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    static func folderSize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        return total
    }

    static func problem(for error: Error, at url: URL) -> ScanProblem {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError || posix == Int(ENOENT) { return .missing(url) }
        return .noAccess(url)
    }
}

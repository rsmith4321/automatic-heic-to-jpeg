// Tests Sources/Core.swift against temporary folders. Run Tools/selftest.sh.
// It makes its own HEIC photos (with EXIF), fakes AirDrop and browser
// quarantine tags, and checks every path. Originals it sends to the Trash are
// moved back out and removed with the temporary folder afterwards.
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heic-selftest-\(UUID().uuidString)")
var trashed: [URL] = []

func makeHEIC(_ url: URL) {
    let w = 640, h = 480
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.95, green: 0.7, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 400, y: 300, width: 120, height: 120))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:16 20:43:00",
                                         kCGImagePropertyExifLensModel: "SelfTest Lens 6.8mm f/1.78"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone SelfTest"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 32.78, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 79.93, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyOrientation: 6,
    ]
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "this Mac can't encode HEIC")
}

func tag(_ url: URL, agent: String, age: TimeInterval = 0) {
    let stamp = String(UInt64(Date().addingTimeInterval(-age).timeIntervalSince1970), radix: 16)
    FileTags.set(FileTags.quarantine, "0081;\(stamp);\(agent);\(UUID().uuidString)", url)
}

/// Makes an item look as if it finished arriving a while ago.
func age(_ url: URL, _ seconds: TimeInterval = 10) {
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
}

func exif(_ url: URL) -> [CFString: Any] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
    return p
}

func isJPEG(_ url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetType(src) as String? == UTType.jpeg.identifier
}

func restoreFromTrash(_ entries: [ActivityEntry]) {
    for e in entries {
        if let p = e.originalPath, p.contains("/.Trash/") {
            let u = URL(fileURLWithPath: p)
            check(fm.fileExists(atPath: p), "original is in the Trash: \(u.lastPathComponent)")
            trashed.append(u)
        }
    }
}

/// Two passes, like the app: the first notes sizes, the second (once stable) acts.
func run(_ p: Processor, _ o: ProcessOptions, processEarlier: Bool = false) -> ScanResult {
    var r = p.scan(o, processEarlier: processEarlier)
    if r.entries.isEmpty && r.settling { r = p.scan(o, processEarlier: processEarlier) }
    restoreFromTrash(r.entries)
    return r
}

func fresh(_ name: String) -> (URL, URL) {
    let w = root.appendingPathComponent(name).appendingPathComponent("Downloads")
    let d = root.appendingPathComponent(name).appendingPathComponent("AirDrop")
    try! fm.createDirectory(at: w, withIntermediateDirectories: true)
    return (w, d)
}

try! fm.createDirectory(at: root, withIntermediateDirectories: true)


print("1. AirDrop HEIC is converted, browser HEIC and other downloads are left alone")
do {
    let (dl, dest) = fresh("basic")
    let air = dl.appendingPathComponent("IMG_2093.HEIC"); makeHEIC(air); tag(air, agent: "sharingd"); age(air)
    let web = dl.appendingPathComponent("photo-from-web.heic"); makeHEIC(web); tag(web, agent: "Safari"); age(web)
    let pdf = dl.appendingPathComponent("invoice.pdf"); try! Data("pdf".utf8).write(to: pdf); tag(pdf, agent: "Google Chrome"); age(pdf)
    let doc = dl.appendingPathComponent("Notes.txt"); try! Data("hi".utf8).write(to: doc); tag(doc, agent: "sharingd"); age(doc)
    let p = Processor()
    let o = ProcessOptions(watchFolder: dl, destination: dest)
    let r = run(p, o)
    let jpeg = dest.appendingPathComponent("IMG_2093.jpg")
    check(isJPEG(jpeg), "IMG_2093.jpg written to the AirDrop folder")
    check(!fm.fileExists(atPath: air.path), "HEIC is gone from Downloads")
    check(fm.fileExists(atPath: web.path), "browser HEIC untouched")
    check(fm.fileExists(atPath: pdf.path), "browser PDF untouched")
    check(fm.fileExists(atPath: dest.appendingPathComponent("Notes.txt").path), "AirDropped non-photo moved as is")
    let e = exif(jpeg)
    let ex = e[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = e[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    check(ex?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:16 20:43:00", "EXIF date kept")
    check(tiff?[kCGImagePropertyTIFFModel] as? String == "iPhone SelfTest", "camera model kept")
    check(e[kCGImagePropertyGPSDictionary] != nil, "GPS kept")
    check(e[kCGImagePropertyOrientation] as? Int == 6, "orientation kept")
    check(r.entries.count == 2, "two activity entries (got \(r.entries.count))")
    let again = run(p, o)
    check(again.entries.isEmpty, "a second pass does nothing")
}

print("2. Name collisions get \" 2\"")
do {
    let (dl, dest) = fresh("collide")
    try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    try! Data("existing".utf8).write(to: dest.appendingPathComponent("IMG_1.jpg"))
    let a = dl.appendingPathComponent("IMG_1.HEIC"); makeHEIC(a); tag(a, agent: "sharingd"); age(a)
    _ = run(Processor(), ProcessOptions(watchFolder: dl, destination: dest))
    check(isJPEG(dest.appendingPathComponent("IMG_1 2.jpg")), "new JPEG named IMG_1 2.jpg")
    check((try? String(contentsOf: dest.appendingPathComponent("IMG_1.jpg"), encoding: .utf8)) == "existing", "existing file not overwritten")
}

print("3. Files still arriving are skipped until they settle")
do {
    let (dl, dest) = fresh("settle")
    let a = dl.appendingPathComponent("IMG_9.HEIC"); makeHEIC(a); tag(a, agent: "sharingd")   // modified just now
    let p = Processor()
    let o = ProcessOptions(watchFolder: dl, destination: dest)
    let r1 = p.scan(o)
    check(r1.entries.isEmpty && r1.settling, "fresh file waits")
    age(a)
    let r2 = p.scan(o)
    check(r2.entries.isEmpty && r2.settling, "changed since last look: still waits")
    let r3 = p.scan(o)
    restoreFromTrash(r3.entries)
    check(r3.entries.count == 1 && isJPEG(dest.appendingPathComponent("IMG_9.jpg")), "stable file converted")
}

print("4. A broken HEIC is never lost")
do {
    let (dl, dest) = fresh("broken")
    let a = dl.appendingPathComponent("IMG_BAD.HEIC"); try! Data(repeating: 7, count: 4096).write(to: a); tag(a, agent: "sharingd"); age(a)
    let r = run(Processor(), ProcessOptions(watchFolder: dl, destination: dest))
    check(r.entries.first?.kind == .failed, "logged as failed")
    check(fm.fileExists(atPath: dest.appendingPathComponent("IMG_BAD.HEIC").path), "original moved as is to the AirDrop folder")
    check(!fm.fileExists(atPath: dest.appendingPathComponent("IMG_BAD.jpg").path), "no half-written JPEG")
    let leftovers = (try? fm.contentsOfDirectory(atPath: dest.path))?.filter { $0.hasPrefix(".") } ?? []
    check(leftovers.isEmpty, "no temporary files left")

    let (dl2, _) = fresh("broken-in-place")
    let b = dl2.appendingPathComponent("IMG_BAD2.HEIC"); try! Data(repeating: 7, count: 4096).write(to: b); tag(b, agent: "sharingd"); age(b)
    let p = Processor()
    let o = ProcessOptions(watchFolder: dl2, destination: nil)
    _ = run(p, o)
    check(fm.fileExists(atPath: b.path), "left in Downloads when there is no destination")
    check(run(p, o).entries.isEmpty, "not retried on every pass")
}

print("5. Keeping originals")
do {
    let (dl, dest) = fresh("keep")
    let a = dl.appendingPathComponent("IMG_K1.HEIC"); makeHEIC(a); tag(a, agent: "sharingd"); age(a)
    _ = run(Processor(), ProcessOptions(watchFolder: dl, destination: dest, originals: .keepBeside))
    check(isJPEG(dest.appendingPathComponent("IMG_K1.jpg")) && fm.fileExists(atPath: dest.appendingPathComponent("IMG_K1.HEIC").path), "beside: JPEG and HEIC in the AirDrop folder")

    let b = dl.appendingPathComponent("IMG_K2.HEIC"); makeHEIC(b); tag(b, agent: "sharingd"); age(b)
    _ = run(Processor(), ProcessOptions(watchFolder: dl, destination: dest, originals: .keepInSubfolder))
    check(isJPEG(dest.appendingPathComponent("IMG_K2.jpg")) && fm.fileExists(atPath: dest.appendingPathComponent("Originals/IMG_K2.HEIC").path), "subfolder: HEIC in AirDrop/Originals")

    let (dl2, _) = fresh("keep-in-place")
    let c = dl2.appendingPathComponent("IMG_K3.HEIC"); makeHEIC(c); tag(c, agent: "sharingd"); age(c)
    let p = Processor()
    let o = ProcessOptions(watchFolder: dl2, destination: nil, originals: .keepBeside)
    _ = run(p, o)
    check(isJPEG(dl2.appendingPathComponent("IMG_K3.jpg")) && fm.fileExists(atPath: c.path), "leave in Downloads: JPEG beside the HEIC")
    check(run(p, o).entries.isEmpty, "kept HEIC is not converted again")
}

print("6. Earlier AirDrops wait for the one-time action")
do {
    let (dl, dest) = fresh("earlier")
    let a = dl.appendingPathComponent("IMG_OLD.HEIC"); makeHEIC(a); tag(a, agent: "sharingd"); age(a)
    let since = Date().addingTimeInterval(60)   // "setup" happened after this file arrived
    let p = Processor()
    let o = ProcessOptions(watchFolder: dl, destination: dest, since: since)
    let r = run(p, o)
    check(r.entries.isEmpty && r.earlier == 1, "counted as earlier, not touched")
    check(fm.fileExists(atPath: a.path), "still in Downloads")
    let r2 = run(p, o, processEarlier: true)
    check(r2.entries.count == 1 && isJPEG(dest.appendingPathComponent("IMG_OLD.jpg")), "processed on request")
}

print("7. Conversion off, other HEIC on, leave in Downloads")
do {
    let (dl, dest) = fresh("options")
    let a = dl.appendingPathComponent("IMG_C.HEIC"); makeHEIC(a); tag(a, agent: "sharingd"); age(a)
    _ = run(Processor(), ProcessOptions(watchFolder: dl, destination: dest, convert: false))
    check(fm.fileExists(atPath: dest.appendingPathComponent("IMG_C.HEIC").path), "convert off: HEIC moved unchanged")

    let (dl2, _) = fresh("other")
    let web = dl2.appendingPathComponent("from-messages.heic"); makeHEIC(web); age(web)
    let p = Processor()
    _ = run(p, ProcessOptions(watchFolder: dl2, destination: nil, convertOtherHEIC: false))
    check(fm.fileExists(atPath: web.path) && !fm.fileExists(atPath: dl2.appendingPathComponent("from-messages.jpg").path), "other HEIC ignored by default")
    _ = run(p, ProcessOptions(watchFolder: dl2, destination: nil, convertOtherHEIC: true))
    check(isJPEG(dl2.appendingPathComponent("from-messages.jpg")), "other HEIC converted in place when turned on")
}

print("8. A missing destination leaves files where they are")
do {
    let (dl, _) = fresh("missing")
    let a = dl.appendingPathComponent("IMG_M.HEIC"); makeHEIC(a); tag(a, agent: "sharingd"); age(a)
    let r = run(Processor(), ProcessOptions(watchFolder: dl, destination: URL(fileURLWithPath: "/Volumes/No Such Drive \(UUID().uuidString)/AirDrop")))
    check(r.destinationProblem != nil, "destination problem reported")
    check(fm.fileExists(atPath: a.path), "AirDrop stays in Downloads")
}

// Clean up: take our test originals back out of the Trash, then remove the temp folder.
for u in trashed { try? fm.moveItem(at: u, to: root.appendingPathComponent("restored-\(UUID().uuidString)")) }
try? fm.removeItem(at: root)
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)

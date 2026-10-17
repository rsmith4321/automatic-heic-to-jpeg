// Draws the app icon: a photo card with a "JPG" tag on a sky-to-sunset tile.
// Run Tools/make-icon.sh.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)   // draw on a 1024 grid at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824 pt rounded square centred in 1024, soft drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.93, alpha: 1),
                        NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.38, alpha: 1)])!
        .draw(in: tile, angle: -70)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.16), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The photo card, tilted a little.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 512, yBy: 540)
    t.rotate(byDegrees: -6)
    t.concat()
    let card = NSRect(x: -250, y: -205, width: 500, height: 410)
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    cardShadow.shadowBlurRadius = 30
    cardShadow.shadowOffset = NSSize(width: 0, height: -14)
    cardShadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 46, yRadius: 46).fill()
    NSShadow().set()

    let photo = card.insetBy(dx: 34, dy: 34)
    let photoPath = NSBezierPath(roundedRect: photo, xRadius: 22, yRadius: 22)
    NSGraphicsContext.saveGraphicsState()
    photoPath.addClip()
    NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.80, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.62, alpha: 1))!.draw(in: photo, angle: -90)
    NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: photo.maxX - 150, y: photo.maxY - 140, width: 90, height: 90)).fill()
    let back = NSBezierPath()
    back.move(to: NSPoint(x: photo.minX - 10, y: photo.minY))
    back.line(to: NSPoint(x: photo.minX + 120, y: photo.minY + 170))
    back.line(to: NSPoint(x: photo.minX + 210, y: photo.minY + 90))
    back.line(to: NSPoint(x: photo.minX + 320, y: photo.minY + 215))
    back.line(to: NSPoint(x: photo.maxX + 10, y: photo.minY + 30))
    back.line(to: NSPoint(x: photo.maxX + 10, y: photo.minY))
    back.close()
    NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.45, alpha: 1).setFill()
    back.fill()
    let front = NSBezierPath()
    front.move(to: NSPoint(x: photo.minX - 10, y: photo.minY))
    front.line(to: NSPoint(x: photo.minX - 10, y: photo.minY + 60))
    front.line(to: NSPoint(x: photo.minX + 140, y: photo.minY + 120))
    front.line(to: NSPoint(x: photo.maxX + 10, y: photo.minY + 20))
    front.line(to: NSPoint(x: photo.maxX + 10, y: photo.minY))
    front.close()
    NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.36, alpha: 1).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // The "JPG" tag, bottom right.
    let tag = NSRect(x: 560, y: 175, width: 300, height: 150)
    NSGraphicsContext.saveGraphicsState()
    let tagShadow = NSShadow()
    tagShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    tagShadow.shadowBlurRadius = 20
    tagShadow.shadowOffset = NSSize(width: 0, height: -8)
    tagShadow.set()
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: tag, xRadius: 40, yRadius: 40).fill()
    NSGraphicsContext.restoreGraphicsState()
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let text = NSAttributedString(string: "JPG", attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: style, .kern: 4])
    let size = text.size()
    text.draw(in: NSRect(x: tag.minX, y: tag.midY - size.height / 2 + 2, width: tag.width, height: size.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]   // .iconset folder
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}

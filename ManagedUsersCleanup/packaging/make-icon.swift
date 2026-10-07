import AppKit
let out = CommandLine.arguments[1]
let sizes: [(String, Int)] = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)]
for (name, px) in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.62, alpha: 1))!.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold).applying(.init(paletteColors: [NSColor(calibratedRed: 1, green: 0.55, blue: 0.5, alpha: 1), .white]))
    if let sym = NSImage(systemSymbolName: "person.2.badge.minus", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = sym.size
        let scale = min(rect.width * 0.66 / sz.width, rect.height * 0.66 / sz.height)
        let w = sz.width * scale, h = sz.height * scale
        sym.draw(in: NSRect(x: rect.midX - w/2, y: rect.midY - h/2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}

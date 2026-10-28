import AppKit

// Run from the repository root: swift Design/Branding/render-symbol.swift
let source = URL(fileURLWithPath: "Design/Branding/MenuBarSymbol.svg")
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot load symbol SVG") }
for scale in [1, 2] {
    let pixels = 18 * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 1 ? "" : "@2x"
    let destination = URL(fileURLWithPath: "Sources/App/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}

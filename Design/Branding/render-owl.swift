import AppKit

let source = URL(fileURLWithPath: "Design/Branding/owl-06-flat-v2.svg")
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot load owl SVG") }
let width = 2280, height = 2040
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to:
    URL(fileURLWithPath: "Design/Branding/owl-render.png"))

import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

// Standalone native verification; no subscriptions, preferences, or network access.
// swiftc -parse-as-library Sources/App/OwlLogoGeometry.swift Sources/App/OwlTouchResponse.swift Sources/App/StatusLogoFeedback.swift \
//   tools/status-bar/verify-vector.swift -o /tmp/verify-airport-vector
@main
struct VerifyVector {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return value ^ (value >> 31)
        }
    }
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let responses = (0..<64).map { index in
            var generator = Seeded(state: UInt64(index) + 20261020)
            return OwlTouchResponse.makeResponse(using: &generator)
        }
        precondition(Set(responses.map { $0.blinks.count }) == Set([1, 2, 3]))
        precondition(Set(responses.map { $0.blinks.first!.start }).count == responses.count)
        precondition(Set(responses.map(\.pressDuration)).count > 3)
        let examples = Array(responses.prefix(3))
        let tiltedCount = responses.filter { $0.samples.contains { abs($0.headAngle) > 0.01 } }.count
        precondition(tiltedCount > 0 && tiltedCount < responses.count / 2)
        for response in responses {
            let samples = response.samples
            precondition(samples.allSatisfy { sample in
                [sample.compression, sample.bodyX, sample.bodyY, sample.headAngle, sample.headX,
                 sample.headY, sample.upperClosure, sample.lowerClosure,
                 sample.rightUpperClosure, sample.rightLowerClosure].allSatisfy(\.isFinite)
            })
            precondition(samples.map(\.compression).min()! > -0.62)
            precondition(samples.contains { $0.compression < -0.05 && $0.scaleY > 1 && $0.scaleX < 1 })
            precondition(samples.map(\.scaleY).min()! > 0.88 && samples.map(\.scaleY).min()! < 0.91)
            precondition(samples.map(\.scaleY).max()! < 1.07)
            // Exclude the forced final rest sample: rebounds must come from the
            // spring itself, alternate around rest, and lose energy each time.
            let extremaIndices = ((response.pressEndIndex + 1)..<(samples.count - 2)).filter { index in
                let previous = samples[index - 1].compression
                let current = samples[index].compression
                let next = samples[index + 1].compression
                return (current - previous) * (next - current) < 0
            }
            let extrema = extremaIndices.map { samples[$0].compression }
            precondition(extrema.count >= 4)
            precondition(extrema[0] < -0.37 && extrema[1] > 0.17 && extrema[2] < -0.075)
            let intervals = zip(extremaIndices, extremaIndices.dropFirst()).map { Double($1 - $0) / 240 }
            precondition(intervals[1] > intervals[0] && intervals[2] > intervals[1])
            for (first, second) in zip(extrema, extrema.dropFirst()) {
                precondition(first * second < 0 && abs(second) < abs(first) * 0.65)
            }
            precondition(abs(samples[samples.count - 2].compression) < 0.02)
            precondition(samples.map(\.scaleX).max()! < 1.06)
            precondition(response.pressDuration > 0.10 && response.pressDuration < 0.30)
            precondition(response.blinks.first!.start > response.pressDuration)
            precondition(samples.prefix(response.pressEndIndex + 1).allSatisfy { $0.upperClosure == 0 && $0.rightUpperClosure == 0 })
            precondition(samples.map { abs($0.headAngle) }.max()! < 0.70)
            precondition(samples.map(\.upperClosure).max()! < 0.90)
            precondition(samples.map(\.rightUpperClosure).max()! <= 0.90)
            precondition(samples.map(\.lowerClosure).max()! < 0.23)
            precondition(samples.first!.headAngle == 0 && samples.last!.headAngle == 0)
            precondition(samples.last!.upperClosure == 0 && samples.last!.compression == 0)
            precondition(response.blinks.first!.start > response.headDelay + 0.07)
            let firstBlinkIndex = Int(response.blinks.first!.start / response.duration * Double(samples.count - 1))
            let before = samples[firstBlinkIndex], after = samples[firstBlinkIndex + 1]
            precondition(hypot(after.headX - before.headX, after.headY - before.headY) > 1e-8)
            precondition(samples.map { abs($0.headY) }.max()! < 0.30)
            let bodyPeakIndex = response.pressEndIndex
            let headPeakIndex = samples.indices.max { abs(samples[$0].headY) < abs(samples[$1].headY) }!
            precondition(headPeakIndex > bodyPeakIndex)
            precondition(samples.map { abs($0.bodyY) }.max()! < 0.06)
            for (index, sample) in samples.enumerated() {
                let time = Double(index) / Double(samples.count - 1) * response.duration
                if time <= response.headDelay {
                    precondition(sample.headAngle == 0 && sample.headX == 0 && sample.headY == 0)
                }
                if time <= response.blinks.first!.start {
                    precondition(sample.upperClosure == 0 && sample.rightUpperClosure == 0)
                }
            }
            for (first, second) in zip(response.blinks, response.blinks.dropFirst()) {
                precondition(second.start >= first.end + 0.129)
            }
        }

        let union = OwlLogoGeometry.headOutline.union(OwlLogoGeometry.bodyOutline)
        // Boolean curves can leave zero-area residual paths; compare filled areas
        // on a half-source-unit grid (over 30× finer than the menu icon's pixels).
        var differences = 0
        var interiorDifferences = 0
        for y in stride(from: 0.25, to: 340.0, by: 0.5) {
            for x in stride(from: 0.25, to: 380.0, by: 0.5) {
                let point = CGPoint(x: x, y: y)
                if union.contains(point) != OwlLogoGeometry.silhouette.contains(point) {
                    differences += 1
                    let fill = OwlLogoGeometry.silhouette.contains(point)
                    let nearBoundary = [CGPoint(x: x - 0.1, y: y), CGPoint(x: x + 0.1, y: y),
                                        CGPoint(x: x, y: y - 0.1), CGPoint(x: x, y: y + 0.1)]
                        .contains { OwlLogoGeometry.silhouette.contains($0) != fill }
                    if !nearBoundary { interiorDifferences += 1 }
                }
            }
        }
        print("Silhouette fill differences: \(differences)")
        FileHandle.standardError.write(Data("Silhouette grid differences: \(differences)\n".utf8))
        precondition(interiorDifferences == 0)

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 390,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        func drawOwl(at origin: CGPoint, zoom: CGFloat, openness: CGFloat, tilt: CGFloat, ink: NSColor,
                     pose: OwlTouchResponse.Sample? = nil) {
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: zoom, y: zoom)
            let state = pose ?? .rest
            let sx = state.scaleX, sy = state.scaleY
            context.concatenate(CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                tx: 9 * (1 - sx) + state.bodyX, ty: 1 - sy + state.bodyY))
            context.setFillColor(ink.cgColor)
            context.addPath(OwlLogoGeometry.iconPath(OwlLogoGeometry.bodyOutline))
            context.fillPath()
            let neck = OwlLogoGeometry.neckPivot
            context.translateBy(x: neck.x + state.headX, y: neck.y + state.headY)
            context.rotate(by: (pose?.headAngle ?? tilt) * .pi / 180)
            context.addPath(OwlLogoGeometry.headPath())
            context.drawPath(using: .eoFill)
            for (eyeIndex, eye) in OwlLogoGeometry.eyePaths.enumerated() {
                let lids = OwlLogoGeometry.eyelids(for: eye)
                context.saveGState()
                context.addPath(OwlLogoGeometry.eyeCoverMask(for: eye))
                context.clip()
                let cover = CGMutablePath()
                cover.addPath(lids.upper, transform: CGAffineTransform(translationX: 0,
                    y: lids.upperTravel * (pose.map { 1 - (eyeIndex == 0 ? $0.upperClosure : $0.rightUpperClosure) } ?? openness)))
                cover.addPath(lids.lower, transform: CGAffineTransform(translationX: 0,
                    y: -lids.lowerTravel * (pose.map { 1 - (eyeIndex == 0 ? $0.lowerClosure : $0.rightLowerClosure) } ?? openness)))
                context.addPath(cover)
                context.fillPath()
                context.restoreGState()
            }
            context.restoreGState()
        }
        for row in 0..<2 {
            let dark = row == 0
            let y = CGFloat(row * 195)
            (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor.white).setFill()
            NSRect(x: 0, y: y, width: 720, height: 195).fill()
            let ink = dark ? NSColor.white : NSColor.black
            for (column, eye) in [CGFloat(1), 0.12, 0].enumerated() {
                let x = CGFloat(column * 240)
                drawOwl(at: CGPoint(x: x + 42, y: y + 38), zoom: 8,
                        openness: eye, tilt: column == 0 ? 0 : 4.5, ink: ink)
                drawOwl(at: CGPoint(x: x + 192, y: y + 102), zoom: 1,
                        openness: eye, tilt: column == 0 ? 0 : 4.5, ink: ink)
                let text = ["Rest", "Half closed + tilt", "Closed + tilt"][column]
                (text as NSString).draw(at: CGPoint(x: x + 30, y: y + 14), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink
                ])
            }
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)

        // Offline motion preview driven by the exact response used in production;
        // this is a rendered preview, not a screen recording of the native button.
        let gifURL = output.deletingLastPathComponent().appendingPathComponent("softening-jelly.gif")
        let frameCount = Int(ceil((examples.enumerated().map { $0.element.duration + ($0.offset == 1 ? 0.28 : 0) }.max()! + 0.8) * 50))
        let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frameCount {
            let time = Double(frame) / 50
            for row in 0..<2 {
                let dark = row == 0
                let y = CGFloat(row * 195)
                (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor.white).setFill()
                NSRect(x: 0, y: y, width: 720, height: 195).fill()
                let ink = dark ? NSColor.white : NSColor.black
                for (column, example) in examples.enumerated() {
                    let samples = example.samples
                    let playback = column == 1 && time > example.pressDuration
                        ? max(example.pressDuration, time - 0.28) : time
                    let index = min(samples.count - 1, Int(playback / example.duration * Double(samples.count - 1)))
                    let state = samples[index]
                    let x = CGFloat(column * 240)
                    drawOwl(at: CGPoint(x: x + 38, y: y + 34), zoom: 8,
                        openness: 1, tilt: 0, ink: ink, pose: state)
                    drawOwl(at: CGPoint(x: x + 194, y: y + 96), zoom: 1,
                        openness: 1, tilt: 0, ink: ink, pose: state)
                    let label = ["轻点", "按住后松开", "另一次轻点"][column]
                    (label as NSString).draw(at: CGPoint(x: x + 40, y: y + 12), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink
                    ])
                }
            }
            // NSBitmapImageRep.cgImage can cache its first snapshot. Capture the
            // current bitmap context so every GIF frame contains the new pose.
            CGImageDestinationAddImage(gif, context.makeImage()!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.02]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        NSGraphicsContext.restoreGraphicsState()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = item.button!
        button.image = OwlLogoGeometry.templateImage
        button.imagePosition = .imageLeading
        button.title = "191.2 GB"
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let rect = button.cell!.imageRect(forBounds: button.bounds)
        precondition(!rect.isEmpty)
        var cancelCount = 0
        let cancelled = StatusLogoFeedback(button: button) { cancelCount += 1 }!
        cancelled.play()
        let owl = cancelled.layer!.sublayers![0]
        precondition(cancelled.convert(owl.frame, to: button) == rect)
        let head = owl.sublayers![1] as! CAShapeLayer
        let touch = owl.animation(forKey: "touchResponse") as! CAKeyframeAnimation
        let follow = head.animation(forKey: "clickFeedback") as! CAKeyframeAnimation
        precondition(touch.duration == follow.duration && touch.keyTimes == follow.keyTimes)
        precondition(head.path == OwlLogoGeometry.headPath())
        for (group, eye) in zip(head.sublayers!, OwlLogoGeometry.eyePaths) {
            precondition((group.mask as! CAShapeLayer).path == OwlLogoGeometry.eyeCoverMask(for: eye))
            for lid in group.sublayers! {
                let animation = lid.animation(forKey: "eyelid") as! CAKeyframeAnimation
                precondition(animation.keyPath == "transform.translation.y")
                precondition(animation.duration == touch.duration && animation.keyTimes == touch.keyTimes)
                precondition(lid.animation(forKey: "path") == nil)
            }
        }
        precondition(button.cell!.imageRect(forBounds: button.bounds) == rect)
        precondition(button.title == "191.2 GB")
        cancelled.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(button.image === OwlLogoGeometry.templateImage && cancelCount == 1)
        precondition(cancelled.superview == nil)
        let quick = StatusLogoFeedback(button: button, onFinish: {})!
        quick.beginPress()
        quick.endPress()
        precondition(!quick.isPressed)
        quick.cancel()
        precondition(button.image === OwlLogoGeometry.templateImage)
        var completed = false
        let feedback = StatusLogoFeedback(button: button, primaryButtonIsDown: { true }) { completed = true }!
        feedback.beginPress()
        let pressedOwl = feedback.layer!.sublayers![0]
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            precondition(feedback.isPressed && !completed)
            let held = pressedOwl.presentation()!.transform
            precondition(held.m22 > 0.88 && held.m22 < 0.92)
            precondition(pressedOwl.animation(forKey: "touchResponse")!.isRemovedOnCompletion == false)
            feedback.endPress()
            precondition(!feedback.isPressed)
            let release = pressedOwl.animation(forKey: "touchResponse") as! CAKeyframeAnimation
            let first = (release.values!.first as! NSValue).caTransform3DValue
            precondition(abs(first.m22 - held.m22) < 0.00001)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            app.stop(nil)
            let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
            app.postEvent(wake, atStart: false)
        }
        app.run()
        precondition(completed && button.image === OwlLogoGeometry.templateImage)
        precondition(feedback.superview == nil)
        print("PASS: bounded jelly response; fixed pupils/masks; native image alignment and text stable; quick tap, held press, continuous release, cancellation and final restoration.")
        print("Preview: \(output.path)")
        print("Motion preview: \(gifURL.path)")
    }
}

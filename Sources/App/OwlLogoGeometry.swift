import AppKit

/// Owl 06's original cubic paths in its 380×340 authoring coordinates.
/// Path data copied from Design/Branding/owl-06-flat-v2.svg; no raster tracing.
enum OwlLogoGeometry {
    private static let outlineData = "M252.688 35.875 C252.218 36.322 251.748 36.77 251.265 37.231 C248.453 40.066 246.43 42.855 244.547 46.383 C238.238 57.838 238.238 57.838 232.25 59.987 C226.249 61.368 220.018 61.527 213.886 61.755 C208.779 61.954 203.877 62.698 198.875 63.75 C198.081 63.917 197.288 64.083 196.47 64.255 C175.367 68.894 154.132 75.455 135.258 86.156 C135.028 86.286 135.028 86.286 133.868 86.942 C131.692 88.183 129.547 89.453 127.417 90.772 C121.94 94.031 121.94 94.031 119.362 93.947 C117.786 93.447 116.451 92.79 115 92 C113.891 91.535 112.777 91.079 111.66 90.633 C111.08 90.389 110.5 90.145 109.902 89.893 C99.4 85.508 88.868 81.706 77.375 81.562 C76.807 81.552 76.239 81.542 75.654 81.532 C71.616 81.618 69.246 82.58 66 85 C64.571 86.609 64.069 87.501 63.777 89.621 C64.367 96.305 68.209 104.209 73 109 C72.518 109.193 72.036 109.387 71.539 109.586 C70.907 109.846 70.276 110.107 69.625 110.375 C68.999 110.63 68.372 110.885 67.727 111.148 C66 112 66 112 64 114 C63.422 118.241 63.922 120.89 66.453 124.348 C70.248 128.401 75.032 132.516 80 135 C79.04 138.042 78.057 140.985 76.703 143.875 C72.431 153.009 69.816 162.367 67.297 172.094 C66.865 173.729 66.433 175.365 66 177 C65.849 177.608 65.698 178.215 65.543 178.841 C64.471 182.683 62.528 184.767 59.5 187.188 C43.496 200.868 29.792 219.814 27.785 241.301 C27.513 247.597 28.348 254.009 32.652 258.863 C37.4 263.069 40.506 264.172 46.812 264.125 C47.321 264.129 47.83 264.133 48.354 264.137 C52.003 264.127 55.414 263.675 59 263 C59.219 263.75 59.438 264.5 59.664 265.273 C64.533 281.269 73.533 291.777 88 300 C88.448 300.26 88.896 300.52 89.357 300.789 C110.645 312.969 137.833 317.14 162 319 C162.254 319.021 162.254 319.021 163.536 319.125 C174.027 319.969 184.478 320.202 195 320.188 C195.809 320.187 196.618 320.186 197.451 320.186 C231.282 320.117 265.278 316.047 296 301 C296.507 300.758 297.014 300.516 297.536 300.267 C319.23 289.807 337.392 270.557 346 248 C358.245 210.595 350.988 169.633 333.988 134.762 C327.734 122.48 319.989 111.418 311 101 C310.611 100.548 310.223 100.096 309.822 99.631 C305.538 94.681 301.275 89.931 296 86 C297.459 81.379 299.226 76.935 301.098 72.465 C302.69 68.115 303.155 64.054 303.188 59.438 C303.202 58.508 303.216 57.579 303.23 56.621 C302.99 53.89 302.48 52.29 301 50 C298.321 48.66 295.916 48.589 293 49 C290.887 49.822 288.947 50.84 287 52 C287.161 51.294 287.322 50.587 287.488 49.859 C289.023 41.286 288.858 30.764 284.5 23 C283 21 283 21 281 20 C269.745 18.66 260.242 28.636 252.688 35.875 Z "
    private static let leftEyeData = "M0 0 C10.236 -0.484 20.234 2.898 28.273 9.16 C36.2 16.527 36.2 16.527 37.273 21.16 C36.634 20.851 35.995 20.541 35.336 20.223 C30.742 18.445 25.858 17.396 21.055 18.816 C15.653 21.316 12.217 24.43 10.023 29.973 C8.066 36.868 9.31 42.78 12.273 49.16 C12.49 49.646 12.707 50.132 12.93 50.633 C14.824 54.319 17.526 56.557 21.273 58.16 C27.452 59.775 32.004 59.484 37.582 56.363 C39.346 55.108 40.793 53.736 42.273 52.16 C41.737 56.411 40.774 59.783 38.648 63.535 C38.515 63.772 38.515 63.772 37.841 64.969 C32.938 73.392 27.013 78.797 18.273 83.16 C17.599 83.502 16.925 83.843 16.23 84.195 C7.307 87.906 -4.646 87.592 -13.727 84.535 C-24.405 79.908 -33.108 72.916 -37.949 62.133 C-41.93 52.03 -42.416 39.802 -38.77 29.496 C-32.912 16.377 -24.861 7.655 -11.477 2.348 C-7.634 1.041 -4.025 0.373 0 0 Z "
    private static let rightEyeData = "M0 0 C1.933 1.841 3.69 3.662 5 6 C5 6.66 5 7.32 5 8 C4.383 7.821 3.765 7.642 3.129 7.457 C-3.305 5.841 -8.11 5.682 -14 9 C-18.422 12.678 -20.55 17.214 -21.219 22.84 C-21.521 29.201 -19.949 35.699 -16.125 40.875 C-12.399 44.937 -8.545 46.571 -3.117 47.062 C2.071 46.909 6.334 44.937 10 41.312 C10.68 40.554 11.353 39.787 12 39 C10.754 50.719 4.786 59.653 -4.242 67.055 C-12.937 73.574 -24.29 76.218 -35 75 C-46.015 72.971 -55.224 67.982 -62.43 59.285 C-69.78 48.589 -71.923 36.028 -69.7 23.278 C-67.038 12.697 -59.663 2.105 -50.391 -3.695 C-33.664 -13.548 -15.234 -12.053 0 0 Z "
    private static let beakData = "M0 0 C1.566 1.07 1.566 1.07 2.566 3.07 C3.527 10.11 2.222 16.285 0.254 23.008 C0.041 23.741 -0.172 24.475 -0.391 25.231 C-1.579 29.065 -2.753 32.06 -5.434 35.07 C-10.539 34.825 -10.539 34.825 -12.786 32.93 C-14.115 31.384 -15.316 29.796 -16.496 28.133 C-16.925 27.547 -17.354 26.962 -17.796 26.359 C-26.948 13.601 -26.948 13.601 -26.621 7.258 C-25.627 3.242 -22.818 1.184 -19.434 -0.93 C-12.71 -4.645 -6.509 -3.439 0 0 Z "

    static let silhouette = path(outlineData)
    private static let leftEye = path(leftEyeData, offset: CGPoint(x: 175.7265625, y: 133.83984375))
    private static let rightEye = path(rightEyeData, offset: CGPoint(x: 306, y: 124))
    private static let beak = path(beakData, offset: CGPoint(x: 247.43359375, y: 195.9296875))

    // A curved, overlapping neck join keeps the left wing in the fixed body.
    // At rest the union is exactly the original silhouette. The overlap remains
    // below the eyes/beak and conceals the join throughout the small head tilt.
    private static let headRegion = path("M0 0 C125 0 255 0 380 0 C380 80 380 160 380 237 C370 237 360 237 349 237 C283 270 82 248 66 177 C44 177 22 177 0 177 Z")
    static let headOutline = silhouette.intersection(headRegion)
    static let bodyOutline: CGPath = {
        var shift = CGAffineTransform(translationX: 0, y: -12)
        return silhouette.subtracting(headRegion.copy(using: &shift)!)
    }()

    private static let scale: CGFloat = 16 / 300.33333333333337
    static let toIcon = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
        tx: (18 - 324.5 * scale) / 2 - 27.666666666666668 * scale,
        ty: 17 + 19.833333333333332 * scale)
    static let neckPivot = CGPoint(x: 215, y: 238).applying(toIcon)

    static func iconPath(_ source: CGPath, relativeTo origin: CGPoint = .zero) -> CGPath {
        var transform = toIcon
        transform.tx -= origin.x
        transform.ty -= origin.y
        return source.copy(using: &transform)!
    }

    static func headPath() -> CGPath {
        let result = CGMutablePath()
        result.addPath(headOutline)
        result.addPath(leftEye)
        result.addPath(rightEye)
        result.addPath(beak)
        return iconPath(result, relativeTo: neckPivot)
    }

    static let eyePaths = [leftEye, rightEye].map { iconPath($0, relativeTo: neckPivot) }

    static func eyeCoverMask(for eye: CGPath) -> CGPath {
        // Cover the antialiased cutout edge too, so closed eyes have no ghost rim.
        eye.union(eye.copy(strokingWithWidth: 0.24, lineCap: .round, lineJoin: .round, miterLimit: 2))
    }

    struct Eyelids {
        let upper: CGPath
        let lower: CGPath
        let upperTravel: CGFloat
        let lowerTravel: CGFloat
    }

    /// Curved lids cover the original cutout through a fixed eye mask. The iris
    /// and pupil are never scaled, morphed, or faded. Coordinates are head-local.
    static func eyelids(for eye: CGPath) -> Eyelids {
        let box = eye.boundingBoxOfPath
        let x0 = box.minX - 0.2, x1 = box.maxX + 0.2
        let width = x1 - x0
        let center = box.minY + box.height * 0.28
        let gap: CGFloat = 0.24
        func edge(_ path: CGMutablePath, offset: CGFloat) {
            path.move(to: CGPoint(x: x0, y: center + offset + 0.14))
            path.addCurve(to: CGPoint(x: x1, y: center + offset + 0.14),
                control1: CGPoint(x: x0 + width / 3, y: center + offset - 0.14),
                control2: CGPoint(x: x1 - width / 3, y: center + offset - 0.14))
        }
        let upper = CGMutablePath(), lower = CGMutablePath()
        edge(upper, offset: gap / 2)
        upper.addLine(to: CGPoint(x: x1, y: box.maxY + 1))
        upper.addLine(to: CGPoint(x: x0, y: box.maxY + 1))
        upper.closeSubpath()
        edge(lower, offset: -gap / 2)
        lower.addLine(to: CGPoint(x: x1, y: box.minY - 1))
        lower.addLine(to: CGPoint(x: x0, y: box.minY - 1))
        lower.closeSubpath()
        return Eyelids(upper: upper, lower: lower,
            upperTravel: box.maxY - center - gap / 2 + 0.35,
            lowerTravel: center - gap / 2 - box.minY + 0.35)
    }

    static let templateImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            let ink = CGMutablePath()
            for part in [silhouette, leftEye, rightEye, beak] { ink.addPath(part) }
            context.addPath(iconPath(ink))
            context.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "套餐流量"
        return image
    }()

    /// Selected v5: coral Owl 06, soft cross eyes and a visible rounded tongue.
    /// Colored drawing preserves the eye whites, mouth and tongue in AppKit.
    static let dizzyImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let ink = dark
                ? NSColor(srgbRed: 1, green: 138.0 / 255, blue: 128.0 / 255, alpha: 1)
                : NSColor(srgbRed: 207.0 / 255, green: 81.0 / 255, blue: 73.0 / 255, alpha: 1)
            context.saveGState()
            context.setFillColor(ink.cgColor)
            let outline = iconPath(silhouette)
            context.addPath(outline)
            context.fillPath()
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.setLineWidth(0.58)
            context.setLineCap(.round)
            for (index, eye) in eyePaths.enumerated() {
                let box = eye.boundingBoxOfPath
                let center = CGPoint(x: box.midX + neckPivot.x, y: box.midY + neckPivot.y)
                let radius = min(box.width, box.height) * 0.51
                context.setFillColor(NSColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 1).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.setStrokeColor((dark ? NSColor(srgbRed: 0.58, green: 0.24, blue: 0.17, alpha: 1) : ink).cgColor)
                let r = min(box.width, box.height) * (index == 0 ? 0.22 : 0.24)
                context.move(to: CGPoint(x: center.x - r, y: center.y - r * 0.85))
                context.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y + r * 0.85),
                                     control: CGPoint(x: center.x + 0.15, y: center.y - 0.1))
                context.move(to: CGPoint(x: center.x - r * 0.85, y: center.y + r))
                context.addQuadCurve(to: CGPoint(x: center.x + r * 0.85, y: center.y - r),
                                     control: CGPoint(x: center.x - 0.1, y: center.y + 0.1))
                context.strokePath()
            }
            context.restoreGState()
            let eyes = eyePaths.map { $0.boundingBoxOfPath }
            let mouthX = (eyes[0].midX + eyes[1].midX) / 2 + neckPivot.x
            let mouthY = min(eyes[0].midY, eyes[1].midY) + neckPivot.y - 2.85
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: mouthX - 1.25, y: mouthY + 0.05))
            mouth.addCurve(to: CGPoint(x: mouthX + 1.18, y: mouthY + 0.36),
                control1: CGPoint(x: mouthX - 0.75, y: mouthY - 0.17),
                control2: CGPoint(x: mouthX + 0.66, y: mouthY - 0.15))
            mouth.addCurve(to: CGPoint(x: mouthX + 0.24, y: mouthY - 1.02),
                control1: CGPoint(x: mouthX + 1.38, y: mouthY - 0.34),
                control2: CGPoint(x: mouthX + 0.96, y: mouthY - 1.02))
            mouth.addCurve(to: CGPoint(x: mouthX - 1.25, y: mouthY + 0.05),
                control1: CGPoint(x: mouthX - 0.57, y: mouthY - 1.10),
                control2: CGPoint(x: mouthX - 1.13, y: mouthY - 0.67))
            mouth.closeSubpath()
            context.setFillColor(NSColor(srgbRed: 0.36, green: 0.15, blue: 0.13, alpha: 1).cgColor)
            context.addPath(mouth)
            context.fillPath()
            let tongue = CGMutablePath()
            tongue.move(to: CGPoint(x: mouthX - 0.50, y: mouthY - 0.59))
            tongue.addCurve(to: CGPoint(x: mouthX + 0.91, y: mouthY - 0.47),
                control1: CGPoint(x: mouthX - 0.14, y: mouthY - 0.28),
                control2: CGPoint(x: mouthX + 0.57, y: mouthY - 0.25))
            tongue.addCurve(to: CGPoint(x: mouthX + 1.01, y: mouthY - 2.26),
                control1: CGPoint(x: mouthX + 1.07, y: mouthY - 0.99),
                control2: CGPoint(x: mouthX + 1.53, y: mouthY - 1.85))
            tongue.addCurve(to: CGPoint(x: mouthX - 0.37, y: mouthY - 2.08),
                control1: CGPoint(x: mouthX + 0.65, y: mouthY - 2.77),
                control2: CGPoint(x: mouthX - 0.10, y: mouthY - 2.72))
            tongue.addCurve(to: CGPoint(x: mouthX - 0.50, y: mouthY - 0.59),
                control1: CGPoint(x: mouthX - 0.57, y: mouthY - 1.68),
                control2: CGPoint(x: mouthX - 0.46, y: mouthY - 0.99))
            tongue.closeSubpath()
            context.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.89, alpha: 1).cgColor)
            context.addPath(tongue)
            context.fillPath()
            context.setStrokeColor(NSColor(srgbRed: 0.62, green: 0.24, blue: 0.27, alpha: 1).cgColor)
            context.setLineWidth(0.20)
            context.addPath(tongue)
            context.strokePath()
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        image.accessibilityDescription = "需要留意"
        return image
    }()

    /// Deliberately supports only M/C/Z, the commands present in this fixed source.
    /// A changed source must fail visibly rather than silently distort the brand.
    private static func path(_ data: String, offset: CGPoint = .zero) -> CGPath {
        let scanner = Scanner(string: data)
        let result = CGMutablePath()
        func point() -> CGPoint {
            guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else {
                preconditionFailure("Invalid owl path coordinates")
            }
            return CGPoint(x: x + offset.x, y: y + offset.y)
        }
        while !scanner.isAtEnd {
            guard let command = scanner.scanCharacters(from: .letters) else {
                preconditionFailure("Invalid owl path command")
            }
            switch command {
            case "M": result.move(to: point())
            case "C":
                let control1 = point(), control2 = point(), end = point()
                result.addCurve(to: end, control1: control1, control2: control2)
            case "Z": result.closeSubpath()
            default: preconditionFailure("Unsupported owl path command: \(command)")
            }
        }
        return result
    }
}

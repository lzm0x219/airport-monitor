import AppKit
import QuartzCore

/// Native input and title layout remain on the status button. Only the temporary
/// owl overlay responds to one shared touch impulse through its coupled layers.
@MainActor
final class StatusLogoFeedback: NSView, CAAnimationDelegate {
    private weak var button: NSStatusBarButton?
    private let originalImage: NSImage
    private let placeholder: NSImage
    private let owl = CALayer()
    private let body = CAShapeLayer()
    private let head = CAShapeLayer()
    private var eyelids: [(upper: CAShapeLayer, lower: CAShapeLayer, upperTravel: CGFloat, lowerTravel: CGFloat)] = []
    private var onFinish: (() -> Void)?
    private let response: OwlTouchResponse.Response
    private let primaryButtonIsDown: () -> Bool
    private var recoveryTimer: Timer?
    private var playbackDeadline: CFTimeInterval?
    private var pressStartedAt: CFTimeInterval = 0
    private(set) var isPressed = false

    init?(button: NSStatusBarButton,
          primaryButtonIsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
          onFinish: @escaping () -> Void) {
        guard let image = button.image, let cell = button.cell else { return nil }
        let rect = cell.imageRect(forBounds: button.bounds)
        guard !rect.isEmpty else { return nil }
        originalImage = image
        placeholder = NSImage(size: image.size)
        self.button = button
        self.onFinish = onFinish
        self.primaryButtonIsDown = primaryButtonIsDown
        var generator = SystemRandomNumberGenerator()
        response = OwlTouchResponse.makeResponse(using: &generator)
        // Give the widened jelly silhouette breathing room without changing the
        // native image slot or moving the balance text.
        super.init(frame: rect.insetBy(dx: -2, dy: -1))
        setAccessibilityElement(false)
        // Inserting the lids must not implicitly animate them out of the eye
        // before the explicit click animation starts.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wantsLayer = true
        owl.anchorPoint = CGPoint(x: 0.5, y: 1.0 / 18)
        owl.frame = CGRect(origin: CGPoint(x: 2, y: 1), size: rect.size)
        layer?.addSublayer(owl)
        body.frame = owl.bounds
        body.path = OwlLogoGeometry.iconPath(OwlLogoGeometry.bodyOutline)
        head.bounds = CGRect(x: -9, y: -9, width: 18, height: 18)
        head.position = OwlLogoGeometry.neckPivot
        head.path = OwlLogoGeometry.headPath()
        head.fillRule = .evenOdd
        for shape in [body, head] {
            shape.contentsScale = button.window?.backingScaleFactor ?? 2
            shape.allowsEdgeAntialiasing = true
            owl.addSublayer(shape)
        }
        for eye in OwlLogoGeometry.eyePaths {
            let group = CALayer()
            group.bounds = head.bounds
            group.position = .zero
            let mask = CAShapeLayer()
            mask.bounds = head.bounds
            mask.position = .zero
            mask.path = OwlLogoGeometry.eyeCoverMask(for: eye)
            mask.fillColor = NSColor.black.cgColor
            mask.contentsScale = head.contentsScale
            group.mask = mask
            head.addSublayer(group)
            let geometry = OwlLogoGeometry.eyelids(for: eye)
            let upper = CAShapeLayer(), lower = CAShapeLayer()
            for (lid, path) in [(upper, geometry.upper), (lower, geometry.lower)] {
                lid.bounds = head.bounds
                lid.position = .zero
                lid.path = path
                lid.contentsScale = head.contentsScale
                group.addSublayer(lid)
            }
            upper.transform = CATransform3DMakeTranslation(0, geometry.upperTravel, 0)
            lower.transform = CATransform3DMakeTranslation(0, -geometry.lowerTravel, 0)
            eyelids.append((upper, lower, geometry.upperTravel, geometry.lowerTravel))
        }
        CATransaction.commit()
        updateInk()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateInk()
    }

    private func updateInk() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let ink = (button?.isHighlighted == true ? NSColor.selectedMenuItemTextColor : NSColor.labelColor).cgColor
            body.fillColor = ink
            head.fillColor = ink
            for lids in eyelids {
                lids.upper.fillColor = ink
                lids.lower.fillColor = ink
            }
            CATransaction.commit()
        }
    }

    func play() {
        attach()
        animate(response.samples, duration: response.duration)
    }

    func beginPress() {
        guard !isPressed else { return }
        isPressed = true
        pressStartedAt = CACurrentMediaTime()
        attach()
        animate(Array(response.samples.prefix(response.pressEndIndex + 1)),
                duration: response.pressDuration, hold: true)
        // AppKit can remain inside button tracking after this action returns.
        CATransaction.flush()
    }

    func endPress() {
        guard isPressed else { return }
        isPressed = false
        let elapsed = min(max(0, CACurrentMediaTime() - pressStartedAt), response.pressDuration)
        let index = min(response.pressEndIndex,
            Int(elapsed / response.duration * Double(response.samples.count - 1)))
        updateInk()
        animate(Array(response.samples[index...]), duration: response.duration - elapsed,
                continueFromPresentation: true)
        DispatchQueue.main.async { [weak self] in self?.updateInk() }
    }

    private func attach() {
        guard let button else { return }
        if superview == nil { button.addSubview(self) }
        button.image = placeholder // Keep the native image slot and balance text fixed.
        updateInk()
        if recoveryTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    if self.isPressed {
                        // A status item can lose its mouse-up action during native
                        // tracking. A real held button must never time out.
                        if !self.primaryButtonIsDown() {
                            if let button = self.button, let window = button.window,
                               button.bounds.contains(button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) {
                                self.endPress()
                            } else {
                                self.cancel()
                            }
                        }
                    } else if let deadline = self.playbackDeadline, CACurrentMediaTime() >= deadline {
                        // Restore even if CA's completion delegate is interrupted.
                        self.cancel()
                    }
                }
            }
            recoveryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func animate(_ samples: [OwlTouchResponse.Sample], duration: CFTimeInterval,
                         hold: Bool = false, continueFromPresentation: Bool = false) {
        playbackDeadline = hold ? nil : CACurrentMediaTime() + duration + 0.15
        var bodyMotion = samples.map { sample -> NSValue in
            var transform = CATransform3DMakeScale(sample.scaleX, sample.scaleY, 1)
            transform.m41 = sample.bodyX
            transform.m42 = sample.bodyY
            return NSValue(caTransform3D: transform)
        }
        if continueFromPresentation, let transform = owl.presentation()?.transform {
            bodyMotion[0] = NSValue(caTransform3D: transform)
        }
        owl.add(sampled("transform", values: bodyMotion, duration: duration, hold: hold), forKey: "touchResponse")
        var headMotion = samples.map { sample -> NSValue in
            var transform = CATransform3DMakeRotation(.pi / 180 * sample.headAngle, 0, 0, 1)
            transform.m41 = sample.headX
            transform.m42 = sample.headY
            return NSValue(caTransform3D: transform)
        }
        if continueFromPresentation, let transform = head.presentation()?.transform {
            headMotion[0] = NSValue(caTransform3D: transform)
        }
        let reaction = sampled("transform", values: headMotion, duration: duration, hold: hold)
        if !hold { reaction.delegate = self }
        head.add(reaction, forKey: "clickFeedback")
        for (index, lids) in eyelids.enumerated() {
            for (lid, start, upper) in [(lids.upper, lids.upperTravel, true), (lids.lower, -lids.lowerTravel, false)] {
                var positions = samples.map { sample in
                    let closure = index == 0
                        ? (upper ? sample.upperClosure : sample.lowerClosure)
                        : (upper ? sample.rightUpperClosure : sample.rightLowerClosure)
                    return start * (1 - closure)
                }
                if continueFromPresentation, let transform = lid.presentation()?.transform {
                    positions[0] = transform.m42
                }
                lid.add(sampled("transform.translation.y", values: positions, duration: duration, hold: hold), forKey: "eyelid")
            }
        }
    }

    private func sampled(_ key: String, values: [Any], duration: CFTimeInterval, hold: Bool) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        animation.calculationMode = .linear // The response already contains its physical timing.
        animation.duration = duration
        if hold {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        return animation
    }

    func cancel() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        playbackDeadline = nil
        isPressed = false
        let finish = onFinish
        onFinish = nil
        if button?.image === placeholder { button?.image = originalImage }
        removeFromSuperview()
        for part in [owl, body, head] { part.removeAllAnimations() }
        for lids in eyelids {
            lids.upper.removeAllAnimations()
            lids.lower.removeAllAnimations()
        }
        finish?()
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        Task { @MainActor [weak self] in self?.cancel() }
    }
}

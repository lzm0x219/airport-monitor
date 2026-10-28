import Foundation

/// Randomness is chosen once per click. A smooth touch drives the body/head;
/// reflex blinks start later, with irregular gaps and slightly different depths.
enum OwlTouchResponse {
    struct Sample {
        let compression: Double
        let bodyX: Double
        let bodyY: Double
        let headAngle: Double
        let headX: Double
        let headY: Double
        let upperClosure: Double
        let lowerClosure: Double
        let rightUpperClosure: Double
        let rightLowerClosure: Double
        // Signed displacement gives several diminishing squash/stretch rebounds.
        // Both axes share the same elastic response.
        var scaleX: Double { 1 + 0.050 * compression }
        var scaleY: Double { 1 - 0.110 * compression }
        static let rest = Sample(compression: 0, bodyX: 0, bodyY: 0, headAngle: 0,
            headX: 0, headY: 0, upperClosure: 0, lowerClosure: 0,
            rightUpperClosure: 0, rightLowerClosure: 0)
    }

    struct Blink {
        let start: Double
        let closing: Double
        let opening: Double
        let depth: Double
        var end: Double { start + closing + opening }

        func closure(at time: Double) -> Double {
            let elapsed = time - start
            guard elapsed > 0, time < end else { return 0 }
            // One asymmetric, rounded pulse: no close/hold/open corners or plateau.
            // Its peak follows closing/(closing+opening), with zero slope at both ends.
            let progress = elapsed / (closing + opening)
            let peak = closing / (closing + opening)
            let a = 2.0, b = 2 * opening / closing
            return depth * exp(a * log(progress / peak) + b * log((1 - progress) / (1 - peak)))
        }
    }

    struct Response {
        let duration: Double
        let pressEndIndex: Int
        let headDelay: Double
        let rightEyeDelay: Double
        let blinks: [Blink]
        let samples: [Sample]
        var pressDuration: Double { duration * Double(pressEndIndex) / Double(samples.count - 1) }
    }

    static func makeResponse<R: RandomNumberGenerator>(using generator: inout R) -> Response {
        let pulse = Double.random(in: 0.120...0.170, using: &generator)
        let strength = Double.random(in: 0.84...1.05, using: &generator)
        let bodyStiffness = Double.random(in: 220...270, using: &generator)
        let bodyDamping = Double.random(in: 4.5...5.5, using: &generator)
        let neckStiffness = Double.random(in: 75...90, using: &generator)
        let neckDamping = Double.random(in: 13...16, using: &generator)
        let headMass = Double.random(in: 0.50...0.60, using: &generator)
        let direction = Bool.random(using: &generator) ? 1.0 : -1.0
        let turn = Int.random(in: 0..<8, using: &generator) == 0
            ? Double.random(in: 0.2...0.65, using: &generator) : 0
        let nod = Double.random(in: 0.02...0.06, using: &generator)
        let lean = Double.random(in: 0.04...0.09, using: &generator)
        let headDelay = Double.random(in: 0.040...0.070, using: &generator)
        let relaxation = Double.random(in: 0.085...0.130, using: &generator)
        let rightDelay = Double.random(in: 0.008...0.023, using: &generator)
        let rightDepth = Double.random(in: 0.94...1.02, using: &generator)
        let choice = Int.random(in: 0..<10, using: &generator)
        let blinkCount = choice < 2 ? 1 : (choice < 8 ? 2 : 3)
        let dt = 1.0 / 240
        let horizon = 864 // 3.6s covers the longest possible three-blink response.
        var body = 0.0, head = 0.0, bodyVelocity = 0.0, headVelocity = 0.0
        var largestCompression = 0.0
        var states: [(body: Double, head: Double, lag: Double)] = []
        for index in 0...horizon {
            let time = Double(index) * dt
            states.append((body, head, body - head))
            largestCompression = max(largestCompression, body)
            // A softening spring preserves the initial press but stretches the
            // later half-periods as energy falls. No separately timed bounces.
            let deformation = largestCompression > 1e-9 ? min(1, abs(body) / largestCompression) : 1
            let stiffness = bodyStiffness * (0.52 + 0.48 * deformation)
            let push = time < pulse ? 150 * pow(sin(.pi * time / pulse), 2) : 0
            let neckForce = neckStiffness * (head - body) + neckDamping * (headVelocity - bodyVelocity)
            let bodyAcceleration = push - stiffness * body - bodyDamping * bodyVelocity + neckForce
            let headAcceleration = -neckForce / headMass
            bodyVelocity += bodyAcceleration * dt
            headVelocity += headAcceleration * dt
            body += bodyVelocity * dt
            head += headVelocity * dt
        }
        let bodyPeak = states.map { $0.body }.max()!
        let pressEndIndex = states.indices.max { states[$0].body < states[$1].body }!
        let headPeak = states.map { $0.head }.max()!
        let lagPeak = states.map { abs($0.lag) }.max()!
        let bodies = states.map { $0.body }
        let lags = states.map { $0.lag }
        // Let the head lazily follow instead of replaying a normalized up/down arc.
        var follow = 0.0
        let alpha = 1 - exp(-dt / relaxation)
        let follows = states.map { state -> Double in
            follow += (state.head / headPeak - follow) * alpha
            return follow
        }
        let blinkPhase = Double.random(in: 0.18...0.30, using: &generator)
        let phaseIndex = follows.firstIndex { $0 >= blinkPhase }!
        var blinks: [Blink] = []
        // Blink while the head is still drifting into its response, not after it arrives.
        var nextBlink = max(Double(pressEndIndex) * dt + Double.random(in: 0.03...0.07, using: &generator),
            Double(phaseIndex) * dt + headDelay + Double.random(in: -0.012...0.016, using: &generator))
        for index in 0..<blinkCount {
            let blink = Blink(start: nextBlink,
                closing: Double.random(in: 0.08...0.14, using: &generator),
                opening: Double.random(in: 0.18...0.30, using: &generator),
                depth: Double.random(in: index == 0 ? 0.38...0.60 : 0.48...0.76, using: &generator))
            blinks.append(blink)
            nextBlink = blink.end + Double.random(in: 0.13...0.38, using: &generator)
        }
        let steps = Int(ceil(max(2.6, blinks.last!.end + rightDelay + 0.30) / dt))
        let duration = Double(steps) * dt
        var samples = states.prefix(steps + 1).enumerated().map { index, state in
            let time = Double(index) * dt
            let delayedTime = time - headDelay
            let position = max(0, delayedTime / dt)
            let lower = min(horizon - 1, Int(position))
            let fraction = position - Double(lower)
            func delayed(_ values: [Double]) -> Double {
                guard delayedTime > 0 else { return 0 }
                return values[lower] + (values[lower + 1] - values[lower]) * fraction
            }
            let compression = strength * state.body / bodyPeak
            let follow = delayed(follows)
            let delayedBody = delayed(bodies) / bodyPeak
            let lag = delayed(lags) / lagPeak
            func eye(_ time: Double) -> Double {
                blinks.map { $0.closure(at: time) }.max() ?? 0
            }
            return Sample(compression: compression,
                bodyX: direction * lean * compression, bodyY: -0.05 * compression,
                headAngle: direction * turn * follow,
                headX: direction * 0.05 * (follow - delayedBody),
                headY: -nod * follow - 0.015 * lag + 0.35 * (follow - delayedBody),
                upperClosure: eye(time), lowerClosure: eye(time - 0.012) * 0.24,
                rightUpperClosure: min(0.90, eye(time - rightDelay) * rightDepth),
                rightLowerClosure: min(0.90, eye(time - rightDelay - 0.012) * rightDepth) * 0.24)
        }
        samples[samples.count - 1] = .rest
        return Response(duration: duration, pressEndIndex: pressEndIndex, headDelay: headDelay, rightEyeDelay: rightDelay,
                        blinks: blinks, samples: samples)
    }
}

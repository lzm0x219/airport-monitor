import Foundation

/// An explicit UI-review entry point. Every credential, request and notification
/// dependency is isolated, while the actual repository and production views run.
@MainActor
enum WorkspaceReviewSupport {
    private final class Environment {
        var credentials: [String: String] = [:]
        var failures = Set<String>()
        var used: [String: UInt64] = [:]
        var failSave = false
        var notifications = 0
        var requests = 0
    }

    static func make() throws -> AirportWorkspace {
        if CommandLine.arguments.contains("--workspace-review-many") { return try makeMany() }
        let environment = Environment()
        let slowSync = CommandLine.arguments.contains("--slow-sync-review")
        let samplingSnapshot = CommandLine.arguments.contains("--sampling-forecast-review")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AirportWorkspaceReview-\(UUID())")
        let defaults = UserDefaults(suiteName: "AirportWorkspaceReview.\(UUID())")!
        defaults.set(5, forKey: "intervalMinutes")
        let now = Date()
        var services = MonitorServices(
            readCredential: { environment.credentials[$0] },
            saveCredential: { environment.credentials[$1] = $0 },
            deleteCredential: { environment.credentials.removeValue(forKey: $0) },
            fetch: { url in
                environment.requests += 1
                let request = environment.requests
                if slowSync { print("Isolated mock request \(request) started") }
                defer { if slowSync { print("Isolated mock request \(request) ended") } }
                try await Task.sleep(for: .milliseconds(slowSync ? 30_000 : 600))
                if url.path.contains("failure") { throw TrafficError.network(-1009) }
                let key = url.host ?? "example.invalid"
                let used = (environment.used[key] ?? 42_000_000_000) + 120_000_000
                environment.used[key] = used
                return try Subscription(upload: 2_000_000_000, download: used, total: 200_000_000_000,
                                        expiry: Date().addingTimeInterval(15 * 86400))
            }, notificationAuthorizationStatus: { .authorized }, requestNotificationAuthorization: { false })
        services.reminderServices = ReminderServices(authorizationStatus: { .authorized },
            send: { _, _, _ in environment.notifications += 1 }, queryAcceptance: { _ in .unknown })
        if CommandLine.arguments.contains("--request-limit-review") || slowSync || samplingSnapshot {
            let gate = SubscriptionRequestGate(storeURL: root.appendingPathComponent("request-review.json"))
            let transport = services.fetch
            services.nextSubscriptionRequest = { try gate.nextAllowedDate(for: $0, observedAttempt: $1) }
            services.fetch = { url in
                try gate.reserve(url)
                return try await transport(url)
            }
        }
        let workspace = AirportWorkspace(defaults: defaults, historyDirectory: root, services: services,
            startAutomatically: false, isolatedReview: true, checkpoint: { point in
                if environment.failSave && point == .beforePublish {
                    environment.failSave = false
                    throw TrafficError.storage
                }
            })
        guard let repository = workspace.repository else { throw TrafficError.storage }
        var rule = ResetRule(); rule.kind = .monthly
        rule.day = Calendar.current.component(.day, from: now.addingTimeInterval(7 * 86400))
        let names = ["云海机场", "星河 · 长名称与同步失败状态检查的备用机场", "轻旅机场"]
        for index in 0..<3 {
            let airportRule = index == 0 && CommandLine.arguments.contains("--missing-reset-review") ? ResetRule() : rule
            let url = "https://review-\(index).example.invalid/" + (index == 1 ? "failure" : "subscription")
            let profile = try repository.saveAirport(profile: nil, name: names[index], plan: "月付 · 200 GB",
                subscription: url, reset: airportRule, threshold: 10)
            var source = repository.source(for: profile.id)!
            var ledger = Ledger()
            let count = samplingSnapshot ? (index == 2 ? 1 : 5) : (index == 2 ? 1 : 8 * 24)
            for offset in 0..<count {
                // Slow-response review must qualify through the real 72-hour gate.
                let date = now.addingTimeInterval(Double(offset - count + 1) * (samplingSnapshot ? 72 * 3600 : 3600) - 30 - (samplingSnapshot ? 36 * 3600 : 0) - (slowSync ? 73 * 3600 : 0))
                let used: UInt64 = CommandLine.arguments.contains("--daily-zero-review") && index == 0 ? 30_000_000_000 : index == 0 ? 30_000_000_000 + UInt64(offset) * (samplingSnapshot ? 7_200_000_000 : 400_000_000) : 150_000_000_000 + UInt64(offset) * (samplingSnapshot ? 2_000_000_000 : 120_000_000)
                try ledger.append(Subscription(upload: 2_000_000_000, download: used, total: 200_000_000_000,
                    expiry: now.addingTimeInterval(Double(index == 1 ? 2 : 20) * 86400)), at: date)
                environment.used["review-\(index).example.invalid"] = used
            }
            source.ledger = ledger; source.needsVerification = false
            source.resetRevisions = [ResetRevision(effectiveAt: nil, rule: airportRule)]
            try repository.updateSource(source)
        }
        // Reopen through the normal migration/loading path, using the same isolated services.
        let result = AirportWorkspace(defaults: defaults, historyDirectory: root, services: services,
            startAutomatically: false, isolatedReview: true, checkpoint: { point in
                if environment.failSave && point == .beforePublish {
                    environment.failSave = false; throw TrafficError.storage
                }
            })
        if CommandLine.arguments.contains("--save-error-review") { environment.failSave = true }
        if CommandLine.arguments.contains("--dark") { result.setAppearance(.dark) }
        if CommandLine.arguments.contains("--light") { result.setAppearance(.light) }
        if CommandLine.arguments.contains("--review-panel-overview") { result.setMenuPanelLayout(.overview) }
        return result
    }

    /// A single synthetic state publication avoids measuring 100 sequential
    /// settings saves while preparing the 100-airport scrolling fixture.
    private static func makeMany() throws -> AirportWorkspace {
        let configuration = try WorkspaceScaleFixture.Configuration(arguments: CommandLine.arguments)
        let generatedAt = Date()
        let started = ContinuousClock.now
        let fixture = try WorkspaceScaleFixture.generate(configuration: configuration, now: generatedAt)
        let generationMilliseconds = WorkspaceScaleFixture.milliseconds(since: started)
        let environment = Environment()
        environment.credentials = fixture.credentials; environment.used = fixture.usedByHost
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AirportWorkspaceReview-Many-\(UUID())")
        let directory = root.appendingPathComponent("native-v2", isDirectory: true)
        let stateURL = directory.appendingPathComponent("state.json")
        let writeStarted = ContinuousClock.now
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let state = try JSONEncoder().encode(fixture.snapshot)
        try state.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let encodeAndWriteMilliseconds = WorkspaceScaleFixture.milliseconds(since: writeStarted)
        let defaults = UserDefaults(suiteName: "AirportWorkspaceReview.Many.\(UUID())")!
        defaults.set(5, forKey: "intervalMinutes")
        defaults.set(false, forKey: "remindersEnabled")
        var services = MonitorServices(
            readCredential: { environment.credentials[$0] },
            saveCredential: { environment.credentials[$1] = $0 },
            deleteCredential: { environment.credentials.removeValue(forKey: $0) },
            fetch: { url in
                try await Task.sleep(for: .milliseconds(600))
                if url.path.contains("failure") { throw TrafficError.network(-1009) }
                let key = url.host ?? "example.invalid"
                let used = (environment.used[key] ?? 42_000_000_000) + 120_000_000
                environment.used[key] = used
                return try Subscription(upload: 2_000_000_000, download: used, total: 200_000_000_000,
                                        expiry: Date().addingTimeInterval(15 * 86400))
            }, notificationAuthorizationStatus: { .authorized }, requestNotificationAuthorization: { false })
        services.reminderServices = ReminderServices(authorizationStatus: { .authorized },
            send: { _, _, _ in environment.notifications += 1 }, queryAcceptance: { _ in .unknown })
        let loadStarted = ContinuousClock.now
        let workspace = AirportWorkspace(defaults: defaults, historyDirectory: root, services: services,
            startAutomatically: false, isolatedReview: true, checkpoint: { point in
                if environment.failSave && point == .beforePublish { environment.failSave = false; throw TrafficError.storage }
            })
        let modelLoadMilliseconds = WorkspaceScaleFixture.milliseconds(since: loadStarted)
        guard !workspace.catalogBlocked, workspace.profiles.count == configuration.airports else { throw TrafficError.storage }
        if CommandLine.arguments.contains("--save-error-review") { environment.failSave = true }
        if CommandLine.arguments.contains("--dark") { workspace.setAppearance(.dark) }
        if CommandLine.arguments.contains("--light") { workspace.setAppearance(.light) }
        let report = WorkspaceScaleFixture.TimingReport(generatedAt: generatedAt, configuration: configuration,
            samples: fixture.samples, longNames: fixture.longNames, paused: fixture.paused,
            failureTargets: fixture.failureTargets, insufficientHistory: fixture.insufficientHistory,
            stateBytes: state.count, generationMilliseconds: generationMilliseconds,
            encodeAndWriteMilliseconds: encodeAndWriteMilliseconds, modelLoadMilliseconds: modelLoadMilliseconds,
            fixtureRoot: root.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)
        try reportData.write(to: root.appendingPathComponent("scale-metrics.json"), options: .atomic)
        FileHandle.standardOutput.write(Data("WORKSPACE_SCALE_METRICS\n".utf8))
        FileHandle.standardOutput.write(reportData); FileHandle.standardOutput.write(Data("\n".utf8))
        return workspace
    }
}

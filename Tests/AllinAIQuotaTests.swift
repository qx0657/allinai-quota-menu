import Darwin

// All credentials are generated at runtime. Tests never read the real Keychain or app data.
final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func set(_ password: String, account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = password }
    func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
    func contains(account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[account] != nil }
}

struct Reply {
    var status = 200
    var data: Any = ["code": 0, "data": [:]]
    var error: URLError?
    var delay: TimeInterval = 0
    var headers: [String: String] = [:]
}

final class MockHTTP: @unchecked Sendable {
    static let routingLock = NSLock()
    static var current: MockHTTP?
    static func install(_ router: MockHTTP) {
        routingLock.lock()
        defer { routingLock.unlock() }
        current = router
    }
    private let lock = NSLock()
    private var requests: [String: Int] = [:]
    private var lastRequests: [String: URLRequest] = [:]
    private var handler: (URLRequest, Int) -> Reply
    init(_ handler: @escaping (URLRequest, Int) -> Reply) { self.handler = handler }
    func change(_ handler: @escaping (URLRequest, Int) -> Reply) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[path] ?? 0 }
    func lastRequest(_ path: String) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return lastRequests[path] }
    func reply(_ request: URLRequest) -> Reply {
        let path = request.url!.path.replacingOccurrences(of: "/api/v1/", with: "")
        lock.lock()
        requests[path, default: 0] += 1
        lastRequests[path] = request
        let count = requests[path]!
        let handler = handler
        lock.unlock()
        return handler(request, count)
    }
}

final class MockProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        MockHTTP.routingLock.lock()
        let router = MockHTTP.current!
        MockHTTP.routingLock.unlock()
        let reply = router.reply(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.data))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); defer { lock.unlock() }; stopped = true }
}

enum Fixtures {
    static let email = "person@example.invalid"
    static let access = UUID().uuidString
    static let refresh = UUID().uuidString
    static let freshAccess = UUID().uuidString
    static let timestamp = ISO8601DateFormatter()
    static func release(_ tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": "https://example.invalid/untrusted"]
    }
    static func rawSubscription(status: String = "active", daily: Double? = 3.8, weekly: Double? = 21,
                                dailyLimit: Double? = 12, weeklyLimit: Double? = 84, expires: TimeInterval = 172800) -> [String: Any] {
        var group: [String: Any] = ["name": "订阅卡（12刀）", "platform": "openai", "description": "用于验证额度、时间与原生界面。"]
        if let dailyLimit { group["daily_limit_usd"] = dailyLimit }
        if let weeklyLimit { group["weekly_limit_usd"] = weeklyLimit }
        var sub: [String: Any] = ["id": 1, "status": status, "group": group,
                                  "starts_at": timestamp.string(from: Date().addingTimeInterval(-3600)),
                                  "expires_at": timestamp.string(from: Date().addingTimeInterval(expires)),
                                  "daily_window_start": timestamp.string(from: Date().addingTimeInterval(-18000)),
                                  "weekly_window_start": timestamp.string(from: Date().addingTimeInterval(-86400))]
        if let daily { sub["daily_usage_usd"] = daily }
        if let weekly { sub["weekly_usage_usd"] = weekly }
        return sub
    }
    static func sub(_ raw: [String: Any]) throws -> Subscription {
        try JSONDecoder().decode(Subscription.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    static func profile(_ balance: Double? = 49.99) -> UserProfile { UserProfile(username: "fixture-account", email: email, balance: balance) }
    static func normal(_ request: URLRequest, _ count: Int) -> Reply {
        if request.url!.path.hasSuffix("subscriptions") { return Reply(data: ["code": 0, "data": [rawSubscription()]]) }
        if request.url!.path.hasSuffix("profile") {
            return Reply(data: ["code": 0, "data": ["username": "fixture-account", "balance": 49.99]])
        }
        return Reply(data: ["code": 0, "data": ["access_token": freshAccess, "refresh_token": refresh, "expires_in": 3600]])
    }
}

struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        if Date() > deadline { throw TestFailure(description: "Timed out waiting for controlled request") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

struct Rig {
    let client: AllinClient
    let storage: LocalStorage
    let credentials: MemoryCredentials
    let http: MockHTTP
    let defaults: UserDefaults
    let suite: String
    func cleanup() {
        try? FileManager.default.removeItem(at: storage.directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

func makeRig(expiredToken: Bool = false, handler: @escaping (URLRequest, Int) -> Reply = Fixtures.normal) async throws -> Rig {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("allinai-tests-\(UUID().uuidString)", isDirectory: true)
    let credentials = MemoryCredentials()
    try credentials.set(UUID().uuidString, account: Fixtures.email)
    let storage = LocalStorage(directory: directory, credentials: credentials)
    try storage.saveConfig(Config(email: Fixtures.email, refreshIntervalSeconds: 300))
    try storage.saveTokens(TokenCache(accessToken: Fixtures.access, refreshToken: Fixtures.refresh,
                                     expiresAt: Date().timeIntervalSince1970 + (expiredToken ? -10 : 3600), account: Fixtures.email))
    let router = MockHTTP(handler)
    MockHTTP.install(router)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockProtocol.self]
    let client = AllinClient(storage: storage, session: URLSession(configuration: configuration))
    _ = try await client.configuration()
    let suite = "allinai-tests-\(UUID().uuidString)"
    return Rig(client: client, storage: storage, credentials: credentials, http: router, defaults: UserDefaults(suiteName: suite)!, suite: suite)
}

@MainActor
struct UpdateRig {
    let checker: UpdateChecker
    let client: ReleaseClient
    let http: MockHTTP
    let defaults: UserDefaults
    let suite: String
    func cleanup() { checker.stop(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor
func makeUpdateRig(handler: @escaping (URLRequest, Int) -> Reply = { _, _ in Reply(data: Fixtures.release()) }) -> UpdateRig {
    let router = MockHTTP(handler)
    MockHTTP.install(router)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockProtocol.self]
    let client = ReleaseClient(session: URLSession(configuration: configuration))
    let suite = "allinai-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return UpdateRig(checker: UpdateChecker(client: client, defaults: defaults, currentVersion: "0.2.0"),
                     client: client, http: router, defaults: defaults, suite: suite)
}

@main
struct TestRunner {
    @MainActor static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            do { try await renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) }
            catch { print("Preview export failed: \(error)"); exit(1) }
            return
        }
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("Release versions compare numerically and reject unsupported tags", {
                try expect(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.9")!, "Compare numeric components, not text")
                try expect(ReleaseVersion("v1.0.0")! > ReleaseVersion("0.99.99")!, "Compare major version first")
                try expect(ReleaseVersion("v0.2.0") == ReleaseVersion("0.2.0"), "Accept optional v prefix")
                for tag in ["", "v0.3.0-rc.1", "release-0.3.0", "0.2", "0.2.0.1", "0.-1.0", "0.02.0", "0..0", "999999999999999999999.0.0"] {
                    try expect(ReleaseVersion(tag) == nil, "Reject ambiguous or non-stable version: \(tag)")
                }
            }),
            ("Update check uses public GitHub API and trusted repository links", {
                let rig = makeUpdateRig()
                defer { rig.cleanup() }
                var manualResults = 0
                rig.checker.onManualResult = { _ in manualResults += 1 }
                rig.checker.check()
                await rig.checker.task?.value
                guard case .available(let release) = rig.checker.state else { throw TestFailure(description: "Expected available update") }
                try expect(release.pageURL.absoluteString == "https://github.com/qx0657/allinai-quota-menu/releases/tag/v0.3.0", "Never follow response-supplied URLs")
                let request = rig.http.lastRequest(AppInfo.latestReleaseAPI.path)
                try expect(request?.url == AppInfo.latestReleaseAPI, "Use this macOS repository")
                try expect(request?.value(forHTTPHeaderField: "Authorization") == nil, "No account or GitHub credentials")
                try expect(request?.httpBody == nil && request?.url?.query == nil, "No account data in update request")
                try expect(request?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("AllinAI-Quota/") == true, "Identify application to GitHub")
                try expect(rig.checker.lastChecked != nil && manualResults == 1, "Save successful check and deliver manual result once")
            }),
            ("Same and older GitHub releases never offer a downgrade", {
                for tag in ["v0.2.0", "v0.1.0"] {
                    let rig = makeUpdateRig { _, _ in Reply(data: Fixtures.release(tag)) }
                    defer { rig.cleanup() }
                    rig.checker.check()
                    await rig.checker.task?.value
                    guard case .current = rig.checker.state else { throw TestFailure(description: "Expected current version for \(tag)") }
                    try expect(rig.checker.availableRelease == nil, "Never offer an older version")
                }
            }),
            ("Missing, draft and prerelease releases remain distinct from up to date", {
                let replies = [Reply(status: 404), Reply(data: Fixtures.release(draft: true)), Reply(data: Fixtures.release(prerelease: true))]
                for reply in replies {
                    let rig = makeUpdateRig { _, _ in reply }
                    defer { rig.cleanup() }
                    rig.checker.check()
                    await rig.checker.task?.value
                    guard case .noRelease = rig.checker.state else { throw TestFailure(description: "Do not claim latest version without a stable release") }
                }
            }),
            ("Invalid release data and tags produce actionable failures", {
                for (reply, expected) in [(Reply(data: ["message": "unexpected"]), UpdateError.invalidResponse),
                                          (Reply(data: Fixtures.release("v0.3.0-rc.1")), .invalidVersion)] {
                    let rig = makeUpdateRig { _, _ in reply }
                    defer { rig.cleanup() }
                    rig.checker.check()
                    await rig.checker.task?.value
                    guard case .failed(let error) = rig.checker.state else { throw TestFailure(description: "Expected invalid release failure") }
                    try expect(error == expected && rig.checker.lastChecked == nil, "Do not record invalid responses as successful checks")
                }
            }),
            ("Update network, timeout and server failures retain their causes", {
                for (reply, expected) in [(Reply(error: URLError(.notConnectedToInternet)), UpdateError.network),
                                          (Reply(error: URLError(.timedOut)), .timedOut), (Reply(status: 503), .server(503)),
                                          (Reply(status: 403), .server(403))] {
                    let rig = makeUpdateRig { _, _ in reply }
                    defer { rig.cleanup() }
                    rig.checker.check()
                    await rig.checker.task?.value
                    guard case .failed(let error) = rig.checker.state else { throw TestFailure(description: "Expected update failure") }
                    try expect(error == expected, "Preserve network vs service vs forbidden causes")
                }
            }),
            ("Concurrent update clicks share one request", {
                let rig = makeUpdateRig { _, _ in Reply(data: Fixtures.release(), delay: 0.08) }
                defer { rig.cleanup() }
                rig.checker.check()
                rig.checker.check()
                rig.checker.checkAutomaticallyIfNeeded()
                try expect(rig.checker.isChecking, "Expose loading state immediately")
                await rig.checker.task?.value
                try expect(rig.http.count(AppInfo.latestReleaseAPI.path) == 1, "Only one update request in flight")
            }),
            ("Automatic checks are opt-in, daily, quiet and can be disabled", {
                let rig = makeUpdateRig()
                defer { rig.cleanup() }
                var manualResults = 0
                rig.checker.onManualResult = { _ in manualResults += 1 }
                rig.checker.checkAutomaticallyIfNeeded()
                try expect(rig.checker.task == nil && !rig.checker.automaticChecksEnabled, "No GitHub contact by default")
                let now = Date()
                rig.checker.setAutomaticChecksEnabled(true)
                await rig.checker.task?.value
                rig.checker.checkAutomaticallyIfNeeded(now: now.addingTimeInterval(86399))
                try expect(rig.checker.task == nil, "No check before 24 hours")
                rig.checker.checkAutomaticallyIfNeeded(now: now.addingTimeInterval(86401))
                await rig.checker.task?.value
                try expect(rig.http.count(AppInfo.latestReleaseAPI.path) == 2 && manualResults == 0, "Daily checks never open manual alerts")
                rig.checker.setAutomaticChecksEnabled(false)
                rig.checker.checkAutomaticallyIfNeeded(now: now.addingTimeInterval(3 * 86400))
                try expect(rig.checker.task == nil, "Disabling stops future automatic requests")
            }),
            ("Restart preserves daily schedule while manual check bypasses it", {
                let rig = makeUpdateRig()
                defer { rig.cleanup() }
                rig.checker.setAutomaticChecksEnabled(true)
                await rig.checker.task?.value
                let restarted = UpdateChecker(client: rig.client, defaults: rig.defaults)
                defer { restarted.stop() }
                restarted.checkAutomaticallyIfNeeded()
                try expect(restarted.task == nil && restarted.lastChecked != nil, "Restart cannot reset the daily schedule")
                restarted.check()
                await restarted.task?.value
                try expect(rig.http.count(AppInfo.latestReleaseAPI.path) == 2, "Manual check remains available during daily interval")
            }),
            ("GitHub rate-limit cooldown survives restarts and blocks repeated requests", {
                let rig = makeUpdateRig { _, count in
                    count == 1 ? Reply(status: 429, headers: ["Retry-After": "120"]) : Reply(data: Fixtures.release())
                }
                defer { rig.cleanup() }
                rig.checker.check()
                await rig.checker.task?.value
                guard case .failed(.rateLimited(let retry)) = rig.checker.state else { throw TestFailure(description: "Expected rate limit") }
                try expect(retry.timeIntervalSinceNow > 100, "Honor Retry-After")
                rig.checker.check()
                let restarted = UpdateChecker(client: rig.client, defaults: rig.defaults)
                defer { restarted.stop() }
                restarted.check()
                try expect(rig.http.count(AppInfo.latestReleaseAPI.path) == 1, "Respect cooldown across clicks and restarts")
                restarted.check(now: retry.addingTimeInterval(1))
                await restarted.task?.value
                try expect(rig.http.count(AppInfo.latestReleaseAPI.path) == 2, "Allow retry after cooldown expires")
            }),
            ("GitHub primary rate limit honors reset timestamp", {
                let reset = Date().addingTimeInterval(600).timeIntervalSince1970
                let rig = makeUpdateRig { _, _ in
                    Reply(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset))])
                }
                defer { rig.cleanup() }
                rig.checker.check()
                await rig.checker.task?.value
                guard case .failed(.rateLimited(let retry)) = rig.checker.state else { throw TestFailure(description: "Expected primary rate limit") }
                try expect(abs(retry.timeIntervalSince1970 - floor(reset)) < 1, "Use GitHub rate-limit reset time")
            }),
            ("Failed automatic rechecks retain known updates without opening alerts", {
                let rig = makeUpdateRig()
                defer { rig.cleanup() }
                var manualResults = 0
                rig.checker.onManualResult = { _ in manualResults += 1 }
                rig.checker.check(manually: false)
                await rig.checker.task?.value
                let checked = rig.checker.lastChecked
                rig.http.change { _, _ in Reply(error: URLError(.notConnectedToInternet)) }
                rig.checker.check(manually: false)
                await rig.checker.task?.value
                try expect(rig.checker.availableRelease?.tag_name == "v0.3.0", "Keep known release after network failure")
                try expect(rig.checker.lastChecked == checked && manualResults == 0, "Failure cannot advance success time or open alerts")
            }),
            ("Stopping update checks discards late responses", {
                let rig = makeUpdateRig { _, _ in Reply(data: Fixtures.release(), delay: 0.2) }
                defer { rig.cleanup() }
                var manualResults = 0
                rig.checker.onManualResult = { _ in manualResults += 1 }
                rig.checker.check()
                let pending = rig.checker.task
                try await waitUntil { rig.http.count(AppInfo.latestReleaseAPI.path) == 1 }
                rig.checker.stop()
                await pending?.value
                try expect(!rig.checker.isChecking && rig.checker.availableRelease == nil && manualResults == 0, "Canceled checks cannot restore state or show alerts")
            }),
            ("Balance mode ignores expired subscription history", {
                var snapshot = AccountSnapshot()
                snapshot.apply(AccountResult(subscriptions: .success([try Fixtures.sub(Fixtures.rawSubscription(status: "expired", expires: -3600))]),
                                             profile: .success(Fixtures.profile())))
                try expect(QuotaPolicy.evaluate(snapshot).mode == .balance, "Expired history must not override spendable balance")
            }),
            ("Zero and missing balances remain distinct", {
                var snapshot = AccountSnapshot()
                snapshot.subscriptions = []
                snapshot.profile = Fixtures.profile(0)
                try expect(QuotaPolicy.evaluate(snapshot).mode == .unavailable, "Zero is insufficient")
                snapshot.profile = Fixtures.profile(nil)
                try expect(QuotaPolicy.evaluate(snapshot).mode == .unknown, "Missing is unknown, not zero")
                snapshot.subscriptions = nil
                snapshot.profile = Fixtures.profile()
                try expect(QuotaPolicy.evaluate(snapshot).mode == .unknown, "Missing subscriptions cannot establish balance mode")
            }),
            ("Most constrained quota window wins", {
                let sub = try Fixtures.sub(Fixtures.rawSubscription(daily: 2.4, weekly: 75.6))
                var snapshot = AccountSnapshot()
                snapshot.subscriptions = [sub]
                let state = QuotaPolicy.evaluate(snapshot)
                try expect(state.primary?.label == "每周", "Weekly 10% must outrank daily 80%")
                try expect(state.metrics.count == 2, "Keep all known periods")
            }),
            ("Missing usage is neither zero nor unlimited", {
                var snapshot = AccountSnapshot()
                snapshot.subscriptions = [try Fixtures.sub(Fixtures.rawSubscription(daily: nil))]
                let status = QuotaPolicy.evaluate(snapshot)
                try expect(status.hasUnknownUsage, "Known limit without usage is incomplete")
                try expect(status.metrics.allSatisfy { $0.label != "每日" }, "No invented zero usage")
            }),
            ("Usage without a valid limit stays explicitly unknown", {
                for limit in [nil, 0.0] as [Double?] {
                    var snapshot = AccountSnapshot()
                    snapshot.subscriptions = [try Fixtures.sub(Fixtures.rawSubscription(dailyLimit: limit))]
                    try expect(QuotaPolicy.evaluate(snapshot).hasUnknownUsage, "A used period with no limit must not silently disappear")
                }
            }),
            ("Default selection does not prefer a missing subscription ID", {
                var missing = Fixtures.rawSubscription()
                missing.removeValue(forKey: "id")
                var snapshot = AccountSnapshot()
                snapshot.subscriptions = [try Fixtures.sub(missing), try Fixtures.sub(Fixtures.rawSubscription())]
                try expect(QuotaPolicy.evaluate(snapshot).subscription?.id == 1, "Default selection must remain stable")
            }),
            ("Exhausted subscriptions do not silently switch billing", {
                var snapshot = AccountSnapshot()
                snapshot.subscriptions = [try Fixtures.sub(Fixtures.rawSubscription(daily: 14))]
                snapshot.profile = Fixtures.profile()
                let status = QuotaPolicy.evaluate(snapshot)
                try expect(status.mode == .subscription && status.primary?.remaining == 0, "Keep subscription exhaustion explicit")
                try expect(status.primary?.used == 14, "Preserve over-limit amounts")
                try expect(Format.percent(0.005) == "<1%", "Non-zero quota must not be rounded to zero")
            }),
            ("Short subscriptions never reset beyond expiry", {
                let sub = try Fixtures.sub(Fixtures.rawSubscription(expires: 1800))
                let reset = QuotaPolicy.resetDate(for: QuotaPolicy.metrics(for: sub)[0], subscription: sub)
                try expect(reset == Format.date(sub.expires_at), "Cap reset at subscription end")
            }),
            ("Partial failures preserve independent successful snapshots", {
                var snapshot = AccountSnapshot()
                let old = Date(timeIntervalSince1970: 100)
                snapshot.apply(AccountResult(subscriptions: .success([], at: old), profile: .success(Fixtures.profile(), at: old)))
                snapshot.apply(AccountResult(subscriptions: .success([], at: old.addingTimeInterval(300)), profile: .failure(.server(503))))
                try expect(snapshot.profile?.balance == 49.99, "Keep last successful balance")
                try expect(snapshot.profileFetchedAt == old, "Failure cannot advance success timestamp")
            }),
            ("Service errors do not trigger login", {
                let rig = try await makeRig { request, count in
                    request.url!.path.hasSuffix("subscriptions") ? Reply(status: 503) : Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let result = try await rig.client.fetchAccountStatus()
                try expect(result.subscriptions.error == .server(503), "Keep classified failure")
                try expect(result.profile.value?.balance == 49.99, "Balance should succeed independently")
                try expect(rig.http.count("auth/login") == 0 && rig.http.count("auth/refresh") == 0, "No reauthentication on 503")
            }),
            ("Offline requests do not trigger login", {
                let rig = try await makeRig { _, _ in Reply(error: URLError(.notConnectedToInternet)) }
                defer { rig.cleanup() }
                let result = try await rig.client.fetchAccountStatus()
                try expect(result.subscriptions.error?.isNetwork == true, "Keep offline cause")
                try expect(rig.http.count("auth/login") == 0, "Offline is not bad credentials")
            }),
            ("Authentication recovery only replays rejected resource", {
                let rig = try await makeRig { request, count in
                    if request.url!.path.hasSuffix("subscriptions"), count == 1 { return Reply(status: 401) }
                    return Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let result = try await rig.client.fetchAccountStatus()
                try expect(result.subscriptions.value?.count == 1, "Recovered request succeeds")
                try expect(rig.http.count("auth/refresh") == 1 && rig.http.count("auth/login") == 0, "Refresh token exactly once")
                try expect(rig.http.count("user/profile") == 1 && rig.http.count("subscriptions") == 2, "Do not replay successful resource")
            }),
            ("Concurrent refreshes share token renewal", {
                let rig = try await makeRig(expiredToken: true) { request, count in
                    var reply = Fixtures.normal(request, count)
                    if request.url!.path.hasSuffix("auth/refresh") { reply.delay = 0.08 }
                    return reply
                }
                defer { rig.cleanup() }
                async let first = rig.client.fetchAccountStatus()
                async let second = rig.client.fetchAccountStatus()
                _ = try await (first, second)
                try expect(rig.http.count("auth/refresh") == 1, "Single token refresh in flight")
            }),
            ("Authentication recovery failures preserve the successful resource", {
                let rig = try await makeRig { request, count in
                    if request.url!.path.hasSuffix("subscriptions") { return Reply(status: 401) }
                    if request.url!.path.hasSuffix("auth/refresh") { return Reply(status: 503) }
                    return Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let result = try await rig.client.fetchAccountStatus()
                try expect(result.profile.value?.balance == 49.99, "Keep fresh profile when token recovery fails")
                try expect(result.subscriptions.error == .server(503), "Only replace the rejected resource")
            }),
            ("Refresh endpoint failures do not fall back to password login", {
                let rig = try await makeRig(expiredToken: true) { _, _ in Reply(status: 503) }
                defer { rig.cleanup() }
                do { _ = try await rig.client.fetchAccountStatus(); throw TestFailure(description: "Expected service error") }
                catch let error as ClientError { try expect(error == .server(503), "Keep service error") }
                try expect(rig.http.count("auth/login") == 0, "No unnecessary password login")
            }),
            ("Missing envelope data is not an empty subscription list", {
                let rig = try await makeRig { request, count in
                    request.url!.path.hasSuffix("subscriptions") ? Reply(data: ["code": 0]) : Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let result = try await rig.client.fetchAccountStatus()
                try expect(result.subscriptions.error == .invalidResponse, "Missing payload must stay unknown")
            }),
            ("Rate limits preserve retry delay", {
                let rig = try await makeRig { _, _ in Reply(status: 429, headers: ["Retry-After": "120"]) }
                defer { rig.cleanup() }
                let result = try await rig.client.fetchAccountStatus()
                try expect(result.subscriptions.error?.retryAfter == 120, "Honor server retry delay")
                try expect(rig.http.count("auth/login") == 0, "Rate limits do not trigger login")
            }),
            ("Manual and connection refreshes respect rate-limit cooldown", {
                let rig = try await makeRig { _, _ in Reply(status: 429, headers: ["Retry-After": "120"]) }
                defer { rig.cleanup() }
                let store = QuotaStore(client: rig.client, defaults: rig.defaults)
                await store.start()
                await store.refreshTask?.value
                try expect(!store.canRefresh, "Refresh action must reflect cooldown")
                store.refresh()
                store.recoverConnection()
                await store.refreshTask?.value
                try expect(rig.http.count("subscriptions") == 1, "No retry before Retry-After")
                store.suspend()
            }),
            ("Logout prevents late token persistence", {
                let rig = try await makeRig(expiredToken: true) { request, count in
                    var reply = Fixtures.normal(request, count)
                    if request.url!.path.hasSuffix("auth/refresh") { reply.delay = 0.2 }
                    return reply
                }
                defer { rig.cleanup() }
                let task = Task { try await rig.client.fetchAccountStatus() }
                try await waitUntil { rig.http.count("auth/refresh") == 1 }
                try await rig.client.logout()
                _ = await task.result
                try expect(!FileManager.default.fileExists(atPath: rig.storage.tokenURL.path), "Old session must not restore tokens")
                try expect(!rig.credentials.contains(account: Fixtures.email), "Logout removes saved credentials")
            }),
            ("UI retains known balance and marks offline data", {
                let rig = try await makeRig { request, count in
                    request.url!.path.hasSuffix("subscriptions") ? Reply(data: ["code": 0, "data": []]) : Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let store = QuotaStore(client: rig.client, defaults: rig.defaults)
                await store.start()
                await store.refreshTask?.value
                rig.http.change { _, _ in Reply(error: URLError(.notConnectedToInternet)) }
                store.refresh()
                await store.refreshTask?.value
                let content = SummaryContent.make(store: store)
                try expect(content.amount == "$49.99" && content.barText == "~$49.99", "Retain and mark last successful amount")
                try expect(content.caption.contains("最近已知"), "Make staleness explicit")
                store.suspend()
            }),
            ("Profile failure does not suppress fresh subscription reminders", {
                let rig = try await makeRig { request, count in
                    request.url!.path.hasSuffix("subscriptions")
                        ? Reply(data: ["code": 0, "data": [Fixtures.rawSubscription(expires: 4 * 86400)]]) : Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let store = QuotaStore(client: rig.client, defaults: rig.defaults)
                let manager = ReminderManager(defaults: rig.defaults)
                await store.start()
                await store.refreshTask?.value
                manager.evaluate(store: store)
                rig.http.change { request, _ in
                    request.url!.path.hasSuffix("subscriptions")
                        ? Reply(data: ["code": 0, "data": [Fixtures.rawSubscription(expires: 2 * 86400)]]) : Reply(status: 503)
                }
                store.refresh()
                await store.refreshTask?.value
                manager.evaluate(store: store)
                let ledger = rig.defaults.dictionary(forKey: Preferences.notices) ?? [:]
                try expect(ledger.keys.contains { $0.contains(":expiry:") }, "Fresh expiry must be evaluated despite profile error")
                store.suspend()
            }),
            ("Store logout discards in-flight UI results", {
                let rig = try await makeRig { request, count in
                    var reply = Fixtures.normal(request, count)
                    reply.delay = 0.2
                    return reply
                }
                defer { rig.cleanup() }
                let store = QuotaStore(client: rig.client, defaults: rig.defaults)
                await store.start()
                let pending = store.refreshTask
                try await waitUntil { rig.http.count("subscriptions") == 1 }
                try await store.logout()
                await pending?.value
                try expect(!store.isConfigured && store.snapshot.profile == nil && store.snapshot.subscriptions == nil,
                           "Old request must not restore signed-out UI")
                try expect(rig.defaults.bool(forKey: Preferences.signedOut), "Restart must respect explicit logout")
            }),
            ("Rejected login does not overwrite saved identity or credentials", {
                let rig = try await makeRig { request, count in
                    request.url!.path.hasSuffix("auth/login") ? Reply(status: 401) : Fixtures.normal(request, count)
                }
                defer { rig.cleanup() }
                let previous = try rig.credentials.get(account: Fixtures.email)
                do {
                    _ = try await rig.client.signIn(email: "other@example.invalid", password: UUID().uuidString)
                    throw TestFailure(description: "Expected login rejection")
                } catch let error as ClientError { try expect(error == .authentication, "Keep rejected authentication explicit") }
                let config = try rig.storage.loadConfig()
                let after = try rig.credentials.get(account: Fixtures.email)
                try expect(config.email == Fixtures.email && previous == after, "Only persist a verified sign-in")
                try expect(!rig.credentials.contains(account: "other@example.invalid"), "No unverified saved account")
            }),
            ("Warning foreground is readable in both native appearances", {
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    let appearance = NSAppearance(named: name)!
                    var ratio = 0.0
                    appearance.performAsCurrentDrawingAppearance {
                        let foreground = AppearanceStyle.warningText.usingColorSpace(.sRGB)!
                        let background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                        func luminance(_ color: NSColor) -> Double {
                            func linear(_ value: CGFloat) -> Double {
                                let value = Double(value)
                                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                            }
                            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                        }
                        let first = luminance(foreground), second = luminance(background)
                        ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
                    }
                    try expect(ratio >= 4.5, "Warning text must reach the accepted contrast target")
                }
            }),
            ("Configuration reads do not rewrite modern files", {
                let rig = try await makeRig()
                defer { rig.cleanup() }
                let before = try Data(contentsOf: rig.storage.configURL)
                let attributes = try FileManager.default.attributesOfItem(atPath: rig.storage.configURL.path)
                _ = try rig.storage.loadConfig()
                _ = try rig.storage.loadConfig()
                let after = try FileManager.default.attributesOfItem(atPath: rig.storage.configURL.path)
                let currentData = try Data(contentsOf: rig.storage.configURL)
                try expect(before == currentData, "Modern config remains identical")
                try expect(attributes[.modificationDate] as? Date == after[.modificationDate] as? Date, "No render-time rewrites")
                let permissions = try FileManager.default.attributesOfItem(atPath: rig.storage.tokenURL.path)[.posixPermissions] as? Int
                try expect(permissions == 0o600, "Restrict token file permissions")
            })
        ]
        var failed = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failed)/\(tests.count) tests passed")
        if failed > 0 { exit(1) }
    }

    @MainActor static func renderPreviews(to directory: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in ["subscription", "balance", "offline", "exhausted", "unknown", "signed-out"] {
            let rig = try await makeRig { request, count in
                if request.url!.path.hasSuffix("subscriptions") {
                    if mode == "unknown" { return Reply(status: 503) }
                    if mode == "balance" || mode == "offline" { return Reply(data: ["code": 0, "data": [Fixtures.rawSubscription(status: "expired", expires: -3600)]]) }
                    return Reply(data: ["code": 0, "data": [Fixtures.rawSubscription(daily: mode == "exhausted" ? 14 : 3.8)]])
                }
                return Fixtures.normal(request, count)
            }
            let store = QuotaStore(client: rig.client, defaults: rig.defaults)
            if mode == "signed-out" { rig.defaults.set(true, forKey: Preferences.signedOut) }
            await store.start()
            await store.refreshTask?.value
            if mode == "offline" {
                rig.http.change { _, _ in Reply(error: URLError(.notConnectedToInternet)) }
                store.refresh()
                await store.refreshTask?.value
            }
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                let header = SummaryView(content: SummaryContent.make(store: store))
                let container = NSView(frame: header.bounds)
                container.wantsLayer = true
                container.appearance = NSAppearance(named: theme)
                container.appearance?.performAsCurrentDrawingAppearance {
                    container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                container.addSubview(header)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(container.bounds.width * 2),
                                          pixelsHigh: Int(container.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = container.bounds.size
                container.cacheDisplay(in: container.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(mode)-\(theme == .aqua ? "light" : "dark").png"))
            }
            store.suspend()
            rig.cleanup()
        }
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 352, height: 64))
            container.wantsLayer = true
            container.appearance = NSAppearance(named: theme)
            container.appearance?.performAsCurrentDrawingAppearance {
                container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let symbols: [(StatusSymbol, String)] = [(.quota(0.68), "68%"), (.quota(0.08), "8%"),
                                                      (.balance, "余额"), (.warning, "不足"), (.unknown, "未知"), (.account, "登录")]
            for (index, pair) in symbols.enumerated() {
                let x = CGFloat(index) * 55 + 16
                let icon = NSImageView(frame: NSRect(x: x + 12, y: 30, width: 18, height: 18))
                icon.image = ProgressIcon.make(pair.0)
                icon.contentTintColor = .labelColor
                container.addSubview(icon)
                let label = NSTextField(labelWithString: pair.1)
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                label.alignment = .center
                label.frame = NSRect(x: x, y: 7, width: 42, height: 18)
                container.addSubview(label)
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 704, pixelsHigh: 128, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = container.bounds.size
            container.cacheDisplay(in: container.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icons-\(theme == .aqua ? "light" : "dark").png"))
        }
        print("Exported native SummaryView and icon states to \(directory.path)")
    }
}

import AppKit
import Foundation
import Security
import Network
import UserNotifications
import LocalAuthentication

// MARK: - Models and quota rules

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    static let intervals = [60, 300, 600, 1800]
    static let repositoryURL = URL(string: "https://github.com/qx0657/allinai-quota-menu")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/qx0657/allinai-quota-menu/releases/latest")!
}

struct Config: Codable, Sendable {
    var email: String
    var refreshIntervalSeconds: Int
}

struct LegacyConfig: Decodable {
    var email: String?
    var password: String?
    var refreshIntervalSeconds: Int?
}

struct TokenCache: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval
    var account: String?
}

struct APIEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
}

struct LoginData: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}

struct UserProfile: Decodable, Sendable {
    let username: String?
    let email: String?
    let balance: Double?

    var displayName: String? {
        [username, email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    var validBalance: Double? { balance.flatMap { $0.isFinite ? $0 : nil } }
}

struct Subscription: Decodable, Sendable {
    let id: Int?
    let starts_at: String?
    let expires_at: String?
    let status: String?
    let daily_window_start: String?
    let weekly_window_start: String?
    let monthly_window_start: String?
    let daily_usage_usd: Double?
    let weekly_usage_usd: Double?
    let monthly_usage_usd: Double?
    let group: Group?
}

struct Group: Decodable, Sendable {
    let name: String?
    let description: String?
    let platform: String?
    let daily_limit_usd: Double?
    let weekly_limit_usd: Double?
    let monthly_limit_usd: Double?
}

struct QuotaMetric: Sendable {
    let label: String
    let used: Double
    let limit: Double
    let windowStart: String?
    let hours: Int

    var ratio: Double { min(max(used / limit, 0), 1) }
    var remainingRatio: Double { 1 - ratio }
    var remaining: Double { max(limit - used, 0) }
}

enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case authentication
    case missingCredentials
    case network(String)
    case rateLimited(TimeInterval?)
    case server(Int)
    case rejected(String)
    case invalidResponse
    case storage(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authentication: return "登录已失效，请重新登录。"
        case .missingCredentials: return "请重新登录，或允许访问 macOS 钥匙串。"
        case .network(let message), .rejected(let message), .storage(let message): return message
        case .rateLimited: return "请求过于频繁，稍后会自动重试。"
        case .server(let code): return "服务暂不可用（\(code)），稍后会自动重试。"
        case .invalidResponse: return "服务返回的数据不完整，请稍后重试。"
        case .cancelled: return "操作已取消。"
        }
    }

    var requiresLogin: Bool { self == .authentication || self == .missingCredentials }
    var isNetwork: Bool { if case .network = self { return true }; return false }
    var retryAfter: TimeInterval? { if case .rateLimited(let delay) = self { return delay }; return nil }

    static func from(_ error: Error) -> ClientError {
        if let error = error as? ClientError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost: return .network("当前离线，请检查网络连接。")
            case .timedOut: return .network("请求超时，请稍后重试。")
            default: return .network("无法连接 AllinAI 服务，请检查网络后重试。")
            }
        }
        return .storage("本地数据操作失败，请检查文件或钥匙串权限。")
    }
}

struct ResourceResult<Value: Sendable>: Sendable {
    let value: Value?
    let error: ClientError?
    let fetchedAt: Date?

    static func success(_ value: Value, at date: Date = Date()) -> Self {
        Self(value: value, error: nil, fetchedAt: date)
    }
    static func failure(_ error: ClientError) -> Self { Self(value: nil, error: error, fetchedAt: nil) }
}

struct AccountResult: Sendable {
    let subscriptions: ResourceResult<[Subscription]>
    let profile: ResourceResult<UserProfile>
}

struct AccountSnapshot {
    var subscriptions: [Subscription]?
    var profile: UserProfile?
    var subscriptionsFetchedAt: Date?
    var profileFetchedAt: Date?
    var subscriptionError: ClientError?
    var profileError: ClientError?

    mutating func apply(_ result: AccountResult) {
        if let value = result.subscriptions.value {
            subscriptions = value
            subscriptionsFetchedAt = result.subscriptions.fetchedAt
        }
        if let value = result.profile.value {
            profile = value
            profileFetchedAt = result.profile.fetchedAt
        }
        subscriptionError = result.subscriptions.error
        profileError = result.profile.error
    }
}

enum ConsumptionMode { case subscription, balance, unavailable, unknown }

struct QuotaStatus {
    let mode: ConsumptionMode
    let subscription: Subscription?
    let metrics: [QuotaMetric]
    let primary: QuotaMetric?
    let balance: Double?
    let hasUnknownUsage: Bool
}

enum QuotaPolicy {
    static func metrics(for sub: Subscription) -> [QuotaMetric] {
        let candidates: [(String, Double?, Double?, String?, Int)] = [
            ("每日", sub.daily_usage_usd, sub.group?.daily_limit_usd, sub.daily_window_start, 24),
            ("每周", sub.weekly_usage_usd, sub.group?.weekly_limit_usd, sub.weekly_window_start, 168),
            ("每月", sub.monthly_usage_usd, sub.group?.monthly_limit_usd, sub.monthly_window_start, 720)
        ]
        return candidates.compactMap { label, used, limit, start, hours in
            guard let used, let limit, used.isFinite, limit.isFinite, used >= 0, limit > 0 else { return nil }
            return QuotaMetric(label: label, used: used, limit: limit, windowStart: start, hours: hours)
        }
    }

    static func isActive(_ sub: Subscription, now: Date) -> Bool {
        guard sub.status == "active" else { return false }
        if let expires = Format.date(sub.expires_at), expires <= now { return false }
        if let starts = Format.date(sub.starts_at), starts > now { return false }
        return true
    }

    static func evaluate(_ snapshot: AccountSnapshot, now: Date = Date(), selectedID: Int? = nil) -> QuotaStatus {
        let subscriptions = snapshot.subscriptions ?? []
        let active = subscriptions.filter { isActive($0, now: now) }.sorted { ($0.id ?? Int.max) < ($1.id ?? Int.max) }
        let selected = selectedID.flatMap { id in active.first { $0.id == id } } ?? active.first
        let balance = snapshot.profile?.validBalance
        if let sub = selected {
            let values = metrics(for: sub)
            let primary = values.max { $0.used / $0.limit < $1.used / $1.limit }
            let limits = [sub.group?.daily_limit_usd, sub.group?.weekly_limit_usd, sub.group?.monthly_limit_usd]
            let expected = limits.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.count
            let usages = [sub.daily_usage_usd, sub.weekly_usage_usd, sub.monthly_usage_usd]
            let unboundedUsage = zip(usages, limits).contains { used, limit in
                guard let used, used.isFinite, used > 0 else { return false }
                return limit == nil || !limit!.isFinite || limit! <= 0
            }
            return QuotaStatus(mode: .subscription, subscription: sub, metrics: values, primary: primary,
                               balance: balance, hasUnknownUsage: values.isEmpty || values.count < expected || unboundedUsage)
        }
        // A failed/missing subscription result is not evidence that the account has no subscription.
        let uncertain = snapshot.subscriptions == nil || subscriptions.contains {
            $0.status != "expired" && !isActive($0, now: now)
        }
        let mode: ConsumptionMode
        if uncertain { mode = .unknown }
        else if let balance { mode = balance > 0 ? .balance : .unavailable }
        else { mode = .unknown }
        return QuotaStatus(mode: mode, subscription: nil, metrics: [], primary: nil, balance: balance, hasUnknownUsage: false)
    }

    static func resetDate(for metric: QuotaMetric, subscription: Subscription) -> Date? {
        guard let start = Format.date(metric.windowStart) else { return nil }
        let reset = start.addingTimeInterval(Double(metric.hours) * 3600)
        if let expires = Format.date(subscription.expires_at) { return min(reset, expires) }
        return reset
    }
}

enum Format {
    static func money(_ value: Double) -> String { String(format: "%.2f", value) }
    static func percent(_ ratio: Double) -> String {
        if ratio > 0 && ratio < 0.01 { return "<1%" }
        if ratio < 1 && ratio > 0.99 { return ">99%" }
        return "\(Int((max(0, min(1, ratio)) * 100).rounded()))%"
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func timestamp(_ date: Date, full: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = full ? "yyyy/MM/dd HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds == 0 { return "已到期" }
        let minutes = max(1, seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
    static func updated(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "尚未成功更新" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        return "上次更新 \(timestamp(date, full: true))"
    }
    static func status(_ value: String?) -> String {
        switch value { case "active": return "有效"; case "expired": return "已过期"; default: return "状态待确认" }
    }
}

// MARK: - GitHub release updates (independent of the AllinAI account)

struct ReleaseVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
    var description: String { components.map(String.init).joined(separator: ".") }
}

struct GitHubRelease: Decodable, Sendable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool

    // Construct links on the known repository instead of trusting a URL from the response.
    var pageURL: URL { AppInfo.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag_name) }
    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
}

enum UpdateError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse
    case invalidVersion
    case network
    case timedOut
    case server(Int)
    case rateLimited(Date)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 返回的数据无法识别，请稍后重试，或打开更新记录查看。"
        case .invalidVersion: return "最新 Release 的版本号无法识别，请打开更新记录查看。正式版标签应为 v主版本.次版本.修订号。"
        case .network: return "无法连接 GitHub，请检查网络后重试，也可直接打开更新记录。"
        case .timedOut: return "连接 GitHub 超时，请稍后重试，也可直接打开更新记录。"
        case .server(let code): return "GitHub 暂时无法访问（\(code)），请稍后重试，或打开更新记录查看。"
        case .rateLimited(let until): return "GitHub 请求次数已达上限，请在 \(Format.timestamp(until, full: true)) 后重试，或直接打开更新记录。"
        }
    }

    static func from(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if let error = error as? URLError { return error.code == .timedOut ? .timedOut : .network }
        return .invalidResponse
    }
}

struct ReleaseClient: Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
    }

    func latestRelease() async throws -> GitHubRelease? {
        var request = URLRequest(url: AppInfo.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AllinAI-Quota/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        if response.statusCode == 404 { return nil }
        if response.statusCode == 429 || (response.statusCode == 403 &&
            (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || response.value(forHTTPHeaderField: "Retry-After") != nil)) {
            let now = Date()
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            let seconds = delay ?? reset.map { $0 - now.timeIntervalSince1970 } ?? 3600
            throw UpdateError.rateLimited(now.addingTimeInterval(seconds.isFinite ? max(60, min(seconds, 86400)) : 3600))
        }
        guard response.statusCode == 200 else { throw UpdateError.server(response.statusCode) }
        let release: GitHubRelease
        do { release = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateError.invalidResponse }
        guard !release.draft && !release.prerelease else { return nil }
        guard release.version != nil else { throw UpdateError.invalidVersion }
        return release
    }
}

enum UpdateState: Sendable {
    case idle, checking, noRelease
    case available(GitHubRelease), current(GitHubRelease)
    case failed(UpdateError)
}

@MainActor
final class UpdateChecker {
    private let client: ReleaseClient
    private let defaults: UserDefaults
    private let currentVersion: String
    private var timer: Timer?
    private(set) var task: Task<Void, Never>?
    private(set) var state: UpdateState = .idle
    private(set) var availableRelease: GitHubRelease?
    var onChange: (() -> Void)?
    var onManualResult: ((UpdateState) -> Void)?

    init(client: ReleaseClient = ReleaseClient(), defaults: UserDefaults = .standard, currentVersion: String = AppInfo.version) {
        self.client = client
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    var automaticChecksEnabled: Bool { defaults.bool(forKey: Preferences.automaticUpdates) }
    var lastChecked: Date? { defaults.object(forKey: Preferences.lastUpdateCheck) as? Date }
    var isChecking: Bool { if case .checking = state { return true }; return false }

    func start() {
        checkAutomaticallyIfNeeded()
        timer?.invalidate()
        // The hourly timer only tests whether a daily check is due; it does not poll GitHub hourly.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomaticallyIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        if isChecking { state = .idle }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Preferences.automaticUpdates)
        onChange?()
        if enabled { checkAutomaticallyIfNeeded() }
    }

    func checkAutomaticallyIfNeeded(now: Date = Date()) {
        guard automaticChecksEnabled else { return }
        let lastAttempt = defaults.object(forKey: Preferences.lastUpdateAttempt) as? Date ?? .distantPast
        guard now.timeIntervalSince(lastAttempt) >= 86400 else { return }
        check(manually: false, now: now)
    }

    func check(manually: Bool = true, now: Date = Date()) {
        guard !isChecking else { return }
        if let retry = defaults.object(forKey: Preferences.updateRetryAfter) as? Date, retry > now {
            state = .failed(.rateLimited(retry))
            onChange?()
            if manually { onManualResult?(state) }
            return
        }
        defaults.set(now, forKey: Preferences.lastUpdateAttempt)
        state = .checking
        onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            let result: UpdateState
            do {
                let release = try await client.latestRelease()
                guard !Task.isCancelled else { return }
                guard let current = ReleaseVersion(currentVersion) else { throw UpdateError.invalidVersion }
                if let release, let version = release.version {
                    availableRelease = version > current ? release : nil
                    result = version > current ? .available(release) : .current(release)
                } else {
                    availableRelease = nil
                    result = .noRelease
                }
                defaults.set(now, forKey: Preferences.lastUpdateCheck)
                defaults.removeObject(forKey: Preferences.updateRetryAfter)
            } catch {
                guard !Task.isCancelled else { return }
                let failure = UpdateError.from(error)
                if case .rateLimited(let retry) = failure { defaults.set(retry, forKey: Preferences.updateRetryAfter) }
                result = .failed(failure)
            }
            state = result
            task = nil
            onChange?()
            if manually { onManualResult?(result) }
        }
    }
}

// MARK: - Local storage and Keychain

protocol CredentialStore: Sendable {
    func get(account: String) throws -> String?
    func set(_ password: String, account: String) throws
    func delete(account: String) throws
    func contains(account: String) -> Bool
}

final class Keychain: CredentialStore {
    private let service: String
    init(service: String = "local.allinai.quota.menu") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func set(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
    }
    func get(account: String) throws -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return String(data: data, encoding: .utf8)
    }
    func contains(account: String) -> Bool {
        var lookup = query(account)
        lookup[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> ClientError {
        if status == errSecUserCanceled { return .storage("已取消钥匙串授权，可重新登录后再试。") }
        return .storage("无法访问 macOS 钥匙串（\(status)），请检查授权后重试。")
    }
}

// Owned by AllinClient; no file or Keychain access occurs during menu rendering.
final class LocalStorage {
    let directory: URL
    let credentials: any CredentialStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var prepared = false
    private var configCache: Config?
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var tokenURL: URL { directory.appendingPathComponent("tokens.json") }

    init(directory: URL, credentials: any CredentialStore = Keychain()) {
        self.directory = directory
        self.credentials = credentials
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    func loadConfig() throws -> Config {
        if let configCache { return configCache }
        try prepare()
        let config = try decoder.decode(Config.self, from: Data(contentsOf: configURL))
        configCache = config
        return config
    }
    private func prepare() throws {
        guard !prepared else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try write(Config(email: "", refreshIntervalSeconds: 300), to: configURL)
        } else {
            let data = try Data(contentsOf: configURL)
            let legacy = try decoder.decode(LegacyConfig.self, from: data)
            let interval = legacy.refreshIntervalSeconds ?? 300
            let config = Config(email: (legacy.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                refreshIntervalSeconds: AppInfo.intervals.contains(interval) ? interval : 300)
            let hasLegacyPassword = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["password"] != nil
            if let password = legacy.password, !password.isEmpty, !config.email.isEmpty {
                try credentials.set(password, account: config.email)
            }
            let modern = try? decoder.decode(Config.self, from: data)
            if hasLegacyPassword || modern == nil || modern?.email != config.email || interval != config.refreshIntervalSeconds {
                try write(config, to: configURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
        if FileManager.default.fileExists(atPath: tokenURL.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }
        prepared = true
    }
    func saveConfig(_ config: Config) throws {
        try prepare()
        try write(config, to: configURL)
        configCache = config
    }
    func loadTokens(account: String) -> TokenCache? {
        guard let data = try? Data(contentsOf: tokenURL),
              let tokens = try? decoder.decode(TokenCache.self, from: data),
              tokens.account == nil || tokens.account == account else { return nil }
        return tokens
    }
    func saveTokens(_ tokens: TokenCache) throws { try write(tokens, to: tokenURL) }
    func clearTokens() throws {
        if FileManager.default.fileExists(atPath: tokenURL.path) { try FileManager.default.removeItem(at: tokenURL) }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Account session and HTTP

actor AllinClient {
    private let baseURL = URL(string: "https://allincode.top/api/v1")!
    private let storage: LocalStorage
    private let session: URLSession
    private var epoch = 0
    private var tokenTask: Task<TokenCache, Error>?
    private var tokenTaskID: UUID?
    private var tokens: TokenCache?

    init(storage: LocalStorage, session: URLSession = .shared) {
        self.storage = storage
        self.session = session
    }
    func configuration() throws -> (Config, Bool) {
        let config = try storage.loadConfig()
        tokens = storage.loadTokens(account: config.email)
        return (config, !config.email.isEmpty && (tokens != nil || storage.credentials.contains(account: config.email)))
    }
    func setInterval(_ seconds: Int) throws -> Config {
        guard AppInfo.intervals.contains(seconds) else { throw ClientError.rejected("请选择有效的刷新间隔。") }
        var config = try storage.loadConfig()
        config.refreshIntervalSeconds = seconds
        try storage.saveConfig(config)
        return config
    }
    func signIn(email: String, password: String) async throws -> Config {
        epoch += 1
        let expected = epoch
        tokenTask?.cancel()
        tokenTask = nil
        tokenTaskID = nil
        let response: LoginData = try await request("auth/login", body: ["email": email, "password": password])
        try check(expected)
        let cache = try makeTokens(response, account: email)
        try storage.credentials.set(password, account: email)
        var config = try storage.loadConfig()
        config.email = email
        try storage.saveConfig(config)
        try storage.saveTokens(cache)
        tokens = cache
        return config
    }
    func logout() throws {
        epoch += 1
        tokenTask?.cancel()
        tokenTask = nil
        tokenTaskID = nil
        tokens = nil
        // Clear tokens even if the user cancels Keychain authorization.
        try storage.clearTokens()
        let config = try storage.loadConfig()
        if !config.email.isEmpty { try storage.credentials.delete(account: config.email) }
    }
    func fetchAccountStatus() async throws -> AccountResult {
        let expected = epoch
        let token = try await accessToken(expected: expected)
        async let subscriptions: ResourceResult<[Subscription]> = fetch("subscriptions", token: token)
        async let profile: ResourceResult<UserProfile> = fetch("user/profile", token: token)
        let first = await AccountResult(subscriptions: subscriptions, profile: profile)
        try check(expected)
        guard first.subscriptions.error == .authentication || first.profile.error == .authentication else { return first }
        let fresh: String
        do { fresh = try await accessToken(expected: expected, rejecting: token) }
        catch {
            try check(expected)
            let failure = ClientError.from(error)
            return AccountResult(subscriptions: first.subscriptions.error == .authentication ? .failure(failure) : first.subscriptions,
                                 profile: first.profile.error == .authentication ? .failure(failure) : first.profile)
        }
        // Only replay resources rejected for authentication, once per refresh.
        async let retriedSubscriptions: ResourceResult<[Subscription]> = first.subscriptions.error == .authentication
            ? fetch("subscriptions", token: fresh) : first.subscriptions
        async let retriedProfile: ResourceResult<UserProfile> = first.profile.error == .authentication
            ? fetch("user/profile", token: fresh) : first.profile
        let result = await AccountResult(subscriptions: retriedSubscriptions, profile: retriedProfile)
        try check(expected)
        return result
    }
    private func accessToken(expected: Int, rejecting rejected: String? = nil) async throws -> String {
        try check(expected)
        if let tokens, tokens.accessToken != rejected, tokens.expiresAt > Date().timeIntervalSince1970 + 60 {
            return tokens.accessToken
        }
        if let tokenTask {
            let cache = try await tokenTask.value
            try check(expected)
            return cache.accessToken
        }
        let id = UUID()
        let task = Task { try await self.obtainTokens(expected: expected) }
        tokenTaskID = id
        tokenTask = task
        defer { if tokenTaskID == id { tokenTask = nil; tokenTaskID = nil } }
        let cache = try await task.value
        try check(expected)
        return cache.accessToken
    }
    private func obtainTokens(expected: Int) async throws -> TokenCache {
        let config = try storage.loadConfig()
        guard !config.email.isEmpty else { throw ClientError.missingCredentials }
        let previous = tokens ?? storage.loadTokens(account: config.email)
        let response: LoginData
        if let previous, !previous.refreshToken.isEmpty {
            do {
                response = try await request("auth/refresh", body: ["refresh_token": previous.refreshToken])
            } catch {
                try check(expected)
                guard ClientError.from(error) == .authentication else { throw error }
                response = try await login(config)
            }
        } else { response = try await login(config) }
        try check(expected)
        var cache = try makeTokens(response, account: config.email)
        if response.refresh_token == nil { cache.refreshToken = previous?.refreshToken ?? "" }
        try storage.saveTokens(cache)
        tokens = cache
        return cache
    }
    private func login(_ config: Config) async throws -> LoginData {
        guard let password = try storage.credentials.get(account: config.email), !password.isEmpty else {
            throw ClientError.missingCredentials
        }
        return try await request("auth/login", body: ["email": config.email, "password": password])
    }
    private func makeTokens(_ data: LoginData, account: String) throws -> TokenCache {
        guard !data.access_token.isEmpty, (data.expires_in ?? 3600) > 0 else { throw ClientError.invalidResponse }
        return TokenCache(accessToken: data.access_token, refreshToken: data.refresh_token ?? "",
                          expiresAt: Date().timeIntervalSince1970 + Double(data.expires_in ?? 3600), account: account)
    }
    private func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == epoch else { throw CancellationError() }
    }
    private func fetch<T: Decodable & Sendable>(_ path: String, token: String) async -> ResourceResult<T> {
        do { return .success(try await request(path, token: token)) }
        catch { return .failure(ClientError.from(error)) }
    }
    private func request<T: Decodable>(_ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if path == "subscriptions" { components.queryItems = [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch http.statusCode {
        case 401: throw ClientError.authentication
        case 429:
            let header = http.value(forHTTPHeaderField: "Retry-After")
            let delay = header.flatMap(Double.init) ?? header.flatMap { value -> TimeInterval? in
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.timeZone = TimeZone(secondsFromGMT: 0)
                parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                return parser.date(from: value)?.timeIntervalSinceNow
            }
            throw ClientError.rateLimited(delay.map { max(0, $0) })
        case 500...599: throw ClientError.server(http.statusCode)
        case 200...299: break
        case 403: throw ClientError.rejected("当前账号无权访问此功能。")
        default: throw ClientError.rejected("请求失败（\(http.statusCode)），请稍后重试。")
        }
        guard let envelope = try? JSONDecoder().decode(APIEnvelope<T>.self, from: data), let code = envelope.code else {
            throw ClientError.invalidResponse
        }
        if code == 401 { throw ClientError.authentication }
        guard code == 0 else { throw ClientError.rejected(String((envelope.message ?? "服务拒绝了此次请求。").prefix(180))) }
        guard let value = envelope.data else { throw ClientError.invalidResponse }
        return value
    }
}

// MARK: - Refresh state and reminders

enum Preferences {
    static let numbers = "showMenuBarNumbers"
    static let reminders = "quotaRemindersEnabled"
    static let lowBalance = "lowBalanceReminderUSD"
    static let signedOut = "explicitlySignedOut"
    static let notices = "deliveredQuotaNotices"
    static let automaticUpdates = "automaticUpdateChecksEnabled"
    static let lastUpdateAttempt = "lastUpdateCheckAttempt"
    static let lastUpdateCheck = "lastSuccessfulUpdateCheck"
    static let updateRetryAfter = "updateCheckRetryAfter"
}

@MainActor
final class QuotaStore {
    let client: AllinClient
    private let defaults: UserDefaults
    private(set) var config = Config(email: "", refreshIntervalSeconds: 300)
    private(set) var snapshot = AccountSnapshot()
    private(set) var isStarting = true
    private(set) var isConfigured = false
    private(set) var isRefreshing = false
    private(set) var error: ClientError?
    private(set) var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var timer: Timer?
    private var failureCount = 0
    private var lastAttempt: Date?
    private var retryNotBefore: Date?
    private var sleeping = false
    var selectedSubscriptionID: Int?
    var onChange: (() -> Void)?

    init(client: AllinClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }
    var status: QuotaStatus { QuotaPolicy.evaluate(snapshot, selectedID: selectedSubscriptionID) }
    var needsLogin: Bool {
        error?.requiresLogin == true || snapshot.subscriptionError?.requiresLogin == true || snapshot.profileError?.requiresLogin == true
    }
    var canRefresh: Bool {
        isConfigured && !isRefreshing && !sleeping && !needsLogin && (retryNotBefore ?? .distantPast) <= Date()
    }
    var displayName: String { snapshot.profile?.displayName ?? config.email }

    func start() async {
        do {
            let (config, configured) = try await client.configuration()
            self.config = config
            isConfigured = configured && !defaults.bool(forKey: Preferences.signedOut)
        } catch { self.error = ClientError.from(error) }
        isStarting = false
        onChange?()
        if isConfigured { refresh() }
    }
    func refresh() {
        guard isConfigured, !isRefreshing, !sleeping, !needsLogin else { return }
        if let retryNotBefore, retryNotBefore > Date() {
            schedule(after: retryNotBefore.timeIntervalSinceNow)
            return
        }
        timer?.invalidate()
        isRefreshing = true
        lastAttempt = Date()
        let expected = generation
        onChange?()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.fetchAccountStatus()
                guard generation == expected, !Task.isCancelled else { return }
                snapshot.apply(result)
                error = nil
                let delay = [result.subscriptions.error, result.profile.error].compactMap { $0?.retryAfter }.max()
                retryNotBefore = delay.map { Date().addingTimeInterval($0) }
                failureCount = result.subscriptions.value == nil && result.profile.value == nil ? failureCount + 1 : 0
            } catch {
                guard generation == expected, !Task.isCancelled else { return }
                let failure = ClientError.from(error)
                if failure != .cancelled {
                    self.error = failure
                    retryNotBefore = failure.retryAfter.map { Date().addingTimeInterval($0) }
                    snapshot.subscriptionError = failure
                    snapshot.profileError = failure
                    failureCount += 1
                }
            }
            guard generation == expected else { return }
            isRefreshing = false
            refreshTask = nil
            schedule()
            onChange?()
        }
    }
    func refreshIfNeeded() {
        let interval = TimeInterval(config.refreshIntervalSeconds)
        if Date().timeIntervalSince(lastAttempt ?? .distantPast) >= interval { refresh() }
    }
    func signIn(email: String, password: String) async throws {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        isRefreshing = false
        defer {
            if isConfigured && !isRefreshing { schedule() }
            onChange?()
        }
        let expected = generation
        let config = try await client.signIn(email: email, password: password)
        guard generation == expected else { throw CancellationError() }
        self.config = config
        snapshot = AccountSnapshot()
        error = nil
        failureCount = 0
        retryNotBefore = nil
        isConfigured = true
        defaults.set(false, forKey: Preferences.signedOut)
        onChange?()
        refresh()
    }
    func logout() async throws {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        isConfigured = false
        isRefreshing = false
        snapshot = AccountSnapshot()
        error = nil
        selectedSubscriptionID = nil
        retryNotBefore = nil
        defaults.set(true, forKey: Preferences.signedOut)
        onChange?()
        try await client.logout()
    }
    func setInterval(_ seconds: Int) async throws {
        config = try await client.setInterval(seconds)
        schedule()
        onChange?()
    }
    func suspend() {
        sleeping = true
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        isRefreshing = false
        onChange?()
    }
    func resume() {
        sleeping = false
        recoverConnection()
    }
    func recoverConnection() {
        guard isConfigured, !isRefreshing, !sleeping, !needsLogin else { return }
        let sinceAttempt = Date().timeIntervalSince(lastAttempt ?? .distantPast)
        if sinceAttempt >= 60 { refresh() }
        else { schedule(after: 60 - sinceAttempt) }
    }
    private func schedule(after delay: TimeInterval? = nil) {
        timer?.invalidate()
        guard isConfigured, !sleeping, !needsLogin else { return }
        let backoff = min(Double(config.refreshIntervalSeconds) * pow(2, Double(min(failureCount, 5))), 1800)
        let retryAfter = max(0, retryNotBefore?.timeIntervalSinceNow ?? 0)
        let wait = max(delay ?? backoff, retryAfter)
        let timer = Timer(timeInterval: max(1, wait), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(wait * 0.1, 30)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

@MainActor
final class ReminderManager {
    private let defaults: UserDefaults
    private var lastSubscriptionChecked: Date?
    private var lastProfileChecked: Date?
    private var observedSubscriptions = false
    private var observedProfile = false
    private var lastAccount: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func evaluate(store: QuotaStore) {
        guard !store.isRefreshing, store.isConfigured, !store.needsLogin else { return }
        let account = store.config.email
        if lastAccount != account {
            lastSubscriptionChecked = nil
            lastProfileChecked = nil
            observedSubscriptions = false
            observedProfile = false
            lastAccount = account
        }
        let freshSubscriptions = store.snapshot.subscriptionError == nil && store.snapshot.subscriptionsFetchedAt != nil &&
            store.snapshot.subscriptionsFetchedAt != lastSubscriptionChecked
        let freshProfile = store.snapshot.profileError == nil && store.snapshot.profileFetchedAt != nil &&
            store.snapshot.profileFetchedAt != lastProfileChecked
        guard freshSubscriptions || freshProfile else { return }
        let notifySubscriptions = observedSubscriptions
        let notifyProfile = observedProfile
        if freshSubscriptions { lastSubscriptionChecked = store.snapshot.subscriptionsFetchedAt; observedSubscriptions = true }
        if freshProfile { lastProfileChecked = store.snapshot.profileFetchedAt; observedProfile = true }
        let status = store.status
        var candidates: [(String, String, String, Bool)] = []
        if freshSubscriptions, let sub = status.subscription {
            let identity = "\(account):\(sub.id ?? -1)"
            if let expires = Format.date(sub.expires_at) {
                let seconds = expires.timeIntervalSinceNow
                if seconds > 0 && seconds <= 3 * 86400 {
                    let threshold = seconds <= 86400 ? 1 : 3
                    candidates.append(("\(identity):expiry:\(expires.timeIntervalSince1970):\(threshold)", "订阅即将到期",
                                       "\(sub.group?.name ?? "订阅")还有 \(Format.remaining(until: expires))到期。", notifySubscriptions))
                }
            }
            if !status.hasUnknownUsage, let metric = status.primary, let window = metric.windowStart,
               let reset = QuotaPolicy.resetDate(for: metric, subscription: sub), reset > Date(), metric.remainingRatio <= 0.1 {
                candidates.append(("\(identity):quota:\(metric.label):\(window):10", "订阅额度即将用尽",
                                   "\(metric.label)剩余 \(Format.percent(metric.remainingRatio))（$\(Format.money(metric.remaining))）。", notifySubscriptions))
            }
        } else if freshProfile, store.snapshot.subscriptionError == nil,
                  status.mode == .balance || status.mode == .unavailable, let balance = status.balance {
            let threshold = defaults.double(forKey: Preferences.lowBalance)
            let key = "\(account):balance:\(threshold)"
            if threshold > 0, balance <= threshold {
                candidates.append((key, "账户余额较低", "当前余额 $\(Format.money(balance))，请留意后续用量。", notifyProfile))
            } else if balance > threshold {
                var ledger = defaults.dictionary(forKey: Preferences.notices) ?? [:]
                ledger.removeValue(forKey: key)
                defaults.set(ledger, forKey: Preferences.notices)
            }
        }
        var ledger = defaults.dictionary(forKey: Preferences.notices) ?? [:]
        let enabled = defaults.bool(forKey: Preferences.reminders)
        for (key, title, body, shouldNotify) in candidates where ledger[key] == nil {
            // Seed current conditions quietly on launch, rather than replaying old warnings.
            ledger[key] = Date().timeIntervalSince1970
            if enabled && shouldNotify {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        var ledger = self.defaults.dictionary(forKey: Preferences.notices) ?? [:]
                        ledger.removeValue(forKey: key)
                        self.defaults.set(ledger, forKey: Preferences.notices)
                    }
                }
            }
        }
        // Keep deduplication bounded across long-running accounts and rotating quota windows.
        ledger = ledger.filter { (Date().timeIntervalSince1970 - ($0.value as? Double ?? 0)) < 100 * 86400 }
        defaults.set(ledger, forKey: Preferences.notices)
    }
}

// MARK: - Presentation (no disk or Keychain access)

enum StatusSymbol { case quota(Double), balance, warning, unknown, account }

struct SummaryContent {
    var account = ""
    var title = "AllinAI"
    var badge = ""
    var caption = ""
    var amount = ""
    var percentage: String?
    var progress: Double?
    var lines: [String] = []
    var banner: String?
    var isWarning = false
    var symbol: StatusSymbol = .unknown
    var barText = "--"
    var tooltip = "AllinAI"

    @MainActor
    static func make(store: QuotaStore, now: Date = Date()) -> Self {
        var content = Self()
        content.account = store.displayName
        if store.isStarting {
            content.caption = "正在加载"
            content.amount = "请稍候…"
            return content
        }
        if !store.isConfigured {
            content.title = "欢迎使用 AllinAI"
            content.caption = "请登录后查看额度与余额"
            content.amount = "尚未登录"
            content.lines = ["密码保存在 macOS 钥匙串。"]
            content.symbol = .account
            content.barText = "请登录"
            content.banner = store.error?.localizedDescription
            content.tooltip = "AllinAI · 请登录"
            return content
        }
        let snapshot = store.snapshot
        let status = store.status
        if store.needsLogin {
            content.caption = "需要重新登录"
            content.amount = "登录已失效"
            content.lines = ["重新登录后继续查看额度与余额。"]
            content.symbol = .account
            content.barText = "需登录"
            content.tooltip = "AllinAI · 登录已失效，请重新登录"
            return content
        }
        switch status.mode {
        case .subscription:
            let sub = status.subscription!
            content.title = sub.group?.name ?? "订阅额度"
            content.badge = "有效"
            if let metric = status.primary {
                content.caption = "\(metric.label)剩余额度"
                content.amount = "$\(Format.money(metric.remaining))"
                content.percentage = Format.percent(metric.remainingRatio)
                content.progress = metric.remainingRatio
                content.lines.append("已用 $\(Format.money(metric.used)) / $\(Format.money(metric.limit))")
                for other in status.metrics where other.label != metric.label {
                    content.lines.append("\(other.label)剩余 \(Format.percent(other.remainingRatio)) · $\(Format.money(other.remaining))")
                }
                if let reset = QuotaPolicy.resetDate(for: metric, subscription: sub) {
                    let label = reset == Format.date(sub.expires_at) ? "额度随订阅结束" : "额度重置"
                    content.lines.append(reset > now ? "\(label)：\(Format.remaining(until: reset, now: now))后" : "额度窗口已到，等待刷新确认")
                }
                content.symbol = .quota(metric.remainingRatio)
                content.barText = Format.percent(metric.remainingRatio)
                content.isWarning = metric.remainingRatio <= 0.1
                if metric.remainingRatio == 0 {
                    content.banner = "此订阅额度已用尽"
                    content.symbol = .warning
                }
            } else {
                content.caption = "订阅额度"
                content.amount = "暂不可用"
                content.lines.append("服务未返回完整的额度信息。")
            }
            if status.hasUnknownUsage {
                content.lines.append("部分周期额度暂不可确认")
                content.symbol = .unknown
                content.barText = "--"
            }
            if let expires = Format.date(sub.expires_at) {
                content.lines.append("还有 \(Format.remaining(until: expires, now: now))到期")
            }
            if let balance = status.balance {
                let age = snapshot.profileError == nil ? "" : "（\(Format.updated(snapshot.profileFetchedAt, now: now))）"
                content.lines.append("余额 $\(Format.money(balance))\(age)")
            } else { content.lines.append("余额暂不可用") }
            content.lines.append(Format.updated(snapshot.subscriptionsFetchedAt, now: now))
        case .balance:
            content.title = "余额消费"
            content.caption = "账户余额（USD）"
            content.amount = "$\(Format.money(status.balance!))"
            content.lines = ["按实际用量扣费", "无有效订阅，可使用账户余额", Format.updated(snapshot.profileFetchedAt, now: now)]
            content.symbol = .balance
            content.barText = content.amount
        case .unavailable:
            content.title = "暂无可用额度"
            content.caption = "账户余额（USD）"
            content.amount = "$\(Format.money(status.balance!))"
            content.lines = ["无有效订阅，账户余额不足。", "可打开订阅页查看或补充额度。", Format.updated(snapshot.profileFetchedAt, now: now)]
            content.symbol = .warning
            content.barText = "暂无额度"
            content.isWarning = true
        case .unknown:
            content.title = "账户状态"
            content.caption = "暂时无法确认可用额度"
            content.amount = "--"
            if let balance = status.balance { content.lines.append("账户余额 $\(Format.money(balance))") }
            content.lines.append(snapshot.subscriptions == nil ? "订阅信息尚未成功获取。" : "订阅状态或有效期需要刷新确认。")
            if let date = snapshot.profileFetchedAt { content.lines.append("余额：\(Format.updated(date, now: now))") }
            content.symbol = .unknown
        }
        let failures = [snapshot.subscriptionError, snapshot.profileError, store.error].compactMap { $0 }
        let primaryIsStale = snapshot.subscriptionError != nil || store.error != nil ||
            (status.mode != .subscription && snapshot.profileError != nil)
        if !failures.isEmpty {
            if status.mode == .unknown && snapshot.subscriptionsFetchedAt == nil && snapshot.profileError == nil && snapshot.profileFetchedAt != nil {
                content.banner = "订阅获取失败 · 余额已更新"
                content.lines.append(failures[0].localizedDescription)
            } else if status.mode == .subscription && !primaryIsStale {
                content.banner = "余额暂不可用 · 订阅额度已更新"
            } else {
                let hasData = snapshot.subscriptionsFetchedAt != nil || snapshot.profileFetchedAt != nil
                content.banner = failures.contains(where: \.isNetwork)
                    ? (hasData ? "当前离线 · 显示最近数据" : "当前离线 · 请检查网络")
                    : (hasData ? "刷新失败 · 显示最近数据" : "获取失败 · 可立即重试")
                content.lines.append(failures[0].localizedDescription)
                content.symbol = .unknown
                if content.barText != "--" { content.barText = "~" + content.barText }
                if status.mode == .balance { content.caption = "最近已知余额（USD）" }
            }
        } else if store.isRefreshing {
            content.banner = "正在刷新…"
        }
        content.tooltip = (["AllinAI", content.title, content.caption + " " + content.amount,
                            content.percentage ?? ""] + content.lines + [content.banner ?? ""])
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return content
    }
}

@MainActor
enum AppearanceStyle {
    static let warningText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.62, blue: 0.58, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.15, blue: 0.11, alpha: 1)
    }
    static let caution = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.72, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.52, green: 0.33, blue: 0.04, alpha: 1)
    }
}

final class QuotaProgressView: NSView {
    let progress: Double
    init(frame: NSRect, progress: Double) {
        self.progress = progress
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("剩余额度")
        setAccessibilityValue(Format.percent(progress))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        guard progress > 0 else { return }
        (progress <= 0.1 ? AppearanceStyle.warningText : progress <= 0.3 ? AppearanceStyle.caution : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()
    }
}

final class SummaryView: NSView {
    override var isFlipped: Bool { true }
    init(content: SummaryContent, width: CGFloat = 352) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let inset: CGFloat = 18
        let usable = width - 2 * inset
        var y: CGFloat = 12
        func text(_ value: String, size: CGFloat = 12, color: NSColor = .labelColor,
                  weight: NSFont.Weight = .regular, x: CGFloat? = nil, w: CGFloat? = nil, wrap: Bool = false) -> CGFloat {
            let label = NSTextField(labelWithString: value)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = color
            label.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
            label.maximumNumberOfLines = wrap ? 0 : 1
            let available = w ?? usable
            let height: CGFloat = wrap ? ceil(label.attributedStringValue.boundingRect(with: NSSize(width: available, height: 200),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 3 : ceil(size * 1.45)
            label.frame = NSRect(x: x ?? inset, y: y, width: available, height: max(height, size + 4))
            label.setAccessibilityLabel(value)
            addSubview(label)
            return label.frame.height
        }
        _ = text("AllinAI", size: 13, weight: .semibold, w: 90)
        if !content.account.isEmpty {
            let label = NSTextField(labelWithString: content.account)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = NSRect(x: 112, y: y, width: width - 130, height: 19)
            label.setAccessibilityLabel("当前账号：\(content.account)")
            addSubview(label)
        }
        y += 28
        y += text(content.title, size: 13, weight: .medium, w: content.badge.isEmpty ? usable : usable - 48) + 6
        if !content.badge.isEmpty {
            y -= ceil(13 * 1.45) + 6
            _ = text(content.badge, size: 11, color: .secondaryLabelColor, x: width - 52, w: 34)
            y += ceil(13 * 1.45) + 6
        }
        if let banner = content.banner {
            let bannerHeight = text(banner, size: 11, color: content.isWarning ? AppearanceStyle.warningText : .secondaryLabelColor, wrap: true)
            y += bannerHeight + 7
        }
        y += text(content.caption, size: 11, color: .secondaryLabelColor) + 1
        let amountSize: CGFloat = content.amount.count > 12 ? 22 : 28
        let amountHeight = text(content.amount, size: amountSize, color: content.isWarning ? AppearanceStyle.warningText : .labelColor,
                                weight: .semibold, w: content.percentage == nil ? usable : usable - 85)
        if let percentage = content.percentage {
            let label = NSTextField(labelWithString: percentage)
            label.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
            label.alignment = .right
            label.frame = NSRect(x: width - 99, y: y + 8, width: 81, height: 31)
            label.setAccessibilityLabel("剩余 \(percentage)")
            addSubview(label)
        }
        y += amountHeight + 7
        if let progress = content.progress {
            addSubview(QuotaProgressView(frame: NSRect(x: inset, y: y, width: usable, height: 5), progress: progress))
            y += 16
        }
        for value in content.lines {
            y += text(value, size: 11.5, color: .secondaryLabelColor, wrap: true) + 3
        }
        frame.size.height = y + 9
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum ProgressIcon {
    static func make(_ symbol: StatusSymbol) -> NSImage {
        let name: String?
        switch symbol {
        case .quota: name = nil
        case .balance: name = "dollarsign.circle"
        case .warning: name = "exclamationmark.circle"
        case .unknown: name = "questionmark.circle"
        case .account: name = "person.crop.circle"
        }
        if let name, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 1.8
        NSColor.black.withAlphaComponent(0.25).setStroke()
        track.stroke()
        if case .quota(let progress) = symbol, progress > 0 {
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 7, startAngle: 90,
                           endAngle: 90 - max(0, min(progress, 1)) * 360, clockwise: true)
            path.lineWidth = 2.3
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
        }
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 2, height: 2)).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// MARK: - Startup and native account panel

enum StartupManager {
    private static let label = "local.allinai.quota.menu"
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    private static var url: URL { directory.appendingPathComponent("\(label).plist") }
    static func isEnabled() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = value as? [String: Any], let arguments = plist["ProgramArguments"] as? [String],
              let executable = Bundle.main.executablePath else { return false }
        return arguments.first == executable && plist["RunAtLoad"] as? Bool == true
    }
    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        guard let executable = Bundle.main.executablePath else { throw ClientError.storage("无法定位当前应用程序。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable], "RunAtLoad": true, "KeepAlive": false]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
    }
}

@MainActor
final class LoginPanelController: NSWindowController, NSWindowDelegate {
    private let emailField: NSTextField
    private let passwordField = NSSecureTextField(string: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let loginButton = NSButton(title: "登录", target: nil, action: nil)
    private let store: QuotaStore
    private var task: Task<Void, Never>?
    var onClose: (() -> Void)?

    init(store: QuotaStore) {
        self.store = store
        emailField = NSTextField(string: store.config.email)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 260),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "登录 AllinAI"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        emailField.placeholderString = "邮箱"
        passwordField.placeholderString = "密码"
        emailField.setAccessibilityLabel("邮箱")
        passwordField.setAccessibilityLabel("密码")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "邮箱"), emailField],
                                      [NSTextField(labelWithString: "密码"), passwordField]])
        grid.columnSpacing = 12
        grid.rowSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        let explanation = NSTextField(wrappingLabelWithString: "账号信息保存在本机，密码保存在 macOS 钥匙串。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        message.textColor = AppearanceStyle.warningText
        loginButton.target = self
        loginButton.action = #selector(submit)
        loginButton.keyEquivalent = "\r"
        loginButton.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, loginButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [explanation, grid, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.heightAnchor.constraint(equalToConstant: 40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(emailField.stringValue.isEmpty ? emailField : passwordField)
    }
    @objc private func submit() {
        guard task == nil else { return }
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !email.isEmpty, !password.isEmpty else { message.stringValue = "请输入邮箱和密码。"; return }
        message.stringValue = "正在登录…"
        message.textColor = .secondaryLabelColor
        loginButton.isEnabled = false
        emailField.isEnabled = false
        passwordField.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.signIn(email: email, password: password)
                guard !Task.isCancelled else { return }
                passwordField.stringValue = ""
                window?.close()
            } catch {
                guard !Task.isCancelled else { return }
                message.textColor = AppearanceStyle.warningText
                message.stringValue = ClientError.from(error).localizedDescription
                loginButton.isEnabled = true
                emailField.isEnabled = true
                passwordField.isEnabled = true
                task = nil
            }
        }
    }
    @objc private func cancel() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        passwordField.stringValue = ""
        onClose?()
    }
}

// MARK: - Menu bar application

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let store: QuotaStore
    private let reminders = ReminderManager()
    private let updates = UpdateChecker()
    private let directory: URL
    private var headerItem: NSMenuItem?
    private var menuIsOpen = false
    private var startupEnabled = false
    private var visibleTimer: Timer?
    private var loginPanel: LoginPanelController?
    private let networkMonitor = NWPathMonitor()
    private var lastConnected: Bool?

    override init() {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = supportRoot.appendingPathComponent("AllinAIQuotaMenu", isDirectory: true)
        let legacy = supportRoot.appendingPathComponent("AllinCodeQuotaMenu", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: directory)
        }
        self.directory = directory
        self.store = QuotaStore(client: AllinClient(storage: LocalStorage(directory: directory)))
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        startupEnabled = StartupManager.isEnabled()
        UNUserNotificationCenter.current().delegate = self
        store.onChange = { [weak self] in self?.render() }
        updates.onChange = { [weak self] in self?.render() }
        updates.onManualResult = { [weak self] result in self?.showUpdateResult(result) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if connected && self.lastConnected == false { self.store.recoverConnection() }
                self.lastConnected = connected
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "local.allinai.quota.network"))
        render()
        Task { await store.start() }
        updates.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.cancel()
        store.suspend()
        updates.stop()
        visibleTimer?.invalidate()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
    @objc private func willSleep(_ notification: Notification) { store.suspend(); updates.stop() }
    @objc private func didWake(_ notification: Notification) { store.resume(); updates.start() }

    private func render() {
        let content = SummaryContent.make(store: store)
        let numbers = UserDefaults.standard.bool(forKey: Preferences.numbers)
        statusItem.length = numbers ? NSStatusItem.variableLength : NSStatusItem.squareLength
        statusItem.button?.image = ProgressIcon.make(content.symbol)
        statusItem.button?.title = numbers ? " " + content.barText : ""
        if case .balance = content.symbol, numbers { statusItem.button?.image = nil }
        statusItem.button?.toolTip = content.tooltip + (updates.availableRelease.map { "\n发现新版本 v\($0.version!.description)，可在“关于”中查看。" } ?? "")
        statusItem.button?.setAccessibilityLabel(content.tooltip)
        if menuIsOpen {
            headerItem?.view = SummaryView(content: content)
            if let refresh = menu.item(withTag: 11) { refresh.isEnabled = store.canRefresh }
            updateAboutMenu()
            menu.update()
        } else { rebuildMenu(content: content) }
        reminders.evaluate(store: store)
    }
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(content: SummaryContent.make(store: store))
        menuIsOpen = true
        store.refreshIfNeeded()
        visibleTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibleTimer = timer
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        visibleTimer?.invalidate()
        visibleTimer = nil
    }
    private func rebuildMenu(content: SummaryContent) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "账户概览", action: nil, keyEquivalent: "")
        header.view = SummaryView(content: content)
        menu.addItem(header)
        headerItem = header
        menu.addItem(.separator())
        if store.isConfigured {
            let refresh = item("立即刷新", #selector(refresh), key: "r")
            refresh.tag = 11
            refresh.isEnabled = store.canRefresh
            menu.addItem(refresh)
            if store.needsLogin { menu.addItem(item("重新登录…", #selector(configureAccount), key: ",")) }
        } else { menu.addItem(item("登录…", #selector(configureAccount), key: ",")) }
        menu.addItem(item("打开订阅页", #selector(openSubscriptions), key: "o"))
        if let subscriptions = store.snapshot.subscriptions, !subscriptions.isEmpty {
            let details = NSMenuItem(title: "订阅详情", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for sub in subscriptions {
                let entry = NSMenuItem(title: "\(sub.group?.name ?? "订阅") · \(Format.status(sub.status))", action: nil, keyEquivalent: "")
                let detail = NSMenu()
                detail.autoenablesItems = false
                var info = SummaryContent()
                info.title = sub.group?.name ?? "订阅"
                info.caption = "\(sub.group?.platform ?? "平台未提供") · \(Format.status(sub.status))"
                let metrics = QuotaPolicy.metrics(for: sub)
                info.amount = "订阅详情"
                info.lines = metrics.map { "\($0.label)：已用 $\(Format.money($0.used)) / $\(Format.money($0.limit))" }
                if metrics.isEmpty { info.lines.append("额度信息暂不可确认") }
                if let starts = Format.date(sub.starts_at) { info.lines.append("开始：\(Format.timestamp(starts, full: true))") }
                if let expires = Format.date(sub.expires_at) { info.lines.append("到期：\(Format.timestamp(expires, full: true))") }
                if let description = sub.group?.description, !description.isEmpty {
                    info.lines.append(String(description.prefix(160)) + (description.count > 160 ? "…" : ""))
                }
                let overview = NSMenuItem(title: "订阅信息", action: nil, keyEquivalent: "")
                overview.view = SummaryView(content: info)
                detail.addItem(overview)
                if QuotaPolicy.isActive(sub, now: Date()), let id = sub.id {
                    let select = item("在菜单栏显示此订阅", #selector(selectSubscription(_:)))
                    select.representedObject = id
                    select.state = store.status.subscription?.id == id ? .on : .off
                    detail.addItem(select)
                }
                if let description = sub.group?.description, description.count > 160 {
                    let full = item("完整说明…", #selector(showDescription(_:)))
                    full.representedObject = description
                    detail.addItem(full)
                }
                entry.submenu = detail
                submenu.addItem(entry)
            }
            details.submenu = submenu
            menu.addItem(details)
        }
        menu.addItem(.separator())
        let intervals = NSMenuItem(title: "刷新间隔 · \(store.config.refreshIntervalSeconds / 60) 分钟", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        intervalMenu.autoenablesItems = false
        for seconds in AppInfo.intervals {
            let entry = item("\(seconds / 60) 分钟", #selector(setInterval(_:)))
            entry.representedObject = seconds
            entry.state = store.config.refreshIntervalSeconds == seconds ? .on : .off
            intervalMenu.addItem(entry)
        }
        intervals.submenu = intervalMenu
        menu.addItem(intervals)
        let startup = item("开机自启动", #selector(toggleStartup))
        startup.state = startupEnabled ? .on : .off
        menu.addItem(startup)

        let tools = NSMenuItem(title: "账号与工具", action: nil, keyEquivalent: "")
        let toolMenu = NSMenu()
        toolMenu.autoenablesItems = false
        if store.isConfigured {
            toolMenu.addItem(item("重新登录…", #selector(configureAccount), key: ","))
            toolMenu.addItem(item("退出登录…", #selector(logout), key: "l"))
            toolMenu.addItem(.separator())
        }
        let numbers = item("菜单栏显示数值", #selector(toggleNumbers))
        numbers.state = UserDefaults.standard.bool(forKey: Preferences.numbers) ? .on : .off
        toolMenu.addItem(numbers)
        let reminderItem = NSMenuItem(title: "提醒设置", action: nil, keyEquivalent: "")
        let reminderMenu = NSMenu()
        reminderMenu.autoenablesItems = false
        let enabled = item("开启额度与到期提醒", #selector(toggleReminders))
        enabled.state = UserDefaults.standard.bool(forKey: Preferences.reminders) ? .on : .off
        reminderMenu.addItem(enabled)
        reminderMenu.addItem(.separator())
        let explanation = NSMenuItem(title: "到期前 3 天／1 天、剩余额度 10% 时提醒", action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        reminderMenu.addItem(explanation)
        let threshold = UserDefaults.standard.double(forKey: Preferences.lowBalance)
        for value in [0, 1, 5, 10] {
            let entry = item(value == 0 ? "关闭低余额提醒" : "余额不高于 $\(value) 时提醒", #selector(setLowBalance(_:)))
            entry.representedObject = value
            entry.state = threshold == Double(value) ? .on : .off
            reminderMenu.addItem(entry)
        }
        reminderItem.submenu = reminderMenu
        toolMenu.addItem(reminderItem)
        toolMenu.addItem(item("打开配置文件夹", #selector(openConfigFolder)))
        tools.submenu = toolMenu
        menu.addItem(tools)
        menu.addItem(.separator())
        let version = NSMenuItem(title: "版本：v\(AppInfo.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let about = NSMenuItem(title: "关于 AllinAI Quota", action: nil, keyEquivalent: "")
        about.tag = 12
        about.submenu = makeAboutMenu()
        menu.addItem(about)
        updateAboutMenu()
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }
    private func updateAboutMenu() {
        guard let about = menu.item(withTag: 12) else { return }
        about.title = updates.availableRelease == nil ? "关于 AllinAI Quota" : "关于 AllinAI Quota · 有新版本"
        // Keep the submenu object alive while NSMenu is tracking it.
        if let submenu = about.submenu {
            submenu.item(withTag: 21)?.title = updates.isChecking ? "正在检查更新…" : "检查更新…"
            submenu.item(withTag: 21)?.isEnabled = !updates.isChecking
            let download = submenu.item(withTag: 22)
            download?.isHidden = updates.availableRelease == nil
            download?.title = updates.availableRelease.map { "下载 v\($0.version!.description)…" } ?? "下载新版本…"
            let checked = submenu.item(withTag: 23)
            checked?.title = updates.lastChecked.map { "上次检查：\(Format.timestamp($0, full: true))" } ?? "尚未检查更新"
            submenu.item(withTag: 24)?.state = updates.automaticChecksEnabled ? .on : .off
            submenu.update()
        }
    }
    private func makeAboutMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let check = item("检查更新…", #selector(checkForUpdates))
        check.tag = 21
        submenu.addItem(check)
        let download = item("下载新版本…", #selector(openAvailableRelease))
        download.tag = 22
        submenu.addItem(download)
        let automatic = item("自动检查更新（每天）", #selector(toggleAutomaticUpdates))
        automatic.tag = 24
        submenu.addItem(automatic)
        let checked = NSMenuItem(title: "尚未检查更新", action: nil, keyEquivalent: "")
        checked.tag = 23
        checked.isEnabled = false
        submenu.addItem(checked)
        submenu.addItem(.separator())
        submenu.addItem(item("更新记录…", #selector(openReleases)))
        submenu.addItem(item("开源地址（GitHub）…", #selector(openRepository)))
        return submenu
    }
    @objc private func checkForUpdates() { updates.check() }
    @objc private func toggleAutomaticUpdates() { updates.setAutomaticChecksEnabled(!updates.automaticChecksEnabled) }
    @objc private func openRepository() { NSWorkspace.shared.open(AppInfo.repositoryURL) }
    @objc private func openReleases() { NSWorkspace.shared.open(AppInfo.releasesURL) }
    @objc private func openAvailableRelease() {
        if let release = updates.availableRelease { NSWorkspace.shared.open(release.pageURL) }
    }
    private func showUpdateResult(_ result: UpdateState) {
        let alert = NSAlert()
        switch result {
        case .available(let release):
            alert.messageText = "发现新版本 v\(release.version!.description)"
            alert.informativeText = "当前版本：v\(AppInfo.version)。打开 GitHub Release 查看更新说明并下载 AllinAI-Quota.dmg。下载后退出旧版，将应用拖入“应用程序”替换，再重新打开。"
            alert.addButton(withTitle: "打开下载页面")
            alert.addButton(withTitle: "稍后")
        case .current(let release):
            alert.messageText = "当前无需更新"
            alert.informativeText = "当前版本：v\(AppInfo.version)\nGitHub 最新正式版：v\(release.version!.description)"
            alert.addButton(withTitle: "好")
        case .noRelease:
            alert.messageText = "暂无正式发布版本"
            alert.informativeText = "GitHub 上尚未找到可用的正式 Release。可以打开更新记录查看发布情况。"
            alert.addButton(withTitle: "打开更新记录")
            alert.addButton(withTitle: "好")
        case .failed(let error):
            alert.messageText = "检查更新失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "打开更新记录")
            alert.addButton(withTitle: "好")
        case .idle, .checking: return
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch result {
        case .available(let release): NSWorkspace.shared.open(release.pageURL)
        case .noRelease, .failed: openReleases()
        default: break
        }
    }
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    @objc private func refresh() { store.refresh() }
    @objc private func configureAccount() {
        if let loginPanel { loginPanel.present(); return }
        let controller = LoginPanelController(store: store)
        controller.onClose = { [weak self] in self?.loginPanel = nil }
        loginPanel = controller
        controller.present()
    }
    @objc private func logout() {
        let alert = NSAlert()
        alert.messageText = "退出登录？"
        alert.informativeText = "这会移除钥匙串中的密码并清除本地令牌。邮箱和刷新间隔会保留。"
        alert.addButton(withTitle: "退出登录")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await store.logout() }
            catch { showAlert("本机已退出，凭据清理未完成", ClientError.from(error).localizedDescription) }
        }
    }
    @objc private func openSubscriptions() { NSWorkspace.shared.open(URL(string: "https://allincode.top/subscriptions")!) }
    @objc private func openConfigFolder() { NSWorkspace.shared.open(directory) }
    @objc private func toggleStartup() {
        do {
            try StartupManager.setEnabled(!startupEnabled)
            startupEnabled = StartupManager.isEnabled()
            render()
        } catch { showAlert("设置开机自启动失败", error.localizedDescription) }
    }
    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        Task {
            do { try await store.setInterval(seconds) }
            catch { showAlert("保存刷新间隔失败", ClientError.from(error).localizedDescription) }
        }
    }
    @objc private func selectSubscription(_ sender: NSMenuItem) {
        store.selectedSubscriptionID = sender.representedObject as? Int
        render()
    }
    @objc private func showDescription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "订阅说明"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.string = text
        view.isEditable = false
        view.font = .systemFont(ofSize: 13)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func toggleNumbers() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Preferences.numbers), forKey: Preferences.numbers)
        render()
    }
    @objc private func toggleReminders() {
        if UserDefaults.standard.bool(forKey: Preferences.reminders) {
            UserDefaults.standard.set(false, forKey: Preferences.reminders)
            render()
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                UserDefaults.standard.set(granted, forKey: Preferences.reminders)
                if !granted { self.showAlert("通知尚未开启", error?.localizedDescription ?? "可在系统设置的通知中允许 AllinAI Quota 发送提醒。") }
                self.render()
            }
        }
    }
    @objc private func setLowBalance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(value, forKey: Preferences.lowBalance)
        render()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

#if !QUOTA_TESTING
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
#endif

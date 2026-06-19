import AppKit
import Foundation
import Security

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
}

struct Config: Codable {
    var email: String
    var refreshIntervalSeconds: Int
}

struct LegacyConfig: Codable {
    var email: String?
    var password: String?
    var refreshIntervalSeconds: Int?
}

struct TokenCache: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval
}

struct APIEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
}

struct LoginData: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}

struct UserProfile: Decodable {
    let username: String?
    let email: String?
    let balance: Double?

    var displayName: String? {
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return username
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return nil
    }
}

struct Subscription: Decodable {
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

struct Group: Decodable {
    let name: String?
    let description: String?
    let platform: String?
    let daily_limit_usd: Double?
    let weekly_limit_usd: Double?
    let monthly_limit_usd: Double?
}

struct QuotaMetric {
    let label: String
    let used: Double
    let limit: Double
    let windowStart: String?
    let hours: Int

    var ratio: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }
}

struct SubscriptionSummary {
    let subscription: Subscription
    let metric: QuotaMetric?
    let userDisplayName: String?
    let balance: Double?
    let fetchedAt: Date
}

enum FetchState {
    case idle
    case loading
    case loaded(SubscriptionSummary)
    case empty(Date, Double?, String?)
    case failed(String, Date?)
}

final class AllinClient {
    private let baseURL = URL(string: "https://allincode.top/api/v1")!
    private let appSupportDir: URL
    private let configURL: URL
    private let tokenURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychain = Keychain(service: "local.allinai.quota.menu")

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
        self.configURL = appSupportDir.appendingPathComponent("config.json")
        self.tokenURL = appSupportDir.appendingPathComponent("tokens.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func ensureFiles() throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let config = Config(
                email: "",
                refreshIntervalSeconds: 300
            )
            try encoder.encode(config).write(to: configURL, options: [.atomic])
        } else {
            try migrateLegacyConfigIfNeeded()
        }
    }

    func readConfig() throws -> Config {
        try ensureFiles()
        return try decoder.decode(Config.self, from: Data(contentsOf: configURL))
    }

    func writeConfig(_ config: Config) throws {
        try ensureFiles()
        try encoder.encode(config).write(to: configURL, options: [.atomic])
    }

    func saveCredentials(email: String, password: String) throws {
        var config = try readConfig()
        config.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeConfig(config)
        try keychain.set(password, account: config.email)
        try clearTokenCache()
    }

    func passwordForConfiguredAccount() throws -> String? {
        let config = try readConfig()
        guard !config.email.isEmpty else { return nil }
        return keychain.get(account: config.email)
    }

    func hasConfiguredCredentials() -> Bool {
        guard let config = try? readConfig(), !config.email.isEmpty else { return false }
        return keychain.contains(account: config.email)
    }

    func clearTokenCache() throws {
        if FileManager.default.fileExists(atPath: tokenURL.path) {
            try FileManager.default.removeItem(at: tokenURL)
        }
    }

    func logout() throws {
        let config = try readConfig()
        if !config.email.isEmpty {
            try keychain.delete(account: config.email)
        }
        try clearTokenCache()
    }

    func fetchSubscriptions(forceLogin: Bool = false) async throws -> [Subscription] {
        let token = try await validAccessToken(forceLogin: forceLogin)
        do {
            return try await requestSubscriptions(accessToken: token)
        } catch {
            let fresh = try await validAccessToken(forceLogin: true)
            return try await requestSubscriptions(accessToken: fresh)
        }
    }

    func fetchAccountStatus(forceLogin: Bool = false) async throws -> ([Subscription], UserProfile?) {
        let token = try await validAccessToken(forceLogin: forceLogin)
        do {
            let subscriptions = try await requestSubscriptions(accessToken: token)
            let profile = try? await requestUserProfile(accessToken: token)
            return (subscriptions, profile)
        } catch {
            let fresh = try await validAccessToken(forceLogin: true)
            let subscriptions = try await requestSubscriptions(accessToken: fresh)
            let profile = try? await requestUserProfile(accessToken: fresh)
            return (subscriptions, profile)
        }
    }

    private func validAccessToken(forceLogin: Bool) async throws -> String {
        if !forceLogin, let cache = readTokenCache(), cache.expiresAt > Date().timeIntervalSince1970 + 60 {
            return cache.accessToken
        }

        if !forceLogin, let cache = readTokenCache(), !cache.refreshToken.isEmpty {
            do {
                return try await refreshToken(cache.refreshToken)
            } catch {
                return try await login()
            }
        }

        return try await login()
    }

    private func login() async throws -> String {
        let config = try readConfig()
        guard !config.email.isEmpty else {
            throw NSError(domain: "AllinAI", code: 10, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
        }
        guard let password = try passwordForConfiguredAccount(), !password.isEmpty else {
            throw NSError(domain: "AllinAI", code: 11, userInfo: [NSLocalizedDescriptionKey: "请先输入密码"])
        }
        let body: [String: String] = [
            "email": config.email,
            "password": password
        ]
        let response: LoginData = try await post("/auth/login", body: body)
        try save(loginData: response)
        return response.access_token
    }

    private func refreshToken(_ token: String) async throws -> String {
        let response: LoginData = try await post("/auth/refresh", body: ["refresh_token": token])
        try save(loginData: response)
        return response.access_token
    }

    private func requestSubscriptions(accessToken: String) async throws -> [Subscription] {
        var components = URLComponents(url: baseURL.appendingPathComponent("subscriptions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AllinAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "请求失败"])
        }

        let envelope = try decoder.decode(APIEnvelope<[Subscription]>.self, from: data)
        if let code = envelope.code, code != 0 {
            throw NSError(domain: "AllinAI", code: code, userInfo: [NSLocalizedDescriptionKey: envelope.message ?? "API error"])
        }
        return envelope.data ?? []
    }

    private func requestUserProfile(accessToken: String) async throws -> UserProfile {
        var request = URLRequest(url: baseURL.appendingPathComponent("user/profile"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AllinAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "余额请求失败"])
        }

        let envelope = try decoder.decode(APIEnvelope<UserProfile>.self, from: data)
        if let code = envelope.code, code != 0 {
            throw NSError(domain: "AllinAI", code: code, userInfo: [NSLocalizedDescriptionKey: envelope.message ?? "API error"])
        }
        guard let payload = envelope.data else {
            throw NSError(domain: "AllinAI", code: 5, userInfo: [NSLocalizedDescriptionKey: "余额响应为空"])
        }
        return payload
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AllinAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "登录请求失败"])
        }

        let envelope = try decoder.decode(APIEnvelope<T>.self, from: data)
        if let code = envelope.code, code != 0 {
            throw NSError(domain: "AllinAI", code: code, userInfo: [NSLocalizedDescriptionKey: envelope.message ?? "API error"])
        }
        guard let payload = envelope.data else {
            throw NSError(domain: "AllinAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "响应为空"])
        }
        return payload
    }

    private func save(loginData: LoginData) throws {
        let cache = TokenCache(
            accessToken: loginData.access_token,
            refreshToken: loginData.refresh_token ?? "",
            expiresAt: Date().timeIntervalSince1970 + Double(loginData.expires_in ?? 3600)
        )
        try encoder.encode(cache).write(to: tokenURL, options: [.atomic])
    }

    private func readTokenCache() -> TokenCache? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? decoder.decode(TokenCache.self, from: data)
    }

    private func migrateLegacyConfigIfNeeded() throws {
        let data = try Data(contentsOf: configURL)
        guard let legacy = try? decoder.decode(LegacyConfig.self, from: data) else { return }
        let config = Config(
            email: legacy.email ?? "",
            refreshIntervalSeconds: legacy.refreshIntervalSeconds ?? 300
        )
        if let email = legacy.email, let password = legacy.password, !email.isEmpty, !password.isEmpty {
            try keychain.set(password, account: email)
        }
        try encoder.encode(config).write(to: configURL, options: [.atomic])
    }
}

final class Keychain {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func set(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "保存密码到钥匙串失败"])
        }
    }

    func get(account: String) -> String? {
        let activate = {
            NSApp.activate(ignoringOtherApps: true)
        }
        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.sync(execute: activate)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func contains(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "从钥匙串移除密码失败"])
        }
    }
}

enum StartupManager {
    private static let label = "local.allinai.quota.menu"
    private static let launchAgentsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    private static let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")

    static func isEnabled() -> Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return false }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let args = dict["ProgramArguments"] as? [String],
              let executable = Bundle.main.executablePath else {
            return true
        }
        return args.first == executable
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    private static func enable() throws {
        guard let executable = Bundle.main.executablePath else {
            throw NSError(domain: "AllinAI", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法定位当前应用程序。"])
        }

        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": "/tmp/\(label).out.log",
            "StandardErrorPath": "/tmp/\(label).err.log"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
    }

    private static func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let client: AllinClient
    private let appSupportDir: URL
    private var config = Config(email: "", refreshIntervalSeconds: 300)
    private var state: FetchState = .idle
    private var timer: Timer?
    private var isFetching = false

    override init() {
        let supportRoot = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = supportRoot.appendingPathComponent("AllinAIQuotaMenu", isDirectory: true)
        let legacyDir = supportRoot.appendingPathComponent("AllinCodeQuotaMenu", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        self.appSupportDir = dir
        self.client = AllinClient(appSupportDir: dir)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "AllinAI 未加载"
        setIcon(progress: nil, color: .systemGray)

        do {
            try client.ensureFiles()
            config = try client.readConfig()
        } catch {
            state = .failed(error.localizedDescription, nil)
        }

        rebuildMenu()
        if config.email.isEmpty {
            state = .failed("请登录", nil)
            setIcon(progress: nil, color: .systemGray)
            rebuildMenu()
        } else {
            refreshNow()
        }
        scheduleTimer()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func refreshNow(forceLogin: Bool = false) {
        guard !isFetching else { return }
        isFetching = true
        state = .loading
        rebuildMenu()
        setIcon(progress: nil, color: .systemBlue)

        Task {
            do {
                let accountStatus = try await client.fetchAccountStatus(forceLogin: forceLogin)
                let subscriptions = accountStatus.0
                let profile = accountStatus.1
                let now = Date()
                if let active = subscriptions.first(where: { $0.status == "active" }) ?? subscriptions.first {
                    let summary = SubscriptionSummary(
                        subscription: active,
                        metric: bestMetric(for: active),
                        userDisplayName: profile?.displayName,
                        balance: profile?.balance,
                        fetchedAt: now
                    )
                    await MainActor.run {
                        self.state = .loaded(summary)
                        self.isFetching = false
                        self.applyIcon(summary)
                        self.rebuildMenu()
                    }
                } else {
                    await MainActor.run {
                        self.state = .empty(now, profile?.balance, profile?.displayName)
                        self.isFetching = false
                        self.setIcon(progress: 0, color: .systemGray)
                        self.rebuildMenu()
                    }
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription, Date())
                    self.isFetching = false
                    self.setIcon(progress: nil, color: .systemRed)
                    self.rebuildMenu()
                }
            }
        }
    }

    private func rebuildMenu() {
        updateTooltip()
        menu.removeAllItems()
        let hasCredentials = client.hasConfiguredCredentials()

        if hasCredentials {
            switch state {
            case .idle:
                disabled("未加载")
            case .loading:
                disabled("正在刷新...")
            case .empty(let date, let balance, _):
                addBalance(balance)
                disabled("没有有效订阅")
                disabled("更新于 \(formatTime(date))")
            case .failed(let message, let date):
                disabled("获取失败")
                disabled(message)
                if let date { disabled("更新于 \(formatTime(date))") }
            case .loaded(let summary):
                addDetails(summary)
            }
        } else {
            disabled("请登录")
        }

        menu.addItem(.separator())
        if hasCredentials {
            menu.addItem(item(logoutTitle(), action: #selector(logoutMenu), key: "l"))
            menu.addItem(item("立即刷新", action: #selector(refreshMenu), key: "r"))
        } else {
            menu.addItem(item("登录...", action: #selector(configureAccount), key: ","))
        }
        menu.addItem(item("打开订阅页", action: #selector(openSubscriptions), key: "o"))

        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for seconds in [60, 300, 600, 1800] {
            let title = seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
            let it = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.representedObject = seconds
            it.state = config.refreshIntervalSeconds == seconds ? .on : .off
            intervalMenu.addItem(it)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let startupItem = item("开机自启动", action: #selector(toggleStartup), key: "")
        startupItem.state = StartupManager.isEnabled() ? .on : .off
        menu.addItem(startupItem)

        menu.addItem(item("打开配置文件夹", action: #selector(openConfigFolder), key: ""))
        menu.addItem(.separator())
        disabled("版本：v\(AppInfo.version)")
        menu.addItem(item("退出", action: #selector(quit), key: "q"))
    }

    private func addDetails(_ summary: SubscriptionSummary) {
        let sub = summary.subscription
        let group = sub.group
        addBalance(summary.balance)
        disabled(group?.name ?? "订阅")
        if let platform = group?.platform, !platform.isEmpty {
            disabled("平台：\(platform)")
        }
        if let desc = group?.description, !desc.isEmpty {
            disabled(desc)
        }
        disabled("状态：\(statusText(sub.status))")

        if let expires = parseDate(sub.expires_at) {
            disabled("到期时间：\(formatDate(expires))")
            disabled("剩余时间：\(remainingText(until: expires))")
        }

        if let metric = summary.metric {
            disabled("\(metric.label)：$\(money(metric.used)) / $\(money(metric.limit))")
            disabled("已用：\(Int(round(metric.ratio * 100)))%")
            if let reset = resetDate(start: metric.windowStart, hours: metric.hours) {
                disabled("重置倒计时：\(remainingText(until: reset))")
            }
        } else {
            disabled("额度：无限或不可用")
        }

        disabled("更新于：\(formatTime(summary.fetchedAt))")
    }

    private func addBalance(_ balance: Double?) {
        if let balance {
            disabled("当前余额：$\(money(balance))")
        } else {
            disabled("当前余额：不可用")
        }
        menu.addItem(.separator())
    }

    private func updateTooltip() {
        let text: String
        switch state {
        case .loaded(let summary):
            let quota = summary.metric.map {
                "剩余额度 \(Int(round((1 - $0.ratio) * 100)))%"
            } ?? "额度不限"
            let balance = summary.balance.map { "余额 $\(money($0))" } ?? "余额不可用"
            text = "AllinAI \(quota) | \(balance)"
        case .empty(_, let balance, _):
            let balanceText = balance.map { "余额 $\(money($0))" } ?? "余额不可用"
            text = "AllinAI 无有效订阅 | \(balanceText)"
        case .failed(let message, _):
            text = "AllinAI 获取失败 | \(message)"
        case .loading:
            text = "AllinAI 正在刷新..."
        case .idle:
            text = config.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "AllinAI 请登录"
                : "AllinAI 未加载"
        }
        statusItem.button?.toolTip = text
    }

    private func logoutTitle() -> String {
        if let displayName = currentUserDisplayName() {
            return "退出登录（\(displayName)）"
        }
        return "退出登录"
    }

    private func currentUserDisplayName() -> String? {
        switch state {
        case .loaded(let summary):
            return summary.userDisplayName ?? configuredEmail()
        case .empty(_, _, let displayName):
            return displayName ?? configuredEmail()
        default:
            return configuredEmail()
        }
    }

    private func configuredEmail() -> String? {
        let email = config.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    private func disabled(_ title: String) {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menu.addItem(menuItem)
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    @objc private func refreshMenu() {
        refreshNow()
    }

    @objc private func logoutMenu() {
        let alert = NSAlert()
        alert.messageText = "退出登录？"
        alert.informativeText = "这会从钥匙串移除保存的密码，并清除本地 token 缓存。邮箱和刷新间隔会保留在本地配置中。"
        alert.addButton(withTitle: "退出登录")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try client.logout()
            timer?.invalidate()
            state = .failed("请登录", nil)
            setIcon(progress: nil, color: .systemGray)
            rebuildMenu()
        } catch {
            showAlert(title: "退出登录失败", message: error.localizedDescription)
        }
    }

    @objc private func configureAccount() {
        do {
            config = try client.readConfig()
        } catch {
            showAlert(title: "配置错误", message: error.localizedDescription)
        }

        let alert = NSAlert()
        alert.messageText = "登录 AllinAI"
        alert.informativeText = "账号信息仅保存在本机，密码会写入 macOS 钥匙串。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let emailField = NSTextField(string: config.email)
        emailField.placeholderString = "邮箱"

        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "密码"

        let grid = NSGridView(views: [
            [label("邮箱"), emailField],
            [label("密码"), passwordField]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            emailField.widthAnchor.constraint(equalToConstant: 300),
            passwordField.widthAnchor.constraint(equalToConstant: 300)
        ])

        alert.accessoryView = container
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !email.isEmpty, !password.isEmpty else {
            showAlert(title: "信息不完整", message: "请输入邮箱和密码。")
            return
        }

        do {
            try client.saveCredentials(email: email, password: password)
            config = try client.readConfig()
            state = .idle
            rebuildMenu()
            scheduleTimer()
            refreshNow(forceLogin: true)
        } catch {
            showAlert(title: "保存失败", message: error.localizedDescription)
        }
    }

    @objc private func openSubscriptions() {
        NSWorkspace.shared.open(URL(string: "https://allincode.top/subscriptions")!)
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(appSupportDir)
    }

    @objc private func toggleStartup() {
        do {
            try StartupManager.setEnabled(!StartupManager.isEnabled())
            rebuildMenu()
        } catch {
            showAlert(title: "设置开机自启动失败", message: error.localizedDescription)
        }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        config.refreshIntervalSeconds = seconds
        try? client.writeConfig(config)
        scheduleTimer()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard !config.email.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.refreshIntervalSeconds), repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        timer?.tolerance = min(TimeInterval(config.refreshIntervalSeconds) * 0.2, 60)
    }

    private func bestMetric(for sub: Subscription) -> QuotaMetric? {
        let metrics = [
            QuotaMetric(label: "每日", used: sub.daily_usage_usd ?? 0, limit: sub.group?.daily_limit_usd ?? 0, windowStart: sub.daily_window_start, hours: 24),
            QuotaMetric(label: "每周", used: sub.weekly_usage_usd ?? 0, limit: sub.group?.weekly_limit_usd ?? 0, windowStart: sub.weekly_window_start, hours: 168),
            QuotaMetric(label: "每月", used: sub.monthly_usage_usd ?? 0, limit: sub.group?.monthly_limit_usd ?? 0, windowStart: sub.monthly_window_start, hours: 720)
        ]
        return metrics.first { $0.limit > 0 }
    }

    private func applyIcon(_ summary: SubscriptionSummary) {
        guard summary.subscription.status == "active" else {
            setIcon(progress: nil, color: .systemRed)
            return
        }
        guard let metric = summary.metric else {
            setIcon(progress: 1, color: .systemGreen)
            return
        }
        let color: NSColor
        switch metric.ratio {
        case 0.9...:
            color = .systemRed
        case 0.7..<0.9:
            color = .systemOrange
        default:
            color = .systemGreen
        }
        setIcon(progress: metric.ratio, color: color)
    }

    private func setIcon(progress: Double?, color: NSColor) {
        statusItem.button?.image = ProgressIcon.make(progress: progress, color: color)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func resetDate(start: String?, hours: Int) -> Date? {
        guard let date = parseDate(start) else { return nil }
        return Calendar.current.date(byAdding: .hour, value: hours, to: date)
    }

    private func remainingText(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "已过期" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "active":
            return "有效"
        case "expired":
            return "已过期"
        case let value? where !value.isEmpty:
            return value
        default:
            return "-"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

enum ProgressIcon {
    static func make(progress: Double?, color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let background = NSBezierPath(ovalIn: rect)
        background.lineWidth = 2.2
        NSColor.tertiaryLabelColor.setStroke()
        background.stroke()

        if let progress {
            let path = NSBezierPath()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            let start = 90.0
            let end = 90.0 - max(0, min(progress, 1)) * 360.0
            path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            path.lineWidth = 2.6
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        } else {
            let dot = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4))
            color.setFill()
            dot.fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

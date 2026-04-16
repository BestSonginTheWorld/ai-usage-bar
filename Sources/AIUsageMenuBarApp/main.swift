import AppKit
import Foundation

private let appID = "AIUsageMenuBar"
private let bundleIdentifier = "local.ai-usage-menubar"
private let appSupportURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    .appendingPathComponent("Library/Application Support/\(appID)", isDirectory: true)
private let cacheURL = appSupportURL.appendingPathComponent("usage.json")
private let configURL = appSupportURL.appendingPathComponent("config.json")
private let logsURL = appSupportURL.appendingPathComponent("logs", isDirectory: true)
private let appLogURL = logsURL.appendingPathComponent("app.log")
private let collectorURL = appSupportURL.appendingPathComponent("runtime/ai_usage_collector.py")

private struct AppConfig: Decodable {
    let refreshIntervalSeconds: Int
    let resetLabelStyle: String
    let showResetLabels: Bool
    let showSonnetMetric: Bool
    let showErrorDetails: Bool

    init(
        refreshIntervalSeconds: Int = 900,
        resetLabelStyle: String = "friendly",
        showResetLabels: Bool = true,
        showSonnetMetric: Bool = true,
        showErrorDetails: Bool = true
    ) {
        self.refreshIntervalSeconds = max(60, refreshIntervalSeconds)
        self.resetLabelStyle = resetLabelStyle == "source" ? "source" : "friendly"
        self.showResetLabels = showResetLabels
        self.showSonnetMetric = showSonnetMetric
        self.showErrorDetails = showErrorDetails
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            refreshIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 900,
            resetLabelStyle: (try container.decodeIfPresent(String.self, forKey: .resetLabelStyle) ?? "friendly").lowercased(),
            showResetLabels: try container.decodeIfPresent(Bool.self, forKey: .showResetLabels) ?? true,
            showSonnetMetric: try container.decodeIfPresent(Bool.self, forKey: .showSonnetMetric) ?? true,
            showErrorDetails: try container.decodeIfPresent(Bool.self, forKey: .showErrorDetails) ?? true
        )
    }

    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds = "refresh_interval_seconds"
        case resetLabelStyle = "reset_label_style"
        case showResetLabels = "show_reset_labels"
        case showSonnetMetric = "show_sonnet_metric"
        case showErrorDetails = "show_error_details"
    }
}

private let defaultAppConfig = AppConfig()

private struct UsageCache: Decodable {
    let writtenAt: String?
    let providers: [String: ProviderState]

    enum CodingKeys: String, CodingKey {
        case writtenAt = "written_at"
        case providers
    }
}

private struct ProviderState: Decodable {
    let enabled: Bool?
    let status: String?
    let stale: Bool?
    let blocker: BlockerState?
    let summary: SummaryState?
    let metrics: [String: MetricState]?
    let error: ProviderError?
}

private struct BlockerState: Decodable {
    let code: String?
    let message: String?
}

private struct SummaryState: Decodable {
    let primaryLeft: Int?
    let secondaryLeft: Int?

    enum CodingKeys: String, CodingKey {
        case primaryLeft = "primary_left"
        case secondaryLeft = "secondary_left"
    }
}

private struct MetricState: Decodable {
    let left: Int?
    let resetAtLabel: String?
    let resetAtSourceLabel: String?

    enum CodingKeys: String, CodingKey {
        case left
        case resetAtLabel = "reset_at_label"
        case resetAtSourceLabel = "reset_at_source_label"
    }
}

private struct ProviderError: Decodable {
    let code: String?
    let message: String?
}

private enum ProviderName: String, CaseIterable {
    case codex
    case claude

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var shortTitle: String {
        switch self {
        case .codex: return "Cdx"
        case .claude: return "Cl"
        }
    }
}

private func ensureRuntimeDirs() {
    try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
}

private func logLine(_ message: String) {
    ensureRuntimeDirs()
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: appLogURL.path),
           let handle = try? FileHandle(forWritingTo: appLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: appLogURL)
        }
    }
}

private func fileModificationDate(_ url: URL) -> Date? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return nil
    }
    return attributes[.modificationDate] as? Date
}

private func defaultConfigContents() -> String {
    return """
    {
      "enabled_providers": ["claude", "codex"],
      "refresh_interval_seconds": 900,
      "stale_after_seconds": 1800,
      "stale_after_failures": 2,
      "debug_captures": true,
      "reset_label_style": "friendly",
      "show_reset_labels": true,
      "show_sonnet_metric": true,
      "show_error_details": true
    }
    """
}

private func ensureConfigFile() {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
    ensureRuntimeDirs()
    try? defaultConfigContents().write(to: configURL, atomically: true, encoding: .utf8)
}

private func readAppConfig() -> AppConfig {
    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
        return defaultAppConfig
    }
    return config
}

private func decodeCache() -> UsageCache? {
    guard let data = try? Data(contentsOf: cacheURL) else {
        return nil
    }
    return try? JSONDecoder().decode(UsageCache.self, from: data)
}

private func pct(_ value: Int?) -> String {
    value.map(String.init) ?? "?"
}

private func providerSummary(_ provider: ProviderState?) -> String {
    if provider?.status == "unavailable" {
        return "--"
    }
    let summary = provider?.summary
    let primary = summary?.primaryLeft
    let secondary = summary?.secondaryLeft
    if primary == nil && secondary == nil {
        return "--"
    }
    return "\(pct(primary))/\(pct(secondary))"
}

private func shouldShowMetric(_ key: String, config: AppConfig) -> Bool {
    if key == "sonnet" {
        return config.showSonnetMetric
    }
    return true
}

private func selectedResetLabel(for metric: MetricState, config: AppConfig) -> String? {
    if config.resetLabelStyle == "source" {
        return metric.resetAtSourceLabel ?? metric.resetAtLabel
    }
    return metric.resetAtLabel ?? metric.resetAtSourceLabel
}

private func hasBlocker(_ provider: ProviderState?) -> Bool {
    guard let code = provider?.blocker?.code else { return false }
    return !code.isEmpty
}

private func isUnavailable(_ provider: ProviderState?) -> Bool {
    provider?.status == "unavailable"
}

private func unavailableHeading(provider: ProviderName, error: ProviderError?) -> String {
    switch error?.code {
    case "command_not_found":
        return "\(provider.title) not installed"
    default:
        return "\(provider.title) unavailable"
    }
}

private func shouldShowRepairAction(provider: ProviderName, providerState: ProviderState?) -> Bool {
    guard provider == .codex else { return false }
    guard let code = providerState?.error?.code else { return false }
    return ["startup_failed", "command_not_found"].contains(code)
}

private func blockerHeading(provider: ProviderName, blocker: BlockerState?) -> String {
    switch blocker?.code {
    case "trust_required":
        return "\(provider.title) setup required"
    case "update_required":
        return "\(provider.title) needs attention"
    case "selection_required":
        return "\(provider.title) needs confirmation"
    case "unknown_prompt":
        return "\(provider.title) needs manual attention"
    default:
        return "\(provider.title) needs attention"
    }
}

private func blockerActionLabel(provider: ProviderName, blocker: BlockerState?) -> String {
    switch blocker?.code {
    case "trust_required":
        return "Continue \(provider.title) setup"
    case "update_required":
        return "Continue \(provider.title)"
    case "selection_required":
        return "Confirm \(provider.title)"
    default:
        return "Open \(provider.title) diagnostics"
    }
}

private func allBlockersLabel(_ providers: [ProviderState]) -> String {
    let blockerCodes = Set(providers.compactMap { $0.blocker?.code })
    if blockerCodes == ["trust_required"] {
        return "Continue setup"
    }
    return "Continue all"
}

private func shouldShowContinueAction(for provider: ProviderState?) -> Bool {
    guard let code = provider?.blocker?.code else { return false }
    return ["trust_required", "update_required", "selection_required"].contains(code)
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var cachePollTimer: Timer?
    private var collectorProcess: Process?
    private var cache: UsageCache?
    private var appConfig = defaultAppConfig
    private var lastCacheMTime: Date?
    private var lastConfigMTime: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count > 1 {
            logLine("[app] duplicate launch suppressed")
            NSApp.terminate(nil)
            return
        }
        ensureRuntimeDirs()
        ensureConfigFile()
        statusItem.button?.title = "AI --"
        loadConfig(force: true)
        loadCache(force: true)
        rebuildMenu()
        scheduleCachePollTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.runCollector(arguments: [], reason: "startup")
        }
        logLine("[app] launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        cachePollTimer?.invalidate()
        logLine("[app] terminated")
    }

    func menuWillOpen(_ menu: NSMenu) {
        loadConfig(force: true)
        loadCache(force: true)
        rebuildMenu()
    }

    @discardableResult
    private func loadConfig(force: Bool) -> Bool {
        let currentMTime = fileModificationDate(configURL)
        if !force, currentMTime == lastConfigMTime {
            return false
        }
        lastConfigMTime = currentMTime
        let previousInterval = appConfig.refreshIntervalSeconds
        appConfig = readAppConfig()
        if force || refreshTimer == nil || previousInterval != appConfig.refreshIntervalSeconds {
            scheduleRefreshTimer()
        }
        return true
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(appConfig.refreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runCollector(arguments: [], reason: "scheduled_refresh")
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func scheduleCachePollTimer() {
        cachePollTimer?.invalidate()
        cachePollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let configChanged = self.loadConfig(force: false)
                let cacheChanged = self.loadCache(force: false)
                if configChanged || cacheChanged {
                    self.rebuildMenu()
                }
            }
        }
        if let cachePollTimer {
            RunLoop.main.add(cachePollTimer, forMode: .common)
        }
    }

    @discardableResult
    private func loadCache(force: Bool) -> Bool {
        let currentMTime = fileModificationDate(cacheURL)
        if !force, currentMTime == lastCacheMTime {
            return false
        }
        lastCacheMTime = currentMTime
        cache = decodeCache()
        statusItem.button?.title = renderSummary()
        return true
    }

    private func renderSummary() -> String {
        guard let cache else { return "AI --" }
        var parts: [String] = []
        var needsAttention = false

        for providerName in ProviderName.allCases {
            guard let provider = cache.providers[providerName.rawValue], provider.enabled == true else { continue }
            parts.append("\(providerName.shortTitle) \(providerSummary(provider))")
            needsAttention = needsAttention || hasBlocker(provider) || ["error", "blocked", "unavailable"].contains(provider.status) || provider.stale == true
        }

        let summary = parts.isEmpty ? "AI --" : parts.joined(separator: " · ")
        return needsAttention ? "! \(summary)" : summary
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let summaryItem = NSMenuItem(title: renderSummary(), action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        if collectorProcess != nil {
            let runningItem = NSMenuItem(title: "Refreshing…", action: nil, keyEquivalent: "")
            runningItem.isEnabled = false
            menu.addItem(runningItem)
        }

        menu.addItem(.separator())

        if let cache {
            let enabledProviders = ProviderName.allCases.compactMap { providerName in
                cache.providers[providerName.rawValue]?.enabled == true ? cache.providers[providerName.rawValue] : nil
            }
            if enabledProviders.contains(where: hasBlocker) {
                let allItem = NSMenuItem(title: allBlockersLabel(enabledProviders), action: #selector(continueAll), keyEquivalent: "")
                allItem.target = self
                allItem.isEnabled = collectorProcess == nil
                menu.addItem(allItem)
                menu.addItem(.separator())
            }
        }

        for providerName in ProviderName.allCases {
            guard let provider = cache?.providers[providerName.rawValue], provider.enabled == true else { continue }
            appendProviderSection(into: menu, providerName: providerName, provider: provider)
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = collectorProcess == nil
        menu.addItem(refreshItem)

        let openSettingsItem = NSMenuItem(title: "Open settings", action: #selector(openSettings), keyEquivalent: "")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        let openLogsItem = NSMenuItem(title: "Open logs", action: #selector(openLogs), keyEquivalent: "")
        openLogsItem.target = self
        menu.addItem(openLogsItem)

        let openDataItem = NSMenuItem(title: "Open app data", action: #selector(openAppData), keyEquivalent: "")
        openDataItem.target = self
        menu.addItem(openDataItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func appendProviderSection(into menu: NSMenu, providerName: ProviderName, provider: ProviderState) {
        let titleItem = NSMenuItem(title: providerName.title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        if isUnavailable(provider) {
            let unavailableItem = NSMenuItem(title: unavailableHeading(provider: providerName, error: provider.error), action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            menu.addItem(unavailableItem)
            if appConfig.showErrorDetails, let message = provider.error?.message, !message.isEmpty {
                let detailItem = NSMenuItem(title: "  \(message)", action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                menu.addItem(detailItem)
            }
            if shouldShowRepairAction(provider: providerName, providerState: provider) {
                let actionItem = NSMenuItem(title: "Repair \(providerName.title) install", action: #selector(repairProvider(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = providerName.rawValue
                actionItem.isEnabled = collectorProcess == nil
                menu.addItem(actionItem)
            }
        } else if hasBlocker(provider) {
            let blockerItem = NSMenuItem(title: blockerHeading(provider: providerName, blocker: provider.blocker), action: nil, keyEquivalent: "")
            blockerItem.isEnabled = false
            menu.addItem(blockerItem)
            if let message = provider.blocker?.message, !message.isEmpty {
                let detailItem = NSMenuItem(title: "  \(message)", action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                menu.addItem(detailItem)
            }
            if shouldShowContinueAction(for: provider) {
                let actionItem = NSMenuItem(title: blockerActionLabel(provider: providerName, blocker: provider.blocker), action: #selector(continueProvider(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = providerName.rawValue
                actionItem.isEnabled = collectorProcess == nil
                menu.addItem(actionItem)
            }
        }

        for (key, label) in [("five_hour", "5h"), ("weekly", "week"), ("sonnet", "sonnet")] {
            guard shouldShowMetric(key, config: appConfig) else { continue }
            guard let metric = provider.metrics?[key] else { continue }
            let valueItem = NSMenuItem(title: "\(label): \(pct(metric.left))% left", action: nil, keyEquivalent: "")
            valueItem.isEnabled = false
            menu.addItem(valueItem)

            if appConfig.showResetLabels {
                let resetLabel = selectedResetLabel(for: metric, config: appConfig) ?? "n/a"
                let resetItem = NSMenuItem(title: "  reset: \(resetLabel)", action: nil, keyEquivalent: "")
                resetItem.isEnabled = false
                menu.addItem(resetItem)
            }
        }

        if provider.stale == true {
            let staleItem = NSMenuItem(title: "  note: stale", action: nil, keyEquivalent: "")
            staleItem.isEnabled = false
            menu.addItem(staleItem)
        }

        if appConfig.showErrorDetails, let errorMessage = provider.error?.message, !errorMessage.isEmpty {
            let errorItem = NSMenuItem(title: "  error: \(errorMessage)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
    }

    private func runCollector(arguments: [String], reason: String) {
        guard collectorProcess == nil else { return }
        ensureRuntimeDirs()

        guard FileManager.default.fileExists(atPath: collectorURL.path) else {
            logLine("[app] collector missing path=\(collectorURL.path)")
            return
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", collectorURL.path] + arguments
        process.currentDirectoryURL = appSupportURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        do {
            try process.run()
            collectorProcess = process
            rebuildMenu()
            logLine("[app] collector start reason=\(reason) args=\((["python3", collectorURL.path] + arguments).joined(separator: " "))")
        } catch {
            logLine("[app] collector failed_to_start reason=\(reason) error=\(error)")
            return
        }

        process.terminationHandler = { [weak self] proc in
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                self?.collectorProcess = nil
                self?.loadCache(force: true)
                self?.rebuildMenu()
                logLine("[app] collector end status=\(proc.terminationStatus) stdout=\(stdout) stderr=\(stderr)")
            }
        }
    }

    @objc private func refreshNow() {
        runCollector(arguments: [], reason: "manual_refresh")
    }

    @objc private func continueAll() {
        runCollector(arguments: ["resolve", "--yes"], reason: "continue_all")
    }

    @objc private func continueProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        runCollector(arguments: ["resolve", "--providers", provider, "--yes"], reason: "continue_\(provider)")
    }

    @objc private func repairProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        runCollector(arguments: ["repair", "--providers", provider], reason: "repair_\(provider)")
    }

    @objc private func openSettings() {
        ensureConfigFile()
        NSWorkspace.shared.open(configURL)
    }

    @objc private func openLogs() {
        ensureRuntimeDirs()
        NSWorkspace.shared.activateFileViewerSelecting([logsURL])
    }

    @objc private func openAppData() {
        ensureRuntimeDirs()
        NSWorkspace.shared.activateFileViewerSelecting([appSupportURL])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
private struct AIUsageMenuBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppController.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

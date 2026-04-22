import AppKit
import Foundation

private let appID = "AIUsageMenuBar"
private let bundleIdentifier = "local.ai-usage-menubar"
private let homeDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
private let appSupportURL = homeDirectoryURL
    .appendingPathComponent("Library/Application Support/\(appID)", isDirectory: true)
private let cacheURL = appSupportURL.appendingPathComponent("usage.json")
private let configURL = appSupportURL.appendingPathComponent("config.json")
private let logsURL = appSupportURL.appendingPathComponent("logs", isDirectory: true)
private let appLogURL = logsURL.appendingPathComponent("app.log")
private let runtimeURL = appSupportURL.appendingPathComponent("runtime", isDirectory: true)
private let collectorURL = appSupportURL.appendingPathComponent("runtime/ai_usage_collector.py")
private let launchAgentsURL = homeDirectoryURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
private let launchAgentLabel = "local.ai-usage-menubar-app"
private let launchAgentURL = launchAgentsURL.appendingPathComponent("\(launchAgentLabel).plist")
private let oldLaunchAgentURL = launchAgentsURL.appendingPathComponent("local.ai-usage-refresh.plist")
private let oldXbarPluginURL = homeDirectoryURL.appendingPathComponent("Library/Application Support/xbar/plugins/ai_usage.5m.py")

private struct AppConfig: Codable {
    let enabledProviders: [String]
    let refreshIntervalSeconds: Int
    let staleAfterSeconds: Int
    let staleAfterFailures: Int
    let debugCaptures: Bool
    let resetLabelStyle: String
    let showResetLabels: Bool
    let showSonnetMetric: Bool
    let showErrorDetails: Bool

    private static let defaultProviders = ["claude", "codex"]

    private static func normalizeEnabledProviders(_ providers: [String]) -> [String] {
        let allowed = Set(ProviderName.allCases.map(\.rawValue))
        var seen = Set<String>()
        var normalized: [String] = []
        for provider in providers.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) where allowed.contains(provider) {
            if seen.insert(provider).inserted {
                normalized.append(provider)
            }
        }
        return normalized.isEmpty ? defaultProviders : normalized
    }

    init(
        enabledProviders: [String] = Self.defaultProviders,
        refreshIntervalSeconds: Int = 900,
        staleAfterSeconds: Int = 1800,
        staleAfterFailures: Int = 2,
        debugCaptures: Bool = true,
        resetLabelStyle: String = "friendly",
        showResetLabels: Bool = true,
        showSonnetMetric: Bool = true,
        showErrorDetails: Bool = true
    ) {
        self.enabledProviders = Self.normalizeEnabledProviders(enabledProviders)
        self.refreshIntervalSeconds = max(60, refreshIntervalSeconds)
        self.staleAfterSeconds = max(60, staleAfterSeconds)
        self.staleAfterFailures = max(1, staleAfterFailures)
        self.debugCaptures = debugCaptures
        self.resetLabelStyle = resetLabelStyle == "source" ? "source" : "friendly"
        self.showResetLabels = showResetLabels
        self.showSonnetMetric = showSonnetMetric
        self.showErrorDetails = showErrorDetails
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabledProviders: try container.decodeIfPresent([String].self, forKey: .enabledProviders) ?? Self.defaultProviders,
            refreshIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 900,
            staleAfterSeconds: try container.decodeIfPresent(Int.self, forKey: .staleAfterSeconds) ?? 1800,
            staleAfterFailures: try container.decodeIfPresent(Int.self, forKey: .staleAfterFailures) ?? 2,
            debugCaptures: try container.decodeIfPresent(Bool.self, forKey: .debugCaptures) ?? true,
            resetLabelStyle: (try container.decodeIfPresent(String.self, forKey: .resetLabelStyle) ?? "friendly").lowercased(),
            showResetLabels: try container.decodeIfPresent(Bool.self, forKey: .showResetLabels) ?? true,
            showSonnetMetric: try container.decodeIfPresent(Bool.self, forKey: .showSonnetMetric) ?? true,
            showErrorDetails: try container.decodeIfPresent(Bool.self, forKey: .showErrorDetails) ?? true
        )
    }

    enum CodingKeys: String, CodingKey {
        case enabledProviders = "enabled_providers"
        case refreshIntervalSeconds = "refresh_interval_seconds"
        case staleAfterSeconds = "stale_after_seconds"
        case staleAfterFailures = "stale_after_failures"
        case debugCaptures = "debug_captures"
        case resetLabelStyle = "reset_label_style"
        case showResetLabels = "show_reset_labels"
        case showSonnetMetric = "show_sonnet_metric"
        case showErrorDetails = "show_error_details"
    }
}

private let defaultAppConfig = AppConfig()

private func makeConfigJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

private func appConfigContents(_ config: AppConfig) -> String {
    let encoder = makeConfigJSONEncoder()
    guard let data = try? encoder.encode(config),
          var text = String(data: data, encoding: .utf8) else {
        return "{}\n"
    }
    if !text.hasSuffix("\n") {
        text.append("\n")
    }
    return text
}

private func writeAppConfig(_ config: AppConfig) throws {
    ensureRuntimeDirs()
    try appConfigContents(config).write(to: configURL, atomically: true, encoding: .utf8)
}

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
    try? FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
}

private func ensureLaunchAgentsDir() {
    try? FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
}

private func launchAgentContents(executablePath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>\(launchAgentLabel)</string>
        <key>ProgramArguments</key>
        <array>
          <string>\(executablePath)</string>
        </array>
        <key>WorkingDirectory</key>
        <string>\(appSupportURL.path)</string>
        <key>RunAtLoad</key>
        <true/>
        <key>StandardOutPath</key>
        <string>\(logsURL.appendingPathComponent("launchd.out.log").path)</string>
        <key>StandardErrorPath</key>
        <string>\(logsURL.appendingPathComponent("launchd.err.log").path)</string>
        <key>EnvironmentVariables</key>
        <dict>
          <key>PATH</key>
          <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        </dict>
      </dict>
    </plist>
    """
}

private func ensureBundledCollector() {
    ensureRuntimeDirs()
    guard let bundledCollectorURL = Bundle.main.url(forResource: "ai_usage_collector", withExtension: "py") else {
        logLine("[app] bundled collector missing")
        return
    }

    do {
        let bundledData = try Data(contentsOf: bundledCollectorURL)
        if let existingData = try? Data(contentsOf: collectorURL), existingData == bundledData {
            return
        }
        try bundledData.write(to: collectorURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: collectorURL.path)
        logLine("[app] bundled collector provisioned")
    } catch {
        logLine("[app] bundled collector provision_failed error=\(error)")
    }
}

private func ensureLaunchAgentFile() {
    ensureRuntimeDirs()
    ensureLaunchAgentsDir()
    try? FileManager.default.removeItem(at: oldLaunchAgentURL)
    try? FileManager.default.removeItem(at: oldXbarPluginURL)

    guard let executablePath = Bundle.main.executableURL?.path else {
        logLine("[app] launchagent missing executable path")
        return
    }

    let contents = launchAgentContents(executablePath: executablePath)
    let existingContents = try? String(contentsOf: launchAgentURL, encoding: .utf8)
    guard existingContents != contents else { return }

    do {
        try contents.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        logLine("[app] launchagent updated path=\(launchAgentURL.path)")
    } catch {
        logLine("[app] launchagent update_failed error=\(error)")
    }
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

private func makeUpdateTimeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
}

private func makeUpdateDateTimeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("MMM d h:mm a")
    return formatter
}

private func makeUpdateTooltipFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}

private func cacheWrittenAtDate(_ cache: UsageCache?) -> Date? {
    guard let writtenAt = cache?.writtenAt else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: writtenAt)
}

private func updateAgeText(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
        return "just now"
    }
    if seconds < 3600 {
        return "\(seconds / 60)m ago"
    }
    if seconds < 86_400 {
        return "\(seconds / 3600)h ago"
    }
    return "\(seconds / 86_400)d ago"
}

private func updateMenuLabel(_ cache: UsageCache?) -> String {
    guard let date = cacheWrittenAtDate(cache) else { return "Updated: never" }
    let absolute = Calendar.current.isDateInToday(date)
        ? makeUpdateTimeFormatter().string(from: date)
        : makeUpdateDateTimeFormatter().string(from: date)
    return "Updated: \(absolute) · \(updateAgeText(since: date))"
}

private func updateTooltip(_ cache: UsageCache?) -> String {
    guard let date = cacheWrittenAtDate(cache) else { return "Last updated: never" }
    return "Last updated: \(makeUpdateTooltipFormatter().string(from: date))"
}

private func defaultConfigContents() -> String {
    appConfigContents(defaultAppConfig)
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
private final class SettingsWindowController: NSWindowController {
    var onSave: ((AppConfig) -> Void)?

    private let claudeCheckbox = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    private let codexCheckbox = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let refreshIntervalField = NSTextField(string: "")
    private let staleAfterSecondsField = NSTextField(string: "")
    private let staleAfterFailuresField = NSTextField(string: "")
    private let resetLabelStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let debugCapturesCheckbox = NSButton(checkboxWithTitle: "Save debug captures", target: nil, action: nil)
    private let showResetLabelsCheckbox = NSButton(checkboxWithTitle: "Show reset labels", target: nil, action: nil)
    private let showSonnetMetricCheckbox = NSButton(checkboxWithTitle: "Show Claude Sonnet metric", target: nil, action: nil)
    private let showErrorDetailsCheckbox = NSButton(checkboxWithTitle: "Show error details", target: nil, action: nil)

    init(config: AppConfig) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        shouldCascadeWindows = true
        window.title = "AI Usage Settings"
        window.isReleasedWhenClosed = false
        window.center()
        buildInterface()
        apply(config: config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(config: AppConfig) {
        claudeCheckbox.state = config.enabledProviders.contains("claude") ? .on : .off
        codexCheckbox.state = config.enabledProviders.contains("codex") ? .on : .off
        refreshIntervalField.stringValue = String(config.refreshIntervalSeconds)
        staleAfterSecondsField.stringValue = String(config.staleAfterSeconds)
        staleAfterFailuresField.stringValue = String(config.staleAfterFailures)
        resetLabelStylePopup.selectItem(withTag: config.resetLabelStyle == "source" ? 1 : 0)
        debugCapturesCheckbox.state = config.debugCaptures ? .on : .off
        showResetLabelsCheckbox.state = config.showResetLabels ? .on : .off
        showSonnetMetricCheckbox.state = config.showSonnetMetric ? .on : .off
        showErrorDetailsCheckbox.state = config.showErrorDetails ? .on : .off
    }

    private func buildInterface() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = contentView

        configureControls()

        let providersStack = NSStackView(views: [claudeCheckbox, codexCheckbox])
        providersStack.orientation = .horizontal
        providersStack.spacing = 16
        providersStack.alignment = .centerY

        let generalGrid = NSGridView(views: [
            [makeFieldLabel("Refresh interval (sec)"), refreshIntervalField],
            [makeFieldLabel("Stale after (sec)"), staleAfterSecondsField],
            [makeFieldLabel("Stale after failures"), staleAfterFailuresField],
            [makeFieldLabel("Reset label style"), resetLabelStylePopup],
        ])
        generalGrid.rowSpacing = 10
        generalGrid.columnSpacing = 12
        generalGrid.column(at: 0).xPlacement = .trailing
        generalGrid.column(at: 1).xPlacement = .fill

        let displayStack = NSStackView(views: [
            debugCapturesCheckbox,
            showResetLabelsCheckbox,
            showSonnetMetricCheckbox,
            showErrorDetailsCheckbox,
        ])
        displayStack.orientation = .vertical
        displayStack.spacing = 8
        displayStack.alignment = .leading

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let buttonsStack = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 10
        buttonsStack.alignment = .centerY

        let rootStack = NSStackView(views: [
            makeSectionLabel("Providers"),
            providersStack,
            makeSectionLabel("Collection"),
            generalGrid,
            makeSectionLabel("Display"),
            displayStack,
            buttonsStack,
        ])
        rootStack.orientation = .vertical
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            refreshIntervalField.widthAnchor.constraint(equalToConstant: 120),
            staleAfterSecondsField.widthAnchor.constraint(equalToConstant: 120),
            staleAfterFailuresField.widthAnchor.constraint(equalToConstant: 120),
            resetLabelStylePopup.widthAnchor.constraint(equalToConstant: 160),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    private func configureControls() {
        [refreshIntervalField, staleAfterSecondsField, staleAfterFailuresField].forEach { field in
            field.alignment = .right
            field.controlSize = .regular
        }

        resetLabelStylePopup.removeAllItems()
        resetLabelStylePopup.addItem(withTitle: "Friendly")
        resetLabelStylePopup.lastItem?.tag = 0
        resetLabelStylePopup.addItem(withTitle: "Source")
        resetLabelStylePopup.lastItem?.tag = 1
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func makeFieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func parsePositiveInt(from field: NSTextField, name: String, minimum: Int) -> Int? {
        let rawValue = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(rawValue) else {
            presentValidationError("\(name) must be a whole number.")
            return nil
        }
        guard value >= minimum else {
            presentValidationError("\(name) must be at least \(minimum).")
            return nil
        }
        return value
    }

    private func presentValidationError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid Settings"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    @objc private func saveSettings() {
        var enabledProviders: [String] = []
        if claudeCheckbox.state == .on {
            enabledProviders.append("claude")
        }
        if codexCheckbox.state == .on {
            enabledProviders.append("codex")
        }
        guard !enabledProviders.isEmpty else {
            presentValidationError("Enable at least one provider.")
            return
        }

        guard let refreshIntervalSeconds = parsePositiveInt(from: refreshIntervalField, name: "Refresh interval", minimum: 60),
              let staleAfterSeconds = parsePositiveInt(from: staleAfterSecondsField, name: "Stale after", minimum: 60),
              let staleAfterFailures = parsePositiveInt(from: staleAfterFailuresField, name: "Stale after failures", minimum: 1) else {
            return
        }

        let config = AppConfig(
            enabledProviders: enabledProviders,
            refreshIntervalSeconds: refreshIntervalSeconds,
            staleAfterSeconds: staleAfterSeconds,
            staleAfterFailures: staleAfterFailures,
            debugCaptures: debugCapturesCheckbox.state == .on,
            resetLabelStyle: resetLabelStylePopup.selectedTag() == 1 ? "source" : "friendly",
            showResetLabels: showResetLabelsCheckbox.state == .on,
            showSonnetMetric: showSonnetMetricCheckbox.state == .on,
            showErrorDetails: showErrorDetailsCheckbox.state == .on
        )

        onSave?(config)
        window?.performClose(nil)
    }

    @objc private func cancelSettings() {
        window?.performClose(nil)
    }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var cachePollTimer: Timer?
    private var collectorProcess: Process?
    private var settingsWindowController: SettingsWindowController?
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
        ensureBundledCollector()
        ensureConfigFile()
        ensureLaunchAgentFile()
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
        statusItem.button?.title = renderSummary()
        return true
    }

    private func configuredProviderNames() -> [ProviderName] {
        let enabled = Set(appConfig.enabledProviders)
        return ProviderName.allCases.filter { enabled.contains($0.rawValue) }
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
        statusItem.button?.toolTip = updateTooltip(cache)
        return true
    }

    private func renderSummary() -> String {
        guard let cache else { return "AI --" }
        var parts: [String] = []
        var needsAttention = false

        for providerName in configuredProviderNames() {
            guard let provider = cache.providers[providerName.rawValue] else { continue }
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

        let updatedItem = NSMenuItem(title: updateMenuLabel(cache), action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        if collectorProcess != nil {
            let runningItem = NSMenuItem(title: "Refreshing…", action: nil, keyEquivalent: "")
            runningItem.isEnabled = false
            menu.addItem(runningItem)
        }

        menu.addItem(.separator())

        if let cache {
            let enabledProviders = configuredProviderNames().compactMap { providerName in
                cache.providers[providerName.rawValue]
            }
            if enabledProviders.contains(where: hasBlocker) {
                let allItem = NSMenuItem(title: allBlockersLabel(enabledProviders), action: #selector(continueAll), keyEquivalent: "")
                allItem.target = self
                allItem.isEnabled = collectorProcess == nil
                menu.addItem(allItem)
                menu.addItem(.separator())
            }
        }

        for providerName in configuredProviderNames() {
            guard let provider = cache?.providers[providerName.rawValue] else { continue }
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
        let providers: [String] = configuredProviderNames().compactMap { providerName -> String? in
            guard let provider = cache?.providers[providerName.rawValue], hasBlocker(provider) else {
                return nil
            }
            return providerName.rawValue
        }
        guard !providers.isEmpty else { return }
        runCollector(arguments: ["resolve", "--providers", providers.joined(separator: ","), "--yes"], reason: "continue_all")
    }

    @objc private func continueProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        runCollector(arguments: ["resolve", "--providers", provider, "--yes"], reason: "continue_\(provider)")
    }

    @objc private func repairProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        runCollector(arguments: ["repair", "--providers", provider], reason: "repair_\(provider)")
    }

    private func saveSettings(_ config: AppConfig) {
        do {
            try writeAppConfig(config)
            _ = loadConfig(force: true)
            rebuildMenu()
            logLine("[app] config saved")
            if collectorProcess == nil {
                runCollector(arguments: [], reason: "settings_saved")
            }
        } catch {
            logLine("[app] config save_failed error=\(error)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Could not Save Settings"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        ensureConfigFile()
        loadConfig(force: true)

        if settingsWindowController == nil {
            let controller = SettingsWindowController(config: appConfig)
            controller.onSave = { [weak self] config in
                self?.saveSettings(config)
            }
            settingsWindowController = controller
        }

        settingsWindowController?.apply(config: appConfig)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

import AppKit
import Combine
import Foundation
import SwiftUI

struct QuotaWindow {
    let remaining: Double?
    let used: Double?
    let resetAt: TimeInterval?
    let windowMinutes: Double?
}

struct QuotaSnapshot {
    let planType: String?
    let primary: QuotaWindow
    let secondary: QuotaWindow
    let sampledAt: Date
    let sourceName: String

    static func newest(_ live: QuotaSnapshot?, _ cached: QuotaSnapshot?) -> QuotaSnapshot? {
        if let live, let cached { return cached.sampledAt > live.sampledAt ? cached : live }
        return live ?? cached
    }
}

enum QuotaParser {
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    static func value(_ dictionary: [String: Any]?, names: [String]) -> Any? {
        guard let dictionary else { return nil }
        for name in names {
            if let value = dictionary[name], !(value is NSNull) {
                return value
            }
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func accountSnapshot(from response: [String: Any], sampledAt: Date) -> QuotaSnapshot? {
        // Prefer the Codex bucket when the server returns multiple metered limits.
        let buckets = dictionary(response["rateLimitsByLimitId"])
        let limits = buckets?["codex"] ?? response["rateLimits"] ?? response["rate_limits"]
        return snapshot(from: limits, sampledAt: sampledAt, sourceName: "app-server")
    }

    static func snapshot(from limitsValue: Any?, sampledAt: Date, sourceName: String) -> QuotaSnapshot? {
        guard let limits = dictionary(limitsValue) else { return nil }
        let primary = window(from: value(limits, names: ["primary"]))
        let secondary = window(from: value(limits, names: ["secondary"]))
        guard primary.used != nil || secondary.used != nil else { return nil }

        let plan = value(limits, names: ["plan_type", "planType"]) as? String
        return QuotaSnapshot(
            planType: plan,
            primary: primary,
            secondary: secondary,
            sampledAt: sampledAt,
            sourceName: sourceName
        )
    }

    private static func window(from rawValue: Any?) -> QuotaWindow {
        let object = dictionary(rawValue)
        let used = number(QuotaParser.value(object, names: ["used_percent", "usedPercent"]))
        let remaining = used.map { min(100, max(0, 100 - $0)) }
        let resetAt = number(QuotaParser.value(object, names: ["resets_at", "resetsAt"]))
        let windowMinutes = number(QuotaParser.value(object, names: ["window_minutes", "windowDurationMins", "window_duration_mins"]))
        return QuotaWindow(remaining: remaining, used: used, resetAt: resetAt, windowMinutes: windowMinutes)
    }
}

enum SnapshotLoader {
    static func load(root: URL) -> QuotaSnapshot? {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let urls = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { return nil }
            return url
        }
        .sorted { modificationDate($0) > modificationDate($1) }
        .prefix(24)

        var newest: QuotaSnapshot?
        for url in urls {
            for line in readTailLines(url: url) where line.contains("\"rate_limits\"") || line.contains("\"rateLimits\"") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] ?? payload["rateLimits"] else { continue }

                let sampledAt = parseDate(event["timestamp"]) ?? modificationDate(url)
                if let snapshot = QuotaParser.snapshot(from: limits, sampledAt: sampledAt, sourceName: url.lastPathComponent) {
                    if newest == nil || snapshot.sampledAt > newest!.sampledAt {
                        newest = snapshot
                    }
                }
            }
        }
        return newest
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }()
    }

    private static func readTailLines(url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let tailSize: UInt64 = 512 * 1024
        let start = end > tailSize ? end - tailSize : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).reversed().map(String.init)
    }
}

final class CodexAppServerClient {
    var onSnapshot: ((QuotaSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.local.chatgpt.quotapet.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var initializeID: Int?
    private var pendingReadID: Int?
    private var pendingSince: Date?
    private var ready = false
    private var lastError = ""

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if let pendingSince = self.pendingSince, Date().timeIntervalSince(pendingSince) > 20 {
                self.emitError("本地额度接口响应超时")
                self.closeOnQueue()
            }
            if self.process?.isRunning != true {
                self.startOnQueue()
            } else if self.ready && self.pendingReadID == nil {
                self.requestReadOnQueue()
            }
        }
    }

    func stop() {
        queue.sync { closeOnQueue() }
    }

    var currentError: String {
        queue.sync { lastError }
    }

    private func executableURL() -> URL? {
        let fileManager = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["CODEX_BIN"], fileManager.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }

        // Finder-launched apps do not inherit the shell's Codex PATH alias.
        let appRoots = ["/Applications", NSHomeDirectory() + "/Applications"]
        let relativePaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex"
        ]
        for root in appRoots {
            for app in ["ChatGPT.app", "Codex.app"] {
                for relativePath in relativePaths {
                    let candidate = "\(root)/\(app)/\(relativePath)"
                    if fileManager.isExecutableFile(atPath: candidate) {
                        return URL(fileURLWithPath: candidate)
                    }
                }
            }
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private func startOnQueue() {
        closeOnQueue()
        guard let executable = executableURL() else {
            emitError("未找到 codex，请确认 ChatGPT/Codex 已安装")
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errorOutput = errorPipe.fileHandleForReading
        self.buffer.removeAll(keepingCapacity: true)
        self.ready = false
        self.initializeID = nil
        self.pendingReadID = nil
        self.pendingSince = nil

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            self?.queue.async { [weak self] in
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.lastError = message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.process?.isRunning != true else { return }
                self.emitErrorIfNeeded()
            }
        }

        do {
            try process.run()
        } catch {
            emitError("无法启动本地额度接口：\(error.localizedDescription)")
            closeOnQueue()
            return
        }

        nextID = 1
        initializeID = nextID
        pendingSince = Date()
        sendOnQueue([
            "jsonrpc": "2.0",
            "id": nextID,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "chatgpt-quota-pet-mac", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ])
    }

    private func sendOnQueue(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        try? input.write(contentsOf: Data(line.utf8))
    }

    private func requestReadOnQueue() {
        guard ready, pendingReadID == nil else { return }
        nextID += 1
        pendingReadID = nextID
        pendingSince = Date()
        sendOnQueue(["jsonrpc": "2.0", "id": nextID, "method": "account/rateLimits/read", "params": NSNull()])
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String, method == "account/rateLimits/updated" {
            let params = message["params"] as? [String: Any]
            if let params, let snapshot = QuotaParser.accountSnapshot(from: params, sampledAt: Date()) {
                onSnapshot?(snapshot)
                lastError = ""
            }
            return
        }

        guard let messageID = QuotaParser.number(message["id"]).map({ Int($0) }) else { return }
        if messageID == initializeID {
            initializeID = nil
            pendingSince = nil
            if let error = message["error"] as? [String: Any], let text = error["message"] as? String {
                emitError(text)
                closeOnQueue()
                return
            }
            ready = true
            sendOnQueue(["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: Any]])
            requestReadOnQueue()
            return
        }

        guard messageID == pendingReadID else { return }
        pendingReadID = nil
        pendingSince = nil
        if let result = message["result"] as? [String: Any],
           let snapshot = QuotaParser.accountSnapshot(from: result, sampledAt: Date()) {
            onSnapshot?(snapshot)
            lastError = ""
        } else if let error = message["error"] as? [String: Any], let text = error["message"] as? String {
            emitError(text)
        } else {
            emitError("额度接口没有返回数据")
        }
    }

    private func emitError(_ message: String) {
        lastError = message
        onError?(message)
    }

    private func emitErrorIfNeeded() {
        emitError(lastError.isEmpty ? "本地额度接口已退出" : lastError)
    }

    private func closeOnQueue() {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        input?.closeFile()
        output?.closeFile()
        errorOutput?.closeFile()
        process?.terminationHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        ready = false
        initializeID = nil
        pendingReadID = nil
        pendingSince = nil
    }
}

enum QuotaFormatter {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func caption(minutes: Double?, fallback: String) -> String {
        guard let minutes else { return fallback }
        let rounded = Int(minutes.rounded())
        guard rounded > 0 else { return fallback }
        if rounded % 1440 == 0 { return "\(rounded / 1440) 天窗口剩余" }
        if rounded % 60 == 0 { return "\(rounded / 60) 小时窗口剩余" }
        return "\(rounded) 分钟窗口剩余"
    }

    static func resetDate(_ timestamp: TimeInterval?, timeZone: TimeZone = .current) -> String {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return "重置于 " + formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func reset(_ timestamp: TimeInterval?, now: Date = Date()) -> String {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return "重置时间未知" }
        let seconds = timestamp - now.timeIntervalSince1970
        if seconds <= 0 { return "窗口已到点，等待刷新" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "约 \(minutes) 分钟后重置" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let rest = minutes % 60
        if days > 0 { return "约 \(days) 天 \(hours) 小时 \(rest) 分钟后重置" }
        return "约 \(hours) 小时 \(rest) 分钟后重置"
    }

    static func consumptionRate(
        window: QuotaWindow,
        fallbackWindowMinutes: Double,
        displayPeriodMinutes: Double,
        unit: String,
        now: Date = Date()
    ) -> String {
        guard let resetAt = window.resetAt, let usedValue = window.used else { return "等待数据" }

        let totalMinutes = max(1, window.windowMinutes ?? fallbackWindowMinutes)
        let remainingMinutes = min(
            totalMinutes,
            max(0, (resetAt - now.timeIntervalSince1970) / 60)
        )
        let elapsedMinutes = totalMinutes - remainingMinutes
        guard elapsedMinutes >= 1 else { return "等待数据" }

        let used = min(100, max(0, usedValue))
        let rate = used / elapsedMinutes * displayPeriodMinutes
        guard rate.isFinite else { return "等待数据" }
        return String(format: "%.1f%%/%@", rate, unit)
    }

    static func shortError(_ error: String) -> String {
        if error.isEmpty { return "" }
        if error.range(of: "codex", options: [.caseInsensitive]) != nil &&
            (error.contains("not found") || error.contains("找不到") || error.contains("executable")) {
            return "未找到 codex"
        }
        let oneLine = error.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(22))
    }
}

@MainActor
final class QuotaModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var fallbackSnapshot: QuotaSnapshot?
    @Published private(set) var connectionError = ""
    @Published private(set) var footer = "正在连接本地额度接口…"

    var currentSnapshot: QuotaSnapshot? {
        QuotaSnapshot.newest(snapshot, fallbackSnapshot)
    }

    var isLive: Bool {
        currentSnapshot?.sourceName == "app-server" && connectionError.isEmpty
    }

    private let client = CodexAppServerClient()
    private let codexHome: URL
    private let refreshSeconds: TimeInterval
    private let fallbackScanInterval: TimeInterval = 30
    private let fallbackScanQueue = DispatchQueue(
        label: "com.local.chatgpt.quotapet.snapshot-loader",
        qos: .utility
    )
    private var timer: Timer?
    private var lastFallbackScanAt: Date?
    private var fallbackScanInFlight = false
    private var forceFallbackScanPending = false
    private var scanGeneration = 0
    private var isStopped = false

    init(refreshSeconds: TimeInterval = 1) {
        self.refreshSeconds = refreshSeconds
        codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
                self?.connectionError = ""
                if let self, let display = self.currentSnapshot { self.updateFooter(display) }
            }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.connectionError = message
                if let display = self.currentSnapshot { self.updateFooter(display) }
                else { self.footer = QuotaFormatter.shortError(message) }
            }
        }
    }

    func start() {
        isStopped = false
        scanGeneration &+= 1
        fallbackScanInFlight = false
        forceFallbackScanPending = false
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(forceFallbackScan: false) }
        }
    }

    func refresh() {
        refresh(forceFallbackScan: true)
    }

    private func refresh(forceFallbackScan: Bool) {
        guard !isStopped else { return }
        requestFallbackSnapshotScan(force: forceFallbackScan)
        client.refresh()
        updateFooterForCurrentSnapshot()
    }

    private func requestFallbackSnapshotScan(force: Bool) {
        guard !isStopped else { return }

        if fallbackScanInFlight {
            if force { forceFallbackScanPending = true }
            return
        }

        let now = Date()
        if !force,
           let lastFallbackScanAt,
           now.timeIntervalSince(lastFallbackScanAt) < fallbackScanInterval {
            return
        }

        fallbackScanInFlight = true
        lastFallbackScanAt = now
        let generation = scanGeneration
        let root = codexHome
        fallbackScanQueue.async { [weak self] in
            let loadedSnapshot = SnapshotLoader.load(root: root)
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isStopped,
                      self.scanGeneration == generation else { return }

                self.fallbackScanInFlight = false
                self.fallbackSnapshot = loadedSnapshot
                self.updateFooterForCurrentSnapshot()

                if self.forceFallbackScanPending {
                    self.forceFallbackScanPending = false
                    self.requestFallbackSnapshotScan(force: true)
                }
            }
        }
    }

    private func updateFooterForCurrentSnapshot() {
        if let display = currentSnapshot {
            updateFooter(display)
        } else if connectionError.isEmpty {
            footer = "正在连接本地额度接口…"
        }
    }

    func stop() {
        isStopped = true
        scanGeneration &+= 1
        timer?.invalidate()
        timer = nil
        fallbackScanInFlight = false
        forceFallbackScanPending = false
        client.stop()
    }

    private func updateFooter(_ value: QuotaSnapshot) {
        let ageMinutes = max(0, Date().timeIntervalSince(value.sampledAt) / 60)
        let formatter = DateFormatter()
        formatter.dateFormat = ageMinutes >= 10 ? "MM-dd HH:mm" : "HH:mm"
        let source = isLive ? "" : "快照 "
        let stale = ageMinutes >= 10 ? " · 可能过期" : ""
        let shortError = QuotaFormatter.shortError(connectionError)
        let error = shortError.isEmpty ? "" : " · \(shortError)"
        footer = "\(source)\(formatter.string(from: value.sampledAt))\(stale)\(error)"
    }
}

private enum QuotaDesign {
    static let width: CGFloat = 416
    static let height: CGFloat = 400
    static let inset: CGFloat = 20
    static let cardRadius: CGFloat = 16

    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.78, green: 0.64, blue: 1.00)
            : Color(red: 0.47, green: 0.21, blue: 0.91)
    }

    static func quotaGradient(for colorScheme: ColorScheme) -> LinearGradient {
        let colors = colorScheme == .dark
            ? [Color(red: 0.52, green: 0.61, blue: 1.00), Color(red: 0.76, green: 0.48, blue: 1.00), Color(red: 0.63, green: 0.34, blue: 1.00)]
            : [Color(red: 0.40, green: 0.47, blue: 0.96), Color(red: 0.65, green: 0.40, blue: 0.96), Color(red: 0.50, green: 0.19, blue: 0.91)]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static func warningGradient(for colorScheme: ColorScheme) -> LinearGradient {
        let colors = colorScheme == .dark
            ? [Color(red: 1.00, green: 0.70, blue: 0.35), Color(red: 1.00, green: 0.52, blue: 0.25), Color(red: 0.98, green: 0.40, blue: 0.24)]
            : [Color(red: 1.00, green: 0.65, blue: 0.30), Color(red: 0.97, green: 0.49, blue: 0.22), Color(red: 0.86, green: 0.34, blue: 0.18)]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

private struct LiquidGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else if #available(macOS 26.0, *) {
            // NSPopover supplies the system Liquid Glass surface on modern macOS.
            // Keep the hosting view transparent so the system can tune the glass
            // for light/dark appearance and the current desktop behind the popover.
            Color.clear
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var cursorID = UUID()
    @State private var cursorBounds = CGSize(width: 30, height: 30)

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(QuotaDesign.accent(for: colorScheme))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    @ViewBuilder
    private var styledButton: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            button
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            button.buttonStyle(.bordered)
        }
    }

    var body: some View {
        styledButton
            .contentShape(Circle())
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ToolbarButtonBoundsKey.self, value: geometry.size)
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(ToolbarButtonBoundsKey.self) { cursorBounds = $0 }
            // Track the visible button after styling, including its glass surface.
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let circle = Circle().path(in: CGRect(origin: .zero, size: cursorBounds))
                    if circle.contains(location) {
                        ToolbarCursor.activate(for: cursorID)
                    } else {
                        ToolbarCursor.restore(for: cursorID)
                    }
                case .ended:
                    ToolbarCursor.restore(for: cursorID)
                }
            }
            .onDisappear { ToolbarCursor.restore(for: cursorID) }
    }
}

private struct ToolbarButtonBoundsKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

@MainActor
private enum ToolbarCursor {
    private static var owner: UUID?

    static func activate(for id: UUID) {
        owner = id
        NSCursor.pointingHand.set()
    }

    static func restore(for id: UUID? = nil) {
        guard let owner, id == nil || owner == id else { return }
        self.owner = nil
        if NSCursor.current == NSCursor.pointingHand {
            NSCursor.arrow.set()
        }
    }
}

private struct QuotaToolbar: View {
    let refresh: () -> Void
    let dismiss: () -> Void
    private var controls: some View {
        HStack(spacing: 8) {
            GlassIconButton(systemName: "arrow.clockwise", accessibilityLabel: "刷新额度", action: refresh)
                .keyboardShortcut("r", modifiers: .command)
            GlassIconButton(systemName: "xmark", accessibilityLabel: "关闭详情", action: dismiss)
        }
    }
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { controls }
        } else { controls }
    }
}

private struct QuotaParticleField: View {
    let reduceMotion: Bool

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            Canvas { context, size in
                Self.draw(in: &context, size: size, time: 0, reduceMotion: true)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 3.0)) { timeline in
                Canvas { context, size in
                    Self.draw(
                        in: &context,
                        size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        reduceMotion: false
                    )
                }
            }
        }
    }

    private static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        reduceMotion: Bool
    ) {
        // About 4.5 stable, deterministically placed particles per 100 pt.
        let count = max(0, Int(size.width / 22))
        guard count > 0 else { return }

        for index in 0..<count {
            let seed = Double(index + 1) * 12.9898
            let baseX = 0.06 + unit(seed) * 0.88
            let y = (0.20 + unit(seed + 31.4) * 0.60) * size.height
            let diameter = 0.7 + unit(seed + 91.7)
            let drift = reduceMotion ? 0 : sin(time * 0.34 + seed) * 0.48
            let opacity = reduceMotion
                ? 0.48
                : 0.26 + 0.48 * (0.5 + 0.5 * sin(time * 0.53 + seed * 0.7))
            let rect = CGRect(
                x: baseX * size.width + drift - diameter / 2,
                y: y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(.white.opacity(opacity))
            )
        }
    }

    private static func unit(_ value: Double) -> Double {
        let value = sin(value * 127.1) * 43_758.5453
        return value - floor(value)
    }
}

private struct QuotaProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let progress: CGFloat
    let remaining: Double?
    let isWarning: Bool

    private var fill: LinearGradient {
        isWarning
            ? QuotaDesign.warningGradient(for: colorScheme)
            : QuotaDesign.quotaGradient(for: colorScheme)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(colorScheme == .dark ? 0.16 : 0.09))
                if remaining != nil {
                    Capsule()
                        .fill(fill)
                        .frame(width: geometry.size.width * progress)
                        .overlay {
                            if !isWarning, let remaining, remaining > 0 {
                                QuotaParticleField(reduceMotion: reduceMotion)
                                    .clipShape(Capsule())
                                    .accessibilityHidden(true)
                            }
                        }
                        .clipShape(Capsule())
                }
            }
        }
        .frame(height: 11)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: progress)
        .accessibilityHidden(true)
    }
}

private struct QuotaCard: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let window: QuotaWindow
    let fallbackWindowMinutes: Double
    let ratePeriodMinutes: Double
    let rateUnit: String
    let warningThreshold: Double
    let now: Date

    private var normalizedRemaining: Double? {
        guard let remaining = window.remaining, remaining.isFinite else { return nil }
        return min(100, max(0, remaining))
    }

    private var isWarning: Bool {
        guard let remaining = normalizedRemaining else { return false }
        return remaining < warningThreshold
    }

    private var tint: Color {
        guard normalizedRemaining != nil else { return .secondary }
        return isWarning
            ? Color(nsColor: .systemOrange)
            : QuotaDesign.accent(for: colorScheme)
    }

    private var progress: CGFloat {
        CGFloat((normalizedRemaining ?? 0) / 100)
    }

    private var surfaceOpacity: Double {
        if contrast == .increased {
            return colorScheme == .light ? 0.26 : 0.20
        }
        return colorScheme == .light ? 0.16 : 0.10
    }

    private var consumptionRate: String {
        QuotaFormatter.consumptionRate(
            window: window,
            fallbackWindowMinutes: fallbackWindowMinutes,
            displayPeriodMinutes: ratePeriodMinutes,
            unit: rateUnit,
            now: now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(QuotaFormatter.caption(minutes: window.windowMinutes, fallback: title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(QuotaFormatter.percent(window.remaining))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .accessibilityLabel("剩余 \(QuotaFormatter.percent(window.remaining))")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(QuotaFormatter.reset(window.resetAt, now: now))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    if let resetAt = window.resetAt, resetAt.isFinite, resetAt > 0 {
                        Text(QuotaFormatter.resetDate(resetAt))
                            .help("按本机时区显示接口返回的重置时间")
                    }
                    Spacer(minLength: 0)
                    Text("消耗速率 \(consumptionRate)")
                        .monospacedDigit()
                        .help("按当前窗口已用额度与已过时长折算")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            QuotaProgress(progress: progress, remaining: normalizedRemaining, isWarning: isWarning)
                .opacity(normalizedRemaining == nil ? 0 : 1)
        }
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: QuotaDesign.cardRadius, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else if #available(macOS 26.0, *) {
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(surfaceOpacity))
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: QuotaDesign.cardRadius, style: .continuous)
                .strokeBorder(
                    contrast == .increased
                        ? Color.primary.opacity(0.32)
                        : QuotaDesign.accent(for: colorScheme).opacity(colorScheme == .dark ? 0.22 : 0.14),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuotaView: View {
    @ObservedObject var model: QuotaModel
    let refresh: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let placeholder = QuotaWindow(remaining: nil, used: nil, resetAt: nil, windowMinutes: nil)

    private var currentSnapshot: QuotaSnapshot? {
        model.currentSnapshot
    }

    private var planTitle: String {
        let plan = currentSnapshot?.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plan, !plan.isEmpty {
            return "\(plan.capitalized) 订阅"
        }
        return "订阅"
    }

    private var statusLabel: String {
        if !model.connectionError.isEmpty { return "连接失败" }
        guard currentSnapshot != nil else { return "连接中" }
        return model.isLive ? "实时" : "快照"
    }

    private var statusTint: Color {
        if !model.connectionError.isEmpty { return Color(nsColor: .systemRed) }
        guard currentSnapshot != nil else { return .secondary }
        return model.isLive
            ? QuotaDesign.accent(for: colorScheme)
            : Color(nsColor: .systemOrange)
    }

    private func quotaCards(now: Date) -> some View {
        VStack(spacing: 10) {
            quotaCard(
                title: "5 小时窗口剩余",
                window: currentSnapshot?.primary ?? placeholder,
                fallbackWindowMinutes: 5 * 60,
                ratePeriodMinutes: 60, rateUnit: "h",
                warningThreshold: 20, now: now
            )
            quotaCard(
                title: "7 天窗口剩余",
                window: currentSnapshot?.secondary ?? placeholder,
                fallbackWindowMinutes: 7 * 24 * 60,
                ratePeriodMinutes: 24 * 60, rateUnit: "天",
                warningThreshold: 10, now: now
            )
        }
    }

    private func quotaCard(
        title: String,
        window: QuotaWindow,
        fallbackWindowMinutes: Double,
        ratePeriodMinutes: Double,
        rateUnit: String,
        warningThreshold: Double,
        now: Date
    ) -> some View {
        QuotaCard(
            title: title,
            window: window,
            fallbackWindowMinutes: fallbackWindowMinutes,
            ratePeriodMinutes: ratePeriodMinutes,
            rateUnit: rateUnit,
            warningThreshold: warningThreshold,
            now: now
        )
    }

    var body: some View {
        ZStack {
            LiquidGlassBackground()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(planTitle)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(QuotaDesign.accent(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(planTitle)
                    Spacer()
                    QuotaToolbar(refresh: refresh, dismiss: dismiss)
                }
                .frame(minHeight: 44)
                .padding(.bottom, 16)

                // Clock changes must invalidate rows even when quota values stay the same.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    quotaCards(now: context.date)
                }
                Spacer(minLength: 10)
                Divider().padding(.bottom, 10)
                HStack(alignment: .center, spacing: 10) {
                    Text(model.footer)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(model.footer)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Circle().fill(statusTint).frame(width: 5, height: 5)
                        Text(statusLabel)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusTint.opacity(0.1), in: Capsule())
                    .fixedSize()
                    .accessibilityLabel("数据状态：\(statusLabel)")
                }
            }
            .padding(QuotaDesign.inset)
        }
        .frame(width: QuotaDesign.width, height: QuotaDesign.height)
    }
}

enum QuotaStatusIcon {
    private static let iconSize = NSSize(width: 20, height: 20)

    static func image(primary: Double?, secondary: Double?) -> NSImage {
        let primaryFraction = normalizedFraction(primary)
        let secondaryFraction = normalizedFraction(secondary)
        let image = NSImage(size: iconSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.setShouldAntialias(true)

            drawScallopedOutline()
            drawPrompt()
            drawMeter(atY: 12.7, fraction: primaryFraction)
            drawMeter(atY: 7.3, fraction: secondaryFraction)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func normalizedFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value)) / 100
    }

    private static func drawScallopedOutline() {
        let samples = 96
        let center = NSPoint(x: 10, y: 10)
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineJoinStyle = .round

        for index in 0...samples {
            let angle = Double(index) / Double(samples) * 2 * Double.pi
            let radius = 7.55 + 0.35 * cos(angle * 6)
            let point = NSPoint(
                x: center.x + CGFloat(cos(angle) * radius),
                y: center.y + CGFloat(sin(angle) * radius)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        NSColor.black.setStroke()
        path.stroke()
    }

    private static func drawPrompt() {
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 5.1, y: 7.35))
        path.line(to: NSPoint(x: 7.2, y: 10))
        path.line(to: NSPoint(x: 5.1, y: 12.65))
        NSColor.black.setStroke()
        path.stroke()
    }

    private static func drawMeter(atY y: CGFloat, fraction: Double?) {
        let startX: CGFloat = 9.15
        let endX: CGFloat = 14.3
        let track = NSBezierPath()
        track.lineWidth = 1.05
        track.lineCapStyle = .round

        if fraction == nil {
            // Dashed neutral rails distinguish unknown from a known zero quota.
            var x = startX
            while x < endX {
                track.move(to: NSPoint(x: x, y: y))
                track.line(to: NSPoint(x: min(x + 0.9, endX), y: y))
                x += 1.7
            }
            NSColor.black.withAlphaComponent(0.38).setStroke()
        } else {
            track.move(to: NSPoint(x: startX, y: y))
            track.line(to: NSPoint(x: endX, y: y))
            NSColor.black.withAlphaComponent(0.20).setStroke()
        }
        track.stroke()

        guard let fraction, fraction > 0 else { return }
        let fill = NSBezierPath()
        fill.lineWidth = 1.4
        fill.lineCapStyle = .round
        fill.move(to: NSPoint(x: startX, y: y))
        fill.line(to: NSPoint(x: startX + (endX - startX) * CGFloat(fraction), y: y))
        NSColor.black.setStroke()
        fill.stroke()
    }
}

final class QuotaStatusView: NSView {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    private let iconLeading: CGFloat = 1
    private let iconSize: CGFloat = 20
    private let labelLeading: CGFloat = 22
    private let labelTrailing: CGFloat = 1
    private let textFieldCellInset: CGFloat = 4
    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "5h —")
    private let secondaryLabel = NSTextField(labelWithString: "7d —")
    private var isPressed = false
    private var hasRenderedIcon = false
    private var lastIconPrimary: Double?
    private var lastIconSecondary: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Codex 剩余额度")

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        addSubview(iconView)

        for label in [primaryLabel, secondaryLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.cell?.wraps = false
            label.backgroundColor = .clear
            label.isBordered = false
            label.isEditable = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: iconLeading, y: 1, width: iconSize, height: iconSize)
        let labelWidth = max(20, bounds.width - labelLeading - labelTrailing)
        primaryLabel.frame = NSRect(x: labelLeading, y: 1, width: labelWidth, height: 10)
        secondaryLabel.frame = NSRect(x: labelLeading, y: 11, width: labelWidth, height: 10)
    }

    var preferredWidth: CGFloat {
        let labelWidth = [
            primaryLabel.stringValue,
            secondaryLabel.stringValue,
            "5h 100%",
            "7d 100%"
        ].map(measuredLabelWidth).max() ?? 0
        return ceil(labelLeading + labelWidth + labelTrailing)
    }

    private func measuredLabelWidth(_ string: String) -> CGFloat {
        let font = primaryLabel.font ?? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let textWidth = (string as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth + textFieldCellInset)
    }

    func update(primary: Double?, secondary: Double?, sourceName: String?) {
        primaryLabel.stringValue = "5h \(QuotaFormatter.percent(primary))"
        secondaryLabel.stringValue = "7d \(QuotaFormatter.percent(secondary))"
        let iconPrimary = normalizedIconValue(primary)
        let iconSecondary = normalizedIconValue(secondary)
        if !hasRenderedIcon || lastIconPrimary != iconPrimary || lastIconSecondary != iconSecondary {
            iconView.image = QuotaStatusIcon.image(primary: iconPrimary, secondary: iconSecondary)
            lastIconPrimary = iconPrimary
            lastIconSecondary = iconSecondary
            hasRenderedIcon = true
        }
        let source = sourceName == "app-server" ? "实时" : (sourceName == nil ? "等待数据" : "快照")
        toolTip = "Codex 额度 · \(source)\n5 小时剩余 \(QuotaFormatter.percent(primary))\n7 天剩余 \(QuotaFormatter.percent(secondary))"
        setAccessibilityValue("5 小时剩余 \(QuotaFormatter.percent(primary))，7 天剩余 \(QuotaFormatter.percent(secondary))，\(source)")
        needsLayout = true
        needsDisplay = true
    }

    private func normalizedIconValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            NSColor.selectedMenuItemColor.withAlphaComponent(0.25).setFill()
            dirtyRect.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldOpen = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if shouldOpen { onLeftClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = QuotaModel()
    private var popover: NSPopover!
    private var statusItem: NSStatusItem!
    private var statusView: QuotaStatusView!
    private let statusMenu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPopover()
        buildStatusItem()
        model.$snapshot
            .combineLatest(model.$fallbackSnapshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.start()
        updateStatusItem()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
        installPopoverDismissMonitors()
        if CommandLine.arguments.contains("--show-details") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPopover() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePopoverDismissMonitors()
        model.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if popover?.isShown == true {
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func buildPopover() {
        popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: QuotaDesign.width, height: QuotaDesign.height)

        let hostingController = NSHostingController(rootView: QuotaView(
            model: model,
            refresh: { [weak self] in self?.model.refresh() },
            dismiss: { [weak self] in self?.closePopover() }
        ))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hostingController
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initialStatusView = QuotaStatusView(frame: NSRect(x: 0, y: 0, width: 0, height: 22))
        let initialWidth = initialStatusView.preferredWidth
        initialStatusView.setFrameSize(NSSize(width: initialWidth, height: 22))
        statusView = initialStatusView
        statusView.onLeftClick = { [weak self] in self?.togglePopover() }
        statusView.onRightClick = { [weak self] in self?.showStatusMenu() }
        statusItem.view = statusView
        statusItem.length = initialWidth

        let show = NSMenuItem(title: "显示额度", action: #selector(showPopover), keyEquivalent: "")
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshQuota), keyEquivalent: "")
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        [show, refresh, NSMenuItem.separator(), quit].forEach { item in
            item.target = self
            statusMenu.addItem(item)
        }
    }

    private func showStatusMenu() {
        closePopover()
        statusMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func installPopoverDismissMonitors() {
        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            self?.dismissPopoverForLocalClick(event)
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissPopoverForGlobalClick()
            }
        }
    }

    private func removePopoverDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func dismissPopoverForLocalClick(_ event: NSEvent) {
        guard popover.isShown else { return }
        // Use the dispatched event, which may be older than the current pointer position.
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return
        }
        let clickLocation = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation

        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(clickLocation) {
            return
        }

        if isClickInStatusItem(clickLocation) {
            return
        }

        closePopover()
    }

    private func dismissPopoverForGlobalClick() {
        guard popover.isShown else { return }
        if isClickInStatusItem(NSEvent.mouseLocation) { return }
        closePopover()
    }

    private func isClickInStatusItem(_ clickLocation: NSPoint) -> Bool {
        guard let statusWindow = statusView.window else { return false }
        let statusRect = statusView.convert(statusView.bounds, to: nil)
        return statusWindow.convertToScreen(statusRect).contains(clickLocation)
    }

    private func updateStatusItem() {
        guard let statusView else { return }
        let value = model.currentSnapshot
        if let value {
            statusView.update(primary: value.primary.remaining, secondary: value.secondary.remaining, sourceName: value.sourceName)
        } else {
            statusView.update(primary: nil, secondary: nil, sourceName: nil)
        }

        let width = statusView.preferredWidth
        if statusItem.length != width {
            statusView.setFrameSize(NSSize(width: width, height: statusView.frame.height))
            statusItem.length = width
            statusView.needsLayout = true
        }
    }

    @objc private func showPopover() {
        guard let statusView else { return }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !popover.isShown {
            popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        ToolbarCursor.restore()
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    @objc private func refreshQuota() {
        model.refresh()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

func runProbe() -> Int32 {
    let client = CodexAppServerClient()
    let semaphore = DispatchSemaphore(value: 0)
    var snapshot: QuotaSnapshot?
    client.onSnapshot = {
        snapshot = $0
        semaphore.signal()
    }
    client.refresh()
    _ = semaphore.wait(timeout: .now() + 8)

    if let snapshot {
        let result: [String: Any] = [
            "Status": "ok",
            "PlanType": snapshot.planType as Any,
            "FiveHourRemain": snapshot.primary.remaining as Any,
            "WeeklyRemain": snapshot.secondary.remaining as Any,
            "FiveHourResetsAt": snapshot.primary.resetAt as Any,
            "WeeklyResetsAt": snapshot.secondary.resetAt as Any,
            "WeeklyResetDate": QuotaFormatter.resetDate(snapshot.secondary.resetAt),
            "WeeklyResetDisplay": QuotaFormatter.reset(snapshot.secondary.resetAt),
            "SampledAt": ISO8601DateFormatter().string(from: snapshot.sampledAt),
            "SourceName": snapshot.sourceName
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        client.stop()
        return 0
    }

    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    if let fallback = SnapshotLoader.load(root: root) {
        let result: [String: Any] = [
            "Status": "ok",
            "PlanType": fallback.planType as Any,
            "FiveHourRemain": fallback.primary.remaining as Any,
            "WeeklyRemain": fallback.secondary.remaining as Any,
            "FiveHourResetsAt": fallback.primary.resetAt as Any,
            "WeeklyResetsAt": fallback.secondary.resetAt as Any,
            "WeeklyResetDate": QuotaFormatter.resetDate(fallback.secondary.resetAt),
            "WeeklyResetDisplay": QuotaFormatter.reset(fallback.secondary.resetAt),
            "SampledAt": ISO8601DateFormatter().string(from: fallback.sampledAt),
            "SourceName": fallback.sourceName
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        client.stop()
        return 0
    }

    let result = ["Status": "unavailable", "Message": client.currentError.isEmpty ? "没有找到可读取的 Codex 限额快照" : client.currentError]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    client.stop()
    return 1
}

@main
struct ChatGPTQuotaPetMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            Foundation.exit(runProbe())
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

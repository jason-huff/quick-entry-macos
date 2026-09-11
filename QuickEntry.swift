import AppKit
import Carbon.HIToolbox
import CryptoKit
import QuartzCore

private let hotKeyID = EventHotKeyID(signature: OSType(0x51454E54), id: 1) // QENT

private enum QuickEntryConfiguration {
    static let launchAgentLabel = "io.github.jasonhuff.quick-entry"
    static let todoCompanionBundleID = "io.github.jasonhuff.quick-entry.todos"
    static let defaultInboxDirectory = "QuickEntry"
    static let defaultInboxFileName = "todo-processing.md"
}
private let modeContentTransitionDuration: CFTimeInterval = 0.22
// NSStatusItem.squareLength is zero on recent macOS releases. Keep a concrete
// width so the menu bar allocates a visible hit target for the to-do icon.
private let todoStatusItemLength: CGFloat = 26

enum ModeTextRollDirection {
    case up
    case down

    // The helper field and the button title have opposite vertical layer
    // orientations, so they need inverse Core Animation subtypes to move in
    // the same visible direction.
    var fieldSubtype: CATransitionSubtype {
        self == .up ? .fromBottom : .fromTop
    }

    var buttonTitleSubtype: CATransitionSubtype {
        self == .up ? .fromTop : .fromBottom
    }
}

private func addModeTextRoll(
    to layer: CALayer,
    key: String,
    subtype: CATransitionSubtype = .fromBottom
) {
    let roll = CATransition()
    roll.type = .push
    roll.subtype = subtype
    roll.duration = modeContentTransitionDuration
    roll.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    layer.removeAnimation(forKey: key)
    layer.add(roll, forKey: key)
}

private func addModePlaceholderReveal(to layer: CALayer, direction: ModeTextRollDirection) {
    let fade = CATransition()
    fade.type = .fade
    fade.duration = 0.26
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    layer.removeAnimation(forKey: "quickEntryModePlaceholderFade")
    layer.add(fade, forKey: "quickEntryModePlaceholderFade")

    // Keep placeholder motion almost imperceptible: a one-and-a-half point
    // settle preserves the mode direction without making the editor move.
    let settle = CABasicAnimation(keyPath: "transform.translation.y")
    settle.fromValue = direction == .up ? 1.5 : -1.5
    settle.toValue = 0
    settle.duration = 0.26
    settle.timingFunction = fade.timingFunction
    layer.removeAnimation(forKey: "quickEntryModePlaceholderSettle")
    layer.add(settle, forKey: "quickEntryModePlaceholderSettle")
}

private func qColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255
    let g = CGFloat((hex >> 8) & 0xff) / 255
    let b = CGFloat(hex & 0xff) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

private func markdownLabel(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let pattern = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*", options: [])
    let nsText = text as NSString
    let matches = pattern?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
    var cursor = 0

    for match in matches {
        if match.range.location > cursor {
            let plain = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: color]))
        }
        let boldRange = match.range(at: 1)
        let bold = nsText.substring(with: boldRange)
        result.append(NSAttributedString(
            string: bold,
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: color,
            ]
        ))
        cursor = match.range.location + match.range.length
    }

    if cursor < nsText.length {
        let plain = nsText.substring(from: cursor)
        result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: color]))
    }

    if matches.isEmpty {
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
    return result
}

private struct TodoPresentation {
    let title: String
    let category: String?
}

private func todoPresentation(_ raw: String) -> TodoPresentation {
    let text = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    let patterns = [
        "^\\s*\\*\\*([^:]+):\\*\\*\\s*(.+)$",
        "^\\s*((?:Vault|Hiring|People|Grid|Hardware|Pulse|Activation|Design System|Case)[^:]*):\\s*(.+)$",
        "^\\s*((?:Weekly|Daily|Before|After|During|Next week|This week)[^:]*):\\s*(.+)$",
    ]

    for pattern in patterns {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges == 3
        else { continue }
        let source = text as NSString
        let category = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let action = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { continue }

        let timePrefixes = [("next week ", "Next week"), ("this week ", "This week"), ("today ", "Today"), ("tomorrow ", "Tomorrow")]
        let lowercaseAction = action.lowercased()
        if let prefix = timePrefixes.first(where: { lowercaseAction.hasPrefix($0.0) }) {
            let remainder = String(action.dropFirst(prefix.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { continue }
            let verbFirst = remainder.prefix(1).uppercased() + remainder.dropFirst()
            return TodoPresentation(title: verbFirst, category: "\(category) · \(prefix.1)")
        }

        let verbFirst = action.prefix(1).uppercased() + action.dropFirst()
        return TodoPresentation(title: verbFirst, category: category)
    }

    return TodoPresentation(title: text, category: nil)
}

private func firstURLAndTitle(_ raw: String) -> (title: String, url: URL?) {
    guard let expression = try? NSRegularExpression(pattern: #"https?://\S+"#),
          let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          let range = Range(match.range, in: raw)
    else {
        return (raw, nil)
    }

    let candidate = String(raw[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>.,;:"))
    let title = raw.replacingCharacters(in: range, with: "")
    return (title, URL(string: candidate))
}

private func conciseMetadata(_ detail: String, category: String?) -> String {
    let normalizedDetail = detail.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    let normalizedCategory = category?.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")

    func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        let lastSpace = prefix.lastIndex(of: " ") ?? prefix.endIndex
        return String(prefix[..<lastSpace]) + "…"
    }

    guard let normalizedCategory, !normalizedCategory.isEmpty else {
        return shortened(normalizedDetail, limit: 58)
    }
    let shortCategory = shortened(normalizedCategory, limit: 24)
    let availableDetail = max(18, 58 - shortCategory.count - 3)
    return "\(shortened(normalizedDetail, limit: availableDetail)) · \(shortCategory)"
}

enum TodoSource: String, Codable, CaseIterable {
    case owing
    case inbox

    var title: String {
        switch self {
        case .owing: return "Owing"
        case .inbox: return "Inbox"
        }
    }

}

struct TodoMenuEntry: Identifiable {
    let id: String
    let source: TodoSource
    let lineIndex: Int
    let timestamp: String?
    let text: String
    let isDone: Bool
}

struct HyperDTodoRecommendation: Decodable {
    let id: String
    let why: String
}

struct HyperDTodoCache: Decodable {
    let generatedAt: String
    let mode: String
    let summary: String
    let radarReport: String?
    let items: [HyperDTodoRecommendation]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case mode
        case summary
        case radarReport = "radar_report"
        case items
    }
}

struct HyperDTodoEntry {
    let todo: TodoMenuEntry
    let why: String
}

struct InboxReviewItem: Decodable {
    let id: String
    let classification: String
    let text: String
}

struct InboxReviewCache: Decodable {
    let generatedAt: String
    let mode: String
    let rawCount: Int
    let nonActionableCount: Int
    let items: [InboxReviewItem]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case mode
        case rawCount = "raw_count"
        case nonActionableCount = "non_actionable_count"
        case items
    }
}

struct TodoLogbookEntry: Codable, Identifiable {
    let id: String
    let completedAt: String
    let todoID: String
    let source: TodoSource
    let text: String
    let timestamp: String?
    var restoredAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case completedAt = "completed_at"
        case todoID = "todo_id"
        case source
        case text
        case timestamp
        case restoredAt = "restored_at"
    }
}

struct SessionCompletedTodo {
    let todo: TodoMenuEntry
    let entry: TodoLogbookEntry
    let detail: String
}

private extension Notification.Name {
    static let caseTodosChanged = Notification.Name("QuickEntryTodosChanged")
    static let caseHyperDTodosChanged = Notification.Name("QuickEntryTopTodosChanged")
    static let caseInboxReviewChanged = Notification.Name("QuickEntryInboxReviewChanged")
}

private enum AppLog {
    static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("QuickEntry.log")
    }()

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [pid:\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        AppLog.write("static main entered")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var panelController: QuickEntryPanelController?
    private var todoPanel: TodoMenuPanel?
    private var todoPopoverController: TodoPopoverController?
    private var todoEscapeMonitor: Any?
    private var todoOutsideMonitor: Any?
    private var todoSyncTimer: Timer?
    private var todoFingerprint = ""
    private var hyperDRefreshInFlight = false
    private var inboxReviewRefreshInFlight = false
    private var isDismissingTodoPanel = false

    private var isTodoCompanion: Bool {
        ProcessInfo.processInfo.arguments.contains("--todos-only") ||
            Bundle.main.bundleIdentifier == QuickEntryConfiguration.todoCompanionBundleID
    }

    private var embeddedTodoMenuEnabled: Bool {
        // The to-do companion is a separate app. Only enable the legacy,
        // embedded menu when the launch agent explicitly opts into it. A
        // foreground/Spotlight launch has no launch-agent environment, and
        // must never create a second to-do surface beside the companion.
        ProcessInfo.processInfo.environment["QUICK_ENTRY_TODOS"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching; launchedByLaunchAgent=\(launchedByLaunchAgent); XPC_SERVICE_NAME=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "nil")")
        NSApp.setActivationPolicy(.accessory)
        if isTodoCompanion {
            setupStatusItem()
            startTodoSync()
            AppLog.write("todo companion launch detected; staying in menu bar")
            return
        }

        setupAppleEventHandlers()
        if embeddedTodoMenuEnabled {
            setupStatusItem()
            startTodoSync()
        }
        registerHotKey()

        if !launchedByLaunchAgent {
            AppLog.write("foreground launch detected; opening panel")
            DispatchQueue.main.async { self.openQuickEntry() }
        } else {
            AppLog.write("launch agent launch detected; staying in menu bar")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.write("applicationShouldHandleReopen; hasVisibleWindows=\(flag)")
        if isTodoCompanion {
            toggleTodoPopover()
        } else {
            openQuickEntry()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("applicationWillTerminate")
        todoSyncTimer?.invalidate()
        closeTodoPopover()
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            AppLog.write("UnregisterEventHotKey status=\(status)")
        }
        if let eventHandlerRef {
            let status = RemoveEventHandler(eventHandlerRef)
            AppLog.write("RemoveEventHandler status=\(status)")
        }
    }

    private var launchedByLaunchAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == QuickEntryConfiguration.launchAgentLabel
    }

    private func setupAppleEventHandlers() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self, andSelector: #selector(handleAppleEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication))
        manager.setEventHandler(self, andSelector: #selector(handleAppleEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
        AppLog.write("registered Apple Event handlers for open/reopen")
    }

    @objc private func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        AppLog.write("received Apple Event id=\(event.eventID); opening panel")
        openQuickEntry()
    }

    private func setupStatusItem() {
        AppLog.write("setupStatusItem")
        let item = NSStatusBar.system.statusItem(withLength: todoStatusItemLength)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggleTodoPopover)
        statusItem = item
        updateStatusTitle()
        logStatusItem("created")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.logStatusItem("one second after creation")
        }

        NotificationCenter.default.addObserver(forName: .caseTodosChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncTodoState(force: true)
        }
        NotificationCenter.default.addObserver(forName: .caseHyperDTodosChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncTodoState(force: true)
        }
        NotificationCenter.default.addObserver(forName: .caseInboxReviewChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncTodoState(force: true)
        }
    }

    @objc private func toggleTodoPopover() {
        guard let button = statusItem?.button else { return }
        if let todoPanel, todoPanel.isVisible {
            closeTodoPopover()
            return
        }

        let controller = TodoPopoverController(
            onRevealSource: { [weak self] source in
                self?.closeTodoPopover()
                self?.revealTodoSource(source)
            },
            onToggle: { [weak self] todo in
                self?.toggleTodoFromPopover(todo)
            },
            onRestoreLogbook: { [weak self] entry in
                self?.restoreLogbookEntry(entry)
            },
            onRefreshHyperD: { [weak self] in
                self?.refreshHyperD(force: true)
            },
            onPreferredSizeChange: { [weak self] size in
                self?.resizeTodoPanel(to: size)
            }
        )
        _ = controller.view
        let size = controller.preferredContentSize
        let panel = TodoMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentViewController = controller
        let targetFrame = todoPanelFrame(for: button, size: size)
        panel.setFrame(targetFrame, display: false)
        panel.alphaValue = 0

        todoPanel = panel
        todoPopoverController = controller
        controller.prepareForPresentation()
        AppLog.write("showing borderless todo panel")
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        controller.animatePresentation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.08, 0.4, 1)
            panel.animator().alphaValue = 1
        }
        // Install outside-click handling after this status-item click has finished.
        // Installing it synchronously consumes the same click that opened the panel.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.todoPanel === panel, panel.isVisible else { return }
            self.installTodoDismissMonitors()
        }
    }

    private func todoPanelFrame(for button: NSStatusBarButton, size: NSSize) -> NSRect {
        let buttonRect = button.convert(button.bounds, to: nil)
        let anchor = button.window?.convertToScreen(buttonRect) ?? .zero
        let screenFrame = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let horizontalInset: CGFloat = 8
        let x = min(
            max(anchor.midX - size.width / 2, screenFrame.minX + horizontalInset),
            screenFrame.maxX - size.width - horizontalInset
        )
        let y = max(screenFrame.minY + horizontalInset, anchor.minY - size.height - 5)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func closeTodoPopover() {
        guard let panel = todoPanel else {
            removeTodoDismissMonitors()
            return
        }
        guard !isDismissingTodoPanel else { return }
        isDismissingTodoPanel = true
        removeTodoDismissMonitors()
        let controller = todoPopoverController
        controller?.animateDismissal()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            controller?.resetCardTransform()
            if self.todoPanel === panel {
                self.todoPanel = nil
                self.todoPopoverController = nil
            }
            self.isDismissingTodoPanel = false
        }
    }

    private func resizeTodoPanel(to size: NSSize) {
        guard let panel = todoPanel,
              let button = statusItem?.button,
              panel.isVisible,
              !isDismissingTodoPanel
        else { return }

        var targetFrame = todoPanelFrame(for: button, size: size)
        // The panel keeps a fixed width. Preserve its exact x-origin during
        // vertical resize so submenus never nudge left/right by a pixel.
        targetFrame.origin.x = panel.frame.origin.x
        guard abs(panel.frame.width - targetFrame.width) > 0.5 || abs(panel.frame.height - targetFrame.height) > 0.5 else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.9, 0.24, 1)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            self?.todoPopoverController?.refreshOverflowFades()
        }
    }

    private func installTodoDismissMonitors() {
        removeTodoDismissMonitors()
        todoEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.todoPanel, panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                self.closeTodoPopover()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown,
               !panel.frame.contains(NSEvent.mouseLocation),
               !(self.statusButtonScreenFrame()?.contains(NSEvent.mouseLocation) ?? false) {
                self.closeTodoPopover()
            }
            return event
        }
        todoOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if !(self.statusButtonScreenFrame()?.contains(NSEvent.mouseLocation) ?? false) {
                    self.closeTodoPopover()
                }
            }
        }
    }

    private func removeTodoDismissMonitors() {
        if let todoEscapeMonitor {
            NSEvent.removeMonitor(todoEscapeMonitor)
            self.todoEscapeMonitor = nil
        }
        if let todoOutsideMonitor {
            NSEvent.removeMonitor(todoOutsideMonitor)
            self.todoOutsideMonitor = nil
        }
    }

    private func logStatusItem(_ phase: String) {
        guard let item = statusItem else {
            AppLog.write("status item [\(phase)]: missing")
            return
        }
        guard let button = item.button else {
            AppLog.write("status item [\(phase)]: button missing; length=\(item.length)")
            return
        }
        AppLog.write(
            "status item [\(phase)]: length=\(item.length); hidden=\(button.isHidden); " +
            "frame=\(NSStringFromRect(button.frame)); window=\(String(describing: button.window)); " +
            "title=\(button.title.debugDescription); attributedTitle=\(button.attributedTitle.string.debugDescription); " +
            "image=\(String(describing: button.image)); imagePosition=\(button.imagePosition.rawValue)"
        )
    }

    private func updateStatusTitle() {
        let openCount = QuickEntryStore.openTodoCount()
        // Keep this deliberately simple. Use the system label color instead
        // of hard-coded black so the dot remains visible when macOS switches
        // the menu bar between light and dark appearances.
        let title = NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: -1,
            ]
        )

        statusItem?.button?.image = nil
        statusItem?.button?.imagePosition = .noImage
        statusItem?.button?.title = ""
        statusItem?.button?.attributedTitle = title
        statusItem?.button?.contentTintColor = nil
        statusItem?.button?.toolTip = "Quick Entry to-dos — \(openCount) open"
        statusItem?.button?.setAccessibilityLabel("Quick Entry to-dos, \(openCount) open")
        statusItem?.length = todoStatusItemLength
    }

    private func startTodoSync() {
        syncTodoState(force: true)
        refreshInboxReview(force: false)
        refreshHyperD(force: false)
        todoSyncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.syncTodoState()
            self.refreshInboxReview(force: false)
            self.refreshHyperD(force: false)
        }
        if let todoSyncTimer {
            RunLoop.main.add(todoSyncTimer, forMode: .common)
        }
    }

    private func syncTodoState(force: Bool = false) {
        let nextFingerprint = QuickEntryStore.todoStateFingerprint()
        guard force || nextFingerprint != todoFingerprint else { return }
        todoFingerprint = nextFingerprint
        updateStatusTitle()
        if todoPanel?.isVisible == true {
            todoPopoverController?.rebuild()
        }
    }

    private func refreshInboxReview(force: Bool) {
        guard !inboxReviewRefreshInFlight else { return }
        guard force || QuickEntryStore.inboxReviewNeedsRefresh() else { return }

        inboxReviewRefreshInFlight = true
        QuickEntryStore.refreshInboxReview { [weak self] success in
            guard let self else { return }
            self.inboxReviewRefreshInFlight = false
            if !success {
                AppLog.write("Inbox review fell back to raw captures")
            }
            self.syncTodoState(force: true)
            // The Top 3 should immediately stop considering interview notes
            // once the conservative inbox review is available.
            if success {
                self.refreshHyperD(force: true)
            }
        }
    }

    private func refreshHyperD(force: Bool) {
        guard !hyperDRefreshInFlight else { return }
        guard force || QuickEntryStore.hyperDNeedsRefresh() else { return }

        hyperDRefreshInFlight = true
        todoPopoverController?.setHyperDRefreshState(true)
        QuickEntryStore.refreshHyperDTodos { [weak self] success in
            guard let self else { return }
            self.hyperDRefreshInFlight = false
            self.todoPopoverController?.setHyperDRefreshState(false)
            if !success {
                AppLog.write("HyperD refresh fell back to local priorities")
            }
            self.syncTodoState(force: true)
        }
    }

    private func toggleTodoFromPopover(_ todo: TodoMenuEntry) {
        do {
            let entry = try QuickEntryStore.completeTodo(todo)
            AppLog.write("completed todo id=\(todo.id)")
            todoPopoverController?.recordCompletion(todo, entry: entry)
            syncTodoState(force: true)
        } catch {
            AppLog.write("failed completing todo id=\(todo.id): \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func restoreLogbookEntry(_ entry: TodoLogbookEntry) {
        do {
            try QuickEntryStore.restoreLogbookEntry(entry)
            AppLog.write("restored logbook entry id=\(entry.id)")
            todoPopoverController?.removeSessionCompletion(entry)
            syncTodoState(force: true)
        } catch {
            AppLog.write("failed restoring logbook entry id=\(entry.id): \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func registerHotKey() {
        let modifiers = UInt32(controlKey)
        let keyCode = UInt32(kVK_Space)
        let hotKeyStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        AppLog.write("RegisterEventHotKey key=Ctrl+Space status=\(hotKeyStatus); hotKeyRefPresent=\(hotKeyRef != nil)")

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            AppLog.write("hotkey event GetEventParameter status=\(status); pressedID=\(pressedID.id)")
            if status == noErr && pressedID.id == hotKeyID.id {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    AppLog.write("hotkey matched; opening panel")
                    delegate.openQuickEntry()
                }
            }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandlerRef)
        AppLog.write("InstallEventHandler status=\(handlerStatus); eventHandlerRefPresent=\(eventHandlerRef != nil)")
    }

    @objc private func openQuickEntry() {
        AppLog.write("openQuickEntry invoked; existingPanel=\(panelController != nil)")
        if panelController == nil {
            panelController = QuickEntryPanelController()
        }
        panelController?.show()
    }

    private func revealTodoSource(_ source: TodoSource) {
        let url = QuickEntryStore.url(for: source)
        AppLog.write("revealTodoSource source=\(source.rawValue) url=\(url.path)")
        QuickEntryStore.ensureTodoProcessingExists()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

}

private final class CASEMenuStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class TodoPopoverController: NSViewController {
    private enum Screen {
        case overview
        case source(TodoSource)
        case logbook
    }

    enum NavigationDirection {
        case forward
        case backward
    }

    private let onRevealSource: (TodoSource) -> Void
    private let onToggle: (TodoMenuEntry) -> Void
    private let onRestoreLogbook: (TodoLogbookEntry) -> Void
    private let onRefreshHyperD: () -> Void
    private let onPreferredSizeChange: (NSSize) -> Void
    private let card = NSView()
    private let headerContainer = NSView()
    private let headerHeight: CGFloat = 64
    private let scroll = NSScrollView()
    private let stack = CASEMenuStackView()
    private var topListFade: CASETextInputEdgeFade?
    private var bottomListFade: CASETextInputEdgeFade?
    private let listFadeHeight: CGFloat = 18
    private var screen: Screen = .overview
    private var isRefreshingHyperD = false
    private var hyperDRefreshStartedAt: Date?
    private var hyperDRefreshTimer: Timer?
    private weak var hyperDLoadingView: CASEMenuLoadingView?
    private var sessionCompleted: [SessionCompletedTodo] = []
    private var logbookVisibleCount = 20
    private var isLoadingMoreLogbook = false
    private var scrollBoundsObserver: NSObjectProtocol?
    private var headerConstraints: [NSLayoutConstraint] = []

    init(
        onRevealSource: @escaping (TodoSource) -> Void,
        onToggle: @escaping (TodoMenuEntry) -> Void,
        onRestoreLogbook: @escaping (TodoLogbookEntry) -> Void,
        onRefreshHyperD: @escaping () -> Void,
        onPreferredSizeChange: @escaping (NSSize) -> Void
    ) {
        self.onRevealSource = onRevealSource
        self.onToggle = onToggle
        self.onRestoreLogbook = onRestoreLogbook
        self.onRefreshHyperD = onRefreshHyperD
        self.onPreferredSizeChange = onPreferredSizeChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hyperDRefreshTimer?.invalidate()
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 376, height: 460))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        card.wantsLayer = true
        card.layer?.backgroundColor = qColor(0xfbfbfc).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = qColor(0x000000).cgColor
        card.layer?.shadowOpacity = 0.16
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = NSSize(width: 0, height: -4)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(headerContainer)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = stack
        let topListFade = CASETextInputEdgeFade(edge: .top, backgroundColor: qColor(0xfbfbfc))
        let bottomListFade = CASETextInputEdgeFade(edge: .bottom, backgroundColor: qColor(0xfbfbfc))
        scroll.contentView.addSubview(topListFade, positioned: .above, relativeTo: stack)
        scroll.contentView.addSubview(bottomListFade, positioned: .above, relativeTo: topListFade)
        self.topListFade = topListFade
        self.bottomListFade = bottomListFade
        card.addSubview(scroll)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateListFades()
            self?.loadMoreLogbookIfNeeded()
        }

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),

            headerContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: card.topAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: headerHeight),

            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        rebuild()
    }

    func setHyperDRefreshState(_ refreshing: Bool) {
        guard refreshing != isRefreshingHyperD else { return }
        isRefreshingHyperD = refreshing

        if refreshing {
            hyperDRefreshStartedAt = Date()
            rebuild()
            startHyperDRefreshStatusUpdates()
        } else {
            stopHyperDRefreshStatusUpdates()
            addHyperDRefreshCompletionTransition()
            rebuild()
        }
    }

    private func startHyperDRefreshStatusUpdates() {
        hyperDRefreshTimer?.invalidate()
        updateHyperDRefreshStatus()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateHyperDRefreshStatus()
        }
        hyperDRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHyperDRefreshStatusUpdates() {
        hyperDRefreshTimer?.invalidate()
        hyperDRefreshTimer = nil
        hyperDRefreshStartedAt = nil
        hyperDLoadingView = nil
    }

    private func updateHyperDRefreshStatus() {
        guard let startedAt = hyperDRefreshStartedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded(.down))
        let status: String
        if elapsed <= 10 {
            status = "Usually about 10 sec · \(elapsed) sec elapsed"
        } else {
            status = "Still ranking · \(elapsed) sec elapsed"
        }
        hyperDLoadingView?.setStatus(status)
    }

    private func addHyperDRefreshCompletionTransition() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = scroll.contentView.layer
        else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        layer.removeAnimation(forKey: "caseTodayRefreshCompletion")
        layer.add(transition, forKey: "caseTodayRefreshCompletion")
    }

    func prepareForPresentation() {
        guard let layer = card.layer else { return }
        layer.removeAnimation(forKey: "caseTodoPresent")
        layer.removeAnimation(forKey: "caseTodoDismiss")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DIdentity
            : CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.commit()
    }

    func animatePresentation() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = card.layer
        else { return }
        let start = CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = 0.24
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.08, 0.4, 1)
        layer.add(animation, forKey: "caseTodoPresent")
    }

    func animateDismissal() {
        guard let layer = card.layer else { return }
        let target = CATransform3DMakeScale(0.97, 0.97, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(animation, forKey: "caseTodoDismiss")
    }

    func resetCardTransform() {
        guard let layer = card.layer else { return }
        layer.removeAnimation(forKey: "caseTodoPresent")
        layer.removeAnimation(forKey: "caseTodoDismiss")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func refreshOverflowFades() {
        updateListFades()
    }

    func recordCompletion(_ todo: TodoMenuEntry, entry: TodoLogbookEntry) {
        let completed = TodoMenuEntry(
            id: todo.id,
            source: todo.source,
            lineIndex: todo.lineIndex,
            timestamp: todo.timestamp,
            text: todo.text,
            isDone: true
        )
        sessionCompleted.removeAll { $0.entry.id == entry.id || $0.todo.id == todo.id }
        animateTodayCompletionUpdate()
        sessionCompleted.insert(
            SessionCompletedTodo(todo: completed, entry: entry, detail: "Recently completed"),
            at: 0
        )
    }

    func removeSessionCompletion(_ entry: TodoLogbookEntry) {
        sessionCompleted.removeAll { $0.entry.id == entry.id }
    }

    func rebuild(navigation: NavigationDirection? = nil) {
        guard isViewLoaded else { return }
        if let navigation {
            addNavigationTransition(navigation)
        }
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        switch screen {
        case .overview:
            buildOverview()
        case .source(let source):
            buildSource(source)
        case .logbook:
            buildLogbook()
        }
        layoutList()
    }

    private func setHeader(_ header: CASEMenuHeaderView) {
        NSLayoutConstraint.deactivate(headerConstraints)
        headerConstraints.removeAll()
        for subview in headerContainer.subviews {
            subview.removeFromSuperview()
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(header)
        headerConstraints = [
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(headerConstraints)
    }

    private func buildOverview() {
        let owing = QuickEntryStore.displayTodoItems(in: .owing).filter { !$0.isDone }
        let inbox = QuickEntryStore.displayTodoItems(in: .inbox).filter { !$0.isDone }
        let openCount = owing.count + inbox.count
        let hyperD = QuickEntryStore.hyperDTodos()

        setHeader(CASEMenuHeaderView(
            title: "Today",
            subtitle: openCount == 0 ? "Nothing open. Nice." : "\(openCount) active  •  \(QuickEntryStore.todayUpdatedText())",
            // Do not leave a second refresh affordance active while the
            // ranking request owns this state.
            actionIcon: isRefreshingHyperD ? nil : "↻",
            onAction: onRefreshHyperD
        ))

        if isRefreshingHyperD {
            let loadingView = CASEMenuLoadingView()
            hyperDLoadingView = loadingView
            add(loadingView)
            DispatchQueue.main.async { [weak self, weak loadingView] in
                guard self?.hyperDLoadingView === loadingView else { return }
                loadingView?.startAnimating()
                self?.updateHyperDRefreshStatus()
            }
        } else if hyperD.isEmpty {
            add(CASEMenuEmptyView(message: "No priority set yet. Refresh to rank today."))
        } else {
            for item in hyperD {
                add(CASETodoRowView(todo: item.todo, detail: item.why, onToggle: onToggle))
            }
        }

        if !sessionCompleted.isEmpty {
            add(CASEMenuSectionView(title: "Recently completed"))
            for completed in sessionCompleted {
                add(CASETodoRowView(
                    todo: completed.todo,
                    detail: completed.detail,
                    isCompleted: true,
                    onToggle: nil
                ))
            }
        }

        add(CASEMenuActionView(
            title: "Owing",
            detail: owing.isEmpty ? "Clear" : "\(owing.count) active",
            icon: "",
            onPress: { [weak self] in self?.show(.owing) }
        ))
        let heldNotes = QuickEntryStore.inboxNotesHeldCount()
        let inboxDetail: String
        if inbox.isEmpty {
            inboxDetail = heldNotes > 0 ? "\(heldNotes) notes held" : "Clear"
        } else {
            inboxDetail = heldNotes > 0 ? "\(inbox.count) to do · \(heldNotes) notes held" : "\(inbox.count) to do"
        }
        add(CASEMenuActionView(
            title: "Inbox",
            detail: inboxDetail,
            icon: "",
            onPress: { [weak self] in self?.show(.inbox) }
        ))
        let logbookCount = QuickEntryStore.logbookEntries().count
        add(CASEMenuActionView(
            title: "Logbook",
            detail: logbookCount == 0 ? "No completed to-dos" : "\(logbookCount) completed",
            icon: "",
            onPress: { [weak self] in self?.showLogbook() }
        ))
    }

    private func buildSource(_ source: TodoSource) {
        let todos = QuickEntryStore.displayTodoItems(in: source).filter { !$0.isDone }
        let subtitle: String
        if source == .inbox, QuickEntryStore.inboxNotesHeldCount() > 0 {
            subtitle = "\(todos.count) actionable to-dos  •  \(QuickEntryStore.inboxNotesHeldCount()) notes held"
        } else {
            subtitle = todos.isEmpty ? "Nothing active" : "\(todos.count) active item\(todos.count == 1 ? "" : "s")"
        }
        setHeader(CASEMenuHeaderView(
            title: source.title,
            subtitle: subtitle,
            onBack: { [weak self] in self?.showOverview() }
        ))

        if todos.isEmpty {
            add(CASEMenuEmptyView(message: "Nothing waiting here."))
        } else {
            var previousContext: String?
            for todo in todos {
                if let context = todo.timestamp, context != previousContext {
                    add(CASEMenuSectionView(title: context))
                    previousContext = context
                }
                let detail = source == .inbox ? (todo.timestamp ?? "Inbox") : ""
                add(CASETodoRowView(todo: todo, detail: detail, onToggle: onToggle))
            }
        }

        add(CASEMenuActionView(
            title: "Open \(source.title) in Finder",
            detail: "Markdown",
            icon: "↗",
            onPress: { [weak self] in self?.onRevealSource(source) }
        ))
    }

    private func buildLogbook() {
        let allEntries = QuickEntryStore.logbookEntries()
        let entries = Array(allEntries.prefix(logbookVisibleCount))
        setHeader(CASEMenuHeaderView(
            title: "Logbook",
            subtitle: allEntries.isEmpty ? "No completed to-dos yet" : "Newest completed to-dos first",
            onBack: { [weak self] in self?.showOverview() }
        ))

        if entries.isEmpty {
            add(CASEMenuEmptyView(message: "Completed to-dos will stay here for rescue."))
        } else {
            var previousBucket: String?
            for entry in entries {
                let bucket = logbookBucket(for: entry)
                if bucket != previousBucket {
                    add(CASEMenuSectionView(title: bucket))
                    previousBucket = bucket
                }
                add(CASELogbookRowView(
                    entry: entry,
                    completedAt: displayLogbookTimestamp(entry.completedAt),
                    onRestore: { [weak self] in self?.onRestoreLogbook(entry) }
                ))
            }
            if entries.count < allEntries.count {
                add(CASEMenuEmptyView(message: "Keep scrolling to load older completed to-dos…"))
            }
        }
    }

    private func show(_ source: TodoSource) {
        screen = .source(source)
        rebuild(navigation: .forward)
        scrollToTop()
    }

    private func showLogbook() {
        logbookVisibleCount = 20
        screen = .logbook
        rebuild(navigation: .forward)
        scrollToTop()
    }

    private func showOverview() {
        screen = .overview
        rebuild(navigation: .backward)
        scrollToTop()
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateListFades()
    }

    private func updateListFades() {
        guard let documentView = scroll.documentView else { return }
        scroll.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = scroll.contentView
        let visibleBounds = clipView.bounds
        let documentBounds = documentView.convert(documentView.bounds, to: clipView)
        let threshold: CGFloat = 0.5
        let hasContentAbove = visibleBounds.minY > documentBounds.minY + threshold
        let hasContentBelow = visibleBounds.maxY < documentBounds.maxY - threshold
        let fadeHeight = min(listFadeHeight, visibleBounds.height)

        topListFade?.frame = NSRect(
            x: visibleBounds.minX,
            y: visibleBounds.minY,
            width: visibleBounds.width,
            height: fadeHeight
        )
        bottomListFade?.frame = NSRect(
            x: visibleBounds.minX,
            y: visibleBounds.maxY - fadeHeight,
            width: visibleBounds.width,
            height: fadeHeight
        )
        topListFade?.alphaValue = hasContentAbove ? 1 : 0
        bottomListFade?.alphaValue = hasContentBelow ? 1 : 0
    }

    private func loadMoreLogbookIfNeeded() {
        guard case .logbook = screen,
              !isLoadingMoreLogbook
        else { return }

        let allEntries = QuickEntryStore.logbookEntries()
        guard logbookVisibleCount < allEntries.count else { return }
        let visibleBottom = scroll.contentView.bounds.maxY
        guard visibleBottom >= stack.frame.height - 100 else { return }

        isLoadingMoreLogbook = true
        let origin = scroll.contentView.bounds.origin
        logbookVisibleCount += 20
        rebuild()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scroll.contentView.scroll(to: origin)
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
            self.isLoadingMoreLogbook = false
        }
    }

    private func animateTodayCompletionUpdate() {
        guard case .overview = screen,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = scroll.contentView.layer
        else { return }

        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        layer.removeAnimation(forKey: "caseTodayCompletion")
        layer.add(transition, forKey: "caseTodayCompletion")
    }

    private func addNavigationTransition(_ direction: NavigationDirection) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = scroll.contentView.layer
        else { return }

        let transition = CATransition()
        transition.type = .push
        transition.subtype = direction == .forward ? .fromRight : .fromLeft
        transition.duration = 0.26
        transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.9, 0.24, 1)
        layer.removeAnimation(forKey: "caseTodoNavigation")
        layer.add(transition, forKey: "caseTodoNavigation")
    }

    private func add(_ arranged: NSView) {
        stack.addArrangedSubview(arranged)
        arranged.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        arranged.heightAnchor.constraint(equalToConstant: arranged.frame.height).isActive = true
    }

    private func layoutList() {
        let width: CGFloat = 368
        let rowHeights = stack.arrangedSubviews.reduce(CGFloat.zero) { $0 + $1.frame.height }
        let spacing = CGFloat(max(0, stack.arrangedSubviews.count - 1)) * stack.spacing
        let verticalPadding = stack.edgeInsets.top + stack.edgeInsets.bottom
        let contentHeight = max(1, rowHeights + spacing + verticalPadding)
        let maximumListHeight: CGFloat = 620 - headerHeight - 8
        let visibleHeight = min(max(contentHeight, 180), maximumListHeight)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        scroll.hasVerticalScroller = contentHeight > visibleHeight
        let nextPreferredSize = NSSize(width: width + 8, height: visibleHeight + headerHeight + 8)
        let preferredSizeChanged = abs(preferredContentSize.width - nextPreferredSize.width) > 0.5 || abs(preferredContentSize.height - nextPreferredSize.height) > 0.5
        preferredContentSize = nextPreferredSize
        if view.window == nil {
            view.setFrameSize(nextPreferredSize)
        } else if preferredSizeChanged {
            onPreferredSizeChange(nextPreferredSize)
        }
        stack.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.updateListFades()
        }
    }

    private func displayLogbookTimestamp(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return "recently" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, h:mma"
        return formatter.string(from: date).lowercased()
    }

    private func logbookBucket(for entry: TodoLogbookEntry) -> String {
        guard let date = ISO8601DateFormatter().date(from: entry.completedAt) else { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start, date >= weekStart {
            return "This week" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .month) { return "This month" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}

final class CASEMenuHeaderView: NSView {
    init(
        title: String,
        subtitle: String,
        actionIcon: String? = nil,
        actionEnabled: Bool = true,
        onAction: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let titleView = NSTextField(labelWithString: title)
        titleView.font = .systemFont(ofSize: 14, weight: .semibold)
        titleView.textColor = qColor(0x1f2329)
        titleView.translatesAutoresizingMaskIntoConstraints = false

        let subtitleView = NSTextField(labelWithString: subtitle)
        subtitleView.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleView.textColor = qColor(0x8d949e)
        subtitleView.lineBreakMode = .byTruncatingTail
        subtitleView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleView)
        addSubview(subtitleView)

        var constraints = [
            titleView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            subtitleView.leadingAnchor.constraint(equalTo: titleView.leadingAnchor),
            subtitleView.topAnchor.constraint(equalTo: titleView.bottomAnchor, constant: 1),
        ]

        if let onBack {
            let back = CASEHeaderActionView(icon: "‹", accessibilityLabel: "Back to Today", isEnabled: true, onPress: onBack)
            back.translatesAutoresizingMaskIntoConstraints = false
            addSubview(back)
            constraints += [
                back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                // Align the back affordance with the title, not the two-line
                // header block; centering it in the whole header read low.
                back.centerYAnchor.constraint(equalTo: titleView.centerYAnchor),
                back.widthAnchor.constraint(equalToConstant: 30),
                back.heightAnchor.constraint(equalToConstant: 30),
                titleView.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 8),
            ]
        } else {
            constraints.append(titleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20))
        }

        if let actionIcon, let onAction {
            let action = CASEHeaderActionView(icon: actionIcon, accessibilityLabel: "Refresh today’s list", isEnabled: actionEnabled, onPress: onAction)
            action.translatesAutoresizingMaskIntoConstraints = false
            addSubview(action)
            constraints += [
                action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                action.centerYAnchor.constraint(equalTo: centerYAnchor),
                action.widthAnchor.constraint(equalToConstant: 30),
                action.heightAnchor.constraint(equalToConstant: 30),
                titleView.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -12),
                subtitleView.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -12),
            ]
        } else {
            constraints += [
                titleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                subtitleView.trailingAnchor.constraint(equalTo: titleView.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }
}

final class CASEHeaderActionView: NSView {
    private let onPress: () -> Void
    private let isActionEnabled: Bool

    init(icon: String, accessibilityLabel: String, isEnabled: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.isActionEnabled = isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xf0f2f5).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        alphaValue = isEnabled ? 1 : 0.5
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)

        let label = NSTextField(labelWithString: icon)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = qColor(0x3f4650)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard isActionEnabled else { return }
        layer?.backgroundColor = qColor(0xe3e7ec).cgColor
        onPress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.layer?.backgroundColor = qColor(0xf0f2f5).cgColor
        }
    }
}

final class CASEMenuSectionView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 368, height: 36))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = qColor(0x4d535c)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class CASEMenuLoadingView: NSView {
    private let card = NSView()
    private let spinner = CASESpinnerView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    private let titleLabel = NSTextField(labelWithString: "Ranking today’s work")
    private let statusLabel = CASEShimmerLabel(text: "Usually about 10 sec · 0 sec elapsed")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 368, height: 58))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        card.wantsLayer = true
        card.layer?.backgroundColor = qColor(0xf2f4f7).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        spinner.setStrokeColor(qColor(0x5c6673))
        spinner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(spinner)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = qColor(0x30353d)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)

        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = qColor(0x7d8590)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // Use the exact same 3 pt vertical inset as the overview rows.
            // Keep the content position fixed while the card gains that pixel.
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            // Match the text rail used by Owing, Inbox, and Logbook. The
            // spinner is a status affordance, so it belongs at the far edge.
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            spinner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -13),
            spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func startAnimating() {
        spinner.startAnimating()
        spinner.alphaValue = 1
        statusLabel.startShimmer(text: statusLabel.stringValue)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer
        else { return }
        let entrance = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 6
        lift.toValue = 0
        entrance.animations = [fade, lift]
        entrance.duration = 0.22
        entrance.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        layer.add(entrance, forKey: "caseTodayLoadingEntrance")
    }

    func setStatus(_ status: String) {
        statusLabel.updateShimmerText(status)
    }

    deinit {
        spinner.stopAnimating()
        statusLabel.stopShimmer()
    }
}

final class CASEMenuEmptyView: NSView {
    init(message: String = "Nothing waiting. Nice.") {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 42))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = qColor(0x8d949e)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 43),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class CASEMenuActionView: NSView {
    private let onPress: () -> Void
    private let isActionEnabled: Bool
    private let card = NSView()

    init(
        title: String,
        detail: String,
        icon: String,
        isEnabled: Bool = true,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.isActionEnabled = isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 46))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor
        alphaValue = isEnabled ? 1 : 0.5
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        card.wantsLayer = true
        card.layer?.backgroundColor = qColor(0xf2f4f7).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let titleView = NSTextField(labelWithString: title)
        titleView.font = .systemFont(ofSize: 12, weight: .semibold)
        titleView.textColor = qColor(0x30353d)
        titleView.translatesAutoresizingMaskIntoConstraints = false

        let detailView = NSTextField(labelWithString: detail)
        detailView.font = .systemFont(ofSize: 11, weight: .medium)
        detailView.textColor = qColor(0x7d8590)
        detailView.alignment = .right
        detailView.lineBreakMode = .byTruncatingHead
        detailView.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(titleView)
        card.addSubview(detailView)

        var constraints = [
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            detailView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            detailView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            detailView.leadingAnchor.constraint(greaterThanOrEqualTo: titleView.trailingAnchor, constant: 12),
        ]

        if icon.isEmpty {
            constraints.append(titleView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13))
        } else {
            let iconView = NSTextField(labelWithString: icon)
            iconView.font = .systemFont(ofSize: 13, weight: .medium)
            iconView.alignment = .center
            iconView.textColor = qColor(0x747d88)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(iconView)
            constraints += [
                iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 14),
                titleView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            ]
        }
        constraints.append(titleView.centerYAnchor.constraint(equalTo: card.centerYAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard isActionEnabled else { return }
        animatePress()
        onPress()
    }

    private func animatePress() {
        card.layer?.backgroundColor = qColor(0xe6eaef).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.card.layer?.backgroundColor = qColor(0xf2f4f7).cgColor
        }
    }
}

final class CASELogbookRowView: NSView {
    private let onRestore: () -> Void
    private let card = NSView()

    init(entry: TodoLogbookEntry, completedAt: String, onRestore: @escaping () -> Void) {
        self.onRestore = onRestore
        let presentation = todoPresentation(entry.text)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = markdownLabel(presentation.title, font: titleFont, color: qColor(0x30353d))
        let titleWidth: CGFloat = 238
        let titleHeight = ceil(title.boundingRect(
            with: NSSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let rowHeight = max(CGFloat(62), 14 + titleHeight + 3 + 13 + 14)
        super.init(frame: NSRect(x: 0, y: 0, width: 368, height: rowHeight))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor
        setAccessibilityRole(.button)
        setAccessibilityLabel("Restore \(presentation.title)")

        card.wantsLayer = true
        card.layer?.backgroundColor = qColor(0xf2f4f7).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let titleView = NSTextField(labelWithString: "")
        titleView.attributedStringValue = title
        titleView.maximumNumberOfLines = 0
        titleView.lineBreakMode = .byWordWrapping
        titleView.cell?.wraps = true
        titleView.cell?.isScrollable = false
        titleView.translatesAutoresizingMaskIntoConstraints = false

        let detailView = NSTextField(labelWithString: conciseMetadata("\(entry.source.title) · \(completedAt)", category: presentation.category))
        detailView.font = .systemFont(ofSize: 10, weight: .regular)
        detailView.textColor = qColor(0x858d98)
        detailView.lineBreakMode = .byTruncatingTail
        detailView.translatesAutoresizingMaskIntoConstraints = false

        let restorePill = NSView()
        restorePill.wantsLayer = true
        restorePill.layer?.backgroundColor = qColor(0xe2e6eb).cgColor
        restorePill.layer?.cornerRadius = 7
        restorePill.layer?.cornerCurve = .continuous
        restorePill.translatesAutoresizingMaskIntoConstraints = false

        let restoreLabel = NSTextField(labelWithString: "Restore")
        restoreLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        restoreLabel.textColor = qColor(0x4a525c)
        restoreLabel.translatesAutoresizingMaskIntoConstraints = false
        restorePill.addSubview(restoreLabel)

        card.addSubview(titleView)
        card.addSubview(detailView)
        card.addSubview(restorePill)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            titleView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
            titleView.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            titleView.trailingAnchor.constraint(equalTo: restorePill.leadingAnchor, constant: -8),
            titleView.heightAnchor.constraint(equalToConstant: titleHeight),

            detailView.leadingAnchor.constraint(equalTo: titleView.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -13),
            detailView.topAnchor.constraint(equalTo: titleView.bottomAnchor, constant: 3),
            detailView.heightAnchor.constraint(equalToConstant: 13),

            restorePill.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            restorePill.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            restorePill.widthAnchor.constraint(equalToConstant: 52),
            restorePill.heightAnchor.constraint(equalToConstant: 22),
            restoreLabel.centerXAnchor.constraint(equalTo: restorePill.centerXAnchor),
            restoreLabel.centerYAnchor.constraint(equalTo: restorePill.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        card.layer?.backgroundColor = qColor(0xe6eaef).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            self.onRestore()
        }
    }
}

final class CASECheckboxView: NSView {
    var checked = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (checked ? qColor(0x1f2329) : qColor(0xfbfbfc)).setFill()
        path.fill()
        (checked ? qColor(0x1f2329) : qColor(0xcfd5df)).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        if checked {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: bounds.width * 0.28, y: bounds.height * 0.52))
            check.line(to: NSPoint(x: bounds.width * 0.44, y: bounds.height * 0.34))
            check.line(to: NSPoint(x: bounds.width * 0.72, y: bounds.height * 0.68))
            qColor(0xffffff).setStroke()
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }
    }
}

final class CASELinkButton: NSButton {
    private let onOpen: () -> Void

    init(title: String, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        font = .systemFont(ofSize: 10, weight: .medium)
        contentTintColor = .linkColor
        target = self
        action = #selector(open)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    @objc private func open() {
        onOpen()
    }
}

final class CASETodoRowView: NSView {
    private let todo: TodoMenuEntry
    private let onToggle: ((TodoMenuEntry) -> Void)?
    private let isCompleted: Bool
    private let checkbox = CASECheckboxView()
    private let restingColor: NSColor

    init(
        todo: TodoMenuEntry,
        detail: String,
        isCompleted: Bool = false,
        onToggle: ((TodoMenuEntry) -> Void)?
    ) {
        self.todo = todo
        self.onToggle = onToggle
        self.isCompleted = isCompleted
        restingColor = qColor(0xfbfbfc)

        let presentation = todoPresentation(todo.text)
        let titleAndURL = firstURLAndTitle(presentation.title)
        let noteText = conciseMetadata(detail, category: presentation.category)
        let hasDetail = !noteText.isEmpty
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleColor = isCompleted ? qColor(0x858d98) : qColor(0x20242a)
        let styledTitle = NSMutableAttributedString(attributedString: markdownLabel(Self.clean(titleAndURL.title), font: titleFont, color: titleColor))
        if isCompleted {
            styledTitle.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: styledTitle.length))
        }
        let titleWidth: CGFloat = titleAndURL.url == nil ? 300 : 238
        let measuredTitleHeight = ceil(styledTitle.boundingRect(
            with: NSSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let rowHeight = max(hasDetail ? CGFloat(58) : CGFloat(42), 13 + measuredTitleHeight + (hasDetail ? 15 : 0) + 12)

        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: rowHeight))
        wantsLayer = true
        layer?.backgroundColor = restingColor.cgColor
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(presentation.title). \(noteText). \(isCompleted ? "Completed" : "Mark complete")")

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = styledTitle
        title.maximumNumberOfLines = 0
        title.lineBreakMode = .byWordWrapping
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString: Self.clean(noteText))
        note.font = .systemFont(ofSize: 10, weight: .regular)
        note.textColor = isCompleted ? qColor(0x9ca3ac) : qColor(0xa0a7b0)
        note.lineBreakMode = .byTruncatingTail
        note.translatesAutoresizingMaskIntoConstraints = false
        note.isHidden = !hasDetail

        checkbox.checked = isCompleted
        addSubview(checkbox)
        addSubview(title)
        addSubview(note)

        let linkButton: CASELinkButton? = titleAndURL.url.map { url in
            let button = CASELinkButton(title: "Open ↗") {
                NSWorkspace.shared.open(url)
            }
            addSubview(button)
            return button
        }

        var constraints = [
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            checkbox.widthAnchor.constraint(equalToConstant: 14),
            checkbox.heightAnchor.constraint(equalToConstant: 14),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 43),
            title.trailingAnchor.constraint(equalTo: linkButton?.leadingAnchor ?? trailingAnchor, constant: linkButton == nil ? -18 : -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.heightAnchor.constraint(equalToConstant: measuredTitleHeight),
        ]
        if let linkButton {
            constraints += [
                linkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                linkButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                linkButton.widthAnchor.constraint(equalToConstant: 48),
                linkButton.heightAnchor.constraint(equalToConstant: 20),
            ]
        }
        if hasDetail {
            constraints += [
                note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                note.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                note.heightAnchor.constraint(equalToConstant: 13),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard !isCompleted, let onToggle else { return }
        layer?.backgroundColor = qColor(0xe9edf1).cgColor
        checkbox.checked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            onToggle(self.todo)
        }
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = restingColor.cgColor
    }

    private static func clean(_ input: String) -> String {
        input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

final class CASESpinnerView: NSView {
    private let arcLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(arcLayer)

        arcLayer.fillColor = NSColor.clear.cgColor
        arcLayer.strokeColor = NSColor.white.cgColor
        arcLayer.lineWidth = 1.8
        arcLayer.lineCap = .round
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updatePath()
    }

    func setStrokeColor(_ color: NSColor) {
        arcLayer.strokeColor = color.cgColor
    }

    func startAnimating() {
        isHidden = false
        updatePath()
        guard arcLayer.animation(forKey: "caseSpin") == nil else { return }

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        arcLayer.add(animation, forKey: "caseSpin")
    }

    func stopAnimating() {
        arcLayer.removeAnimation(forKey: "caseSpin")
        isHidden = true
        alphaValue = 0
    }

    private func updatePath() {
        let inset = arcLayer.lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.12,
            clockwise: false
        )
        arcLayer.frame = bounds
        arcLayer.path = path
    }
}

final class CASEPassiveButtonTitleLabel: NSTextField {
    init(text: String = "") {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        textColor = .white
        font = .systemFont(ofSize: 12, weight: .semibold)
        alignment = .center
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CASERollingActionButton: NSButton {
    private let titleLabel = CASEPassiveButtonTitleLabel()
    private var currentActionTitle = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        titleLabel.frame = titleFrame
    }

    func setActionTitle(
        _ title: String,
        animated: Bool = false,
        direction: ModeTextRollDirection = .up
    ) {
        guard title != currentActionTitle else { return }
        let previousTitle = currentActionTitle
        currentActionTitle = title
        setAccessibilityLabel(title.isEmpty ? "Working" : title)
        cancelTitleTransition()

        let finalFrame = titleFrame
        guard animated,
              !previousTitle.isEmpty,
              !title.isEmpty,
              window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let titleLayer = titleLabel.layer
        else {
            titleLabel.stringValue = title
            titleLabel.frame = finalFrame
            titleLabel.alphaValue = title.isEmpty ? 0 : 1
            return
        }

        addModeTextRoll(
            to: titleLayer,
            key: "caseActionTitleRoll",
            subtype: direction.buttonTitleSubtype
        )
        titleLabel.stringValue = title
        titleLabel.frame = finalFrame
        titleLabel.alphaValue = 1
    }

    private var titleFrame: NSRect {
        let height: CGFloat = 16
        return NSRect(
            x: 4,
            y: floor((bounds.height - height) / 2),
            width: max(0, bounds.width - 8),
            height: height
        )
    }

    private func cancelTitleTransition() {
        titleLabel.layer?.removeAnimation(forKey: "caseActionTitleRoll")
        titleLabel.alphaValue = currentActionTitle.isEmpty ? 0 : 1
        titleLabel.frame = titleFrame
    }
}

final class CASEShimmerLabel: NSTextField {
    private var gradientLayer: CAGradientLayer?
    private var textMaskLayer: CATextLayer?
    private var restingTextColor: NSColor?

    convenience init(text: String) {
        self.init(frame: .zero)
        stringValue = text
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateShimmerFrames()
    }

    func startShimmer(text: String) {
        stringValue = text
        stopShimmer(restoreTextColor: false)
        restingTextColor = textColor
        textColor = .clear
        wantsLayer = true
        guard let hostLayer = layer else { return }

        let mask = CATextLayer()
        mask.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        mask.string = stringValue
        mask.alignmentMode = .left
        mask.truncationMode = .end
        mask.isWrapped = false
        if let font {
            mask.font = font.fontName as CFString
            mask.fontSize = font.pointSize
        }
        mask.foregroundColor = NSColor.black.cgColor

        let gradient = CAGradientLayer()
        gradient.contentsScale = mask.contentsScale
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            qColor(0x868d97, alpha: 0.55).cgColor,
            qColor(0x0e1014, alpha: 0.96).cgColor,
            qColor(0x868d97, alpha: 0.55).cgColor,
        ]
        gradient.locations = [-0.35, -0.12, 0.1]
        gradient.mask = mask

        hostLayer.addSublayer(gradient)
        gradientLayer = gradient
        textMaskLayer = mask
        updateShimmerFrames()

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.35, -0.12, 0.1]
        animation.toValue = [0.9, 1.12, 1.35]
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(animation, forKey: "caseTextShimmer")
    }

    func stopShimmer(restoreTextColor: Bool = true) {
        gradientLayer?.removeAnimation(forKey: "caseTextShimmer")
        gradientLayer?.removeFromSuperlayer()
        gradientLayer = nil
        textMaskLayer = nil
        if restoreTextColor, let restingTextColor {
            textColor = restingTextColor
        }
        restingTextColor = nil
    }

    func updateShimmerText(_ text: String) {
        stringValue = text
        textMaskLayer?.string = text
        updateShimmerFrames()
    }

    func setText(
        _ text: String,
        animated: Bool = false,
        direction: ModeTextRollDirection = .up
    ) {
        guard text != stringValue else { return }
        guard animated,
              gradientLayer == nil,
              window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer
        else {
            stringValue = text
            return
        }

        addModeTextRoll(
            to: layer,
            key: "caseStatusTextRoll",
            subtype: direction.fieldSubtype
        )
        stringValue = text
    }

    private func updateShimmerFrames() {
        gradientLayer?.frame = bounds
        textMaskLayer?.frame = bounds
    }
}

final class CASEModeTabs: NSView {
    enum Selection {
        case todo
        case writing
    }

    var onSelection: ((Selection) -> Void)?

    private let activePill = CALayer()
    private let todoButton = NSButton(title: "To do", target: nil, action: nil)
    private let writingButton = NSButton(title: "Writing", target: nil, action: nil)
    private(set) var selection: Selection = .todo
    private var isControlEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = qColor(0xf0f2f5).cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

        activePill.backgroundColor = qColor(0x0e1014).cgColor
        activePill.cornerRadius = 12
        activePill.cornerCurve = .continuous

        configure(todoButton, label: "Todo mode", identifier: "CASEQuickEntryModeTodo")
        configure(writingButton, label: "Writing mode", identifier: "CASEQuickEntryModeWriting")
        todoButton.target = self
        todoButton.action = #selector(selectTodo)
        writingButton.target = self
        writingButton.action = #selector(selectWriting)

        addSubview(todoButton)
        addSubview(writingButton)
        layer?.insertSublayer(activePill, at: 0)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let inset: CGFloat = 2
        let segmentWidth = max(0, (bounds.width - inset * 2) / 2)
        let segmentHeight = max(0, bounds.height - inset * 2)
        let todoFrame = NSRect(x: inset, y: inset, width: segmentWidth, height: segmentHeight)
        let writingFrame = todoFrame.offsetBy(dx: segmentWidth, dy: 0)
        todoButton.frame = todoFrame
        writingButton.frame = writingFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activePill.frame = indicatorFrame(for: selection)
        CATransaction.commit()
    }

    func setSelection(_ selection: Selection, animated: Bool = false) {
        guard selection != self.selection else { return }
        layoutSubtreeIfNeeded()
        let currentX = activePill.presentation()?.position.x ?? activePill.position.x
        activePill.removeAnimation(forKey: "caseModeTabSlide")
        activePill.removeAnimation(forKey: "caseModeTabImpact")
        self.selection = selection
        let targetFrame = indicatorFrame(for: selection)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activePill.frame = targetFrame
        CATransaction.commit()

        if animated, targetFrame.width > 0, abs(currentX - targetFrame.midX) > 0.5 {
            animateActivePill(from: currentX, to: targetFrame.midX)
        }

        updateAppearance()
    }

    private func animateActivePill(from currentX: CGFloat, to targetX: CGFloat) {
        let direction: CGFloat = targetX > currentX ? 1 : -1

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = currentX
            slide.toValue = targetX
            slide.duration = 0.18
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            activePill.add(slide, forKey: "caseModeTabSlide")
            return
        }

        // The active tab travels to the far edge, then gives a near-imperceptible
        // one-point rebound so the landing feels intentional rather than springy.
        let overshoot = min(CGFloat(1), abs(targetX - currentX) * 0.02)
        let slide = CAKeyframeAnimation(keyPath: "position.x")
        slide.values = [
            currentX,
            targetX + direction * overshoot,
            targetX - direction * (overshoot * 0.35),
            targetX,
        ]
        slide.keyTimes = [0, 0.72, 0.88, 1]
        slide.duration = 0.30
        slide.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        activePill.add(slide, forKey: "caseModeTabSlide")

        let impact = CAKeyframeAnimation(keyPath: "transform.scale.x")
        impact.values = [1, 1, 0.985, 1.004, 1]
        impact.keyTimes = [0, 0.68, 0.78, 0.90, 1]
        impact.duration = slide.duration
        impact.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]
        activePill.add(impact, forKey: "caseModeTabImpact")
    }

    func setEnabled(_ enabled: Bool) {
        isControlEnabled = enabled
        todoButton.isEnabled = enabled
        writingButton.isEnabled = enabled
        updateAppearance()
    }

    @objc private func selectTodo() {
        select(.todo)
    }

    @objc private func selectWriting() {
        select(.writing)
    }

    private func select(_ selection: Selection) {
        guard isControlEnabled, selection != self.selection else { return }
        setSelection(selection, animated: true)
        onSelection?(selection)
    }

    private func configure(_ button: NSButton, label: String, identifier: String) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.focusRingType = .none
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }

    private func updateAppearance() {
        let activeText = NSColor.white
        let inactiveText = qColor(0x555a63)
        todoButton.contentTintColor = selection == .todo ? activeText : inactiveText
        writingButton.contentTintColor = selection == .writing ? activeText : inactiveText
        alphaValue = isControlEnabled ? 1 : 0.55
    }

    private func indicatorFrame(for selection: Selection) -> NSRect {
        selection == .todo ? todoButton.frame : writingButton.frame
    }
}

final class CASETextInputEdgeFade: NSView {
    enum Edge {
        case top
        case bottom
    }

    private let edge: Edge
    private let backgroundColor: NSColor

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(edge: Edge, backgroundColor: NSColor = qColor(0xffffff)) {
        self.edge = edge
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let opaque = backgroundColor.withAlphaComponent(0.96)
        let transparent = backgroundColor.withAlphaComponent(0)
        let gradient: NSGradient
        switch edge {
        case .top:
            gradient = NSGradient(starting: opaque, ending: transparent)!
        case .bottom:
            gradient = NSGradient(starting: transparent, ending: opaque)!
        }
        gradient.draw(
            from: NSPoint(x: bounds.midX, y: bounds.minY),
            to: NSPoint(x: bounds.midX, y: bounds.maxY),
            options: []
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class QuickEntryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TodoMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class QuickEntryPanelController: NSObject, NSWindowDelegate {
    private enum EntryMode {
        case todo
        case writing
    }

    private let window: NSPanel
    private let textView: QuickEntryTextView
    private let statusLabel: CASEShimmerLabel
    private var card: NSView?
    private var textScroll: NSScrollView?
    private var topTextInputFade: CASETextInputEdgeFade?
    private var bottomTextInputFade: CASETextInputEdgeFade?
    private let textInputFadeHeight: CGFloat = 14
    private var textScrollBoundsObserver: NSObjectProtocol?
    private var isTextInputFadeUpdateScheduled = false
    private var saveButton: CASERollingActionButton?
    private var copyButton: NSButton?
    private var modeTabs: CASEModeTabs?
    private var cancelButton: NSButton?
    private var polishSpinner: CASESpinnerView?
    private var mode: EntryMode = .todo
    private var targetFrame: NSRect = .zero
    private var isPolishing = false
    private var polishStartedAt: Date?
    private var polishEstimatedDuration: TimeInterval = 0
    private var polishStatusTimer: Timer?

    deinit {
        polishStatusTimer?.invalidate()
        if let textScrollBoundsObserver {
            NotificationCenter.default.removeObserver(textScrollBoundsObserver)
        }
    }

    override init() {
        AppLog.write("QuickEntryPanelController init")
        window = QuickEntryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 198),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Entry"
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0

        textView = QuickEntryTextView(frame: .zero)
        statusLabel = CASEShimmerLabel(text: "⌘↩ save · esc cancel")
        super.init()

        textView.onSave = { [weak self] in self?.primaryAction() }
        textView.onCancel = { [weak self] in self?.close() }
        textView.onTodoMode = { [weak self] in self?.selectModeFromShortcut(.todo) }
        textView.onWritingMode = { [weak self] in self?.selectModeFromShortcut(.writing) }
        window.delegate = self
        buildUI()
    }

    func show() {
        if isPolishing {
            AppLog.write("panel show requested while polish is pending; preserving draft")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        AppLog.write("panel show requested")
        resetCardTransform()
        textView.string = ""
        mode = .todo
        isPolishing = false
        window.hidesOnDeactivate = true
        statusLabel.stopShimmer()
        polishSpinner?.stopAnimating()
        applyMode()
        textView.isEditable = true
        saveButton?.layer?.backgroundColor = qColor(0x0e1014).cgColor
        saveButton?.contentTintColor = .white
        saveButton?.alphaValue = 1
        saveButton?.isEnabled = true
        copyButton?.isHidden = true
        copyButton?.isEnabled = false
        modeTabs?.setEnabled(true)
        cancelButton?.isEnabled = true
        positionAtTopCenter()

        let startFrame = scaledFrame(from: targetFrame, scale: 0.92).offsetBy(dx: 0, dy: 12)
        window.setFrame(startFrame, display: true)
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let firstResponderSet = window.makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.textView)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.08, 0.4, 1)
            window.animator().alphaValue = 1
            window.animator().setFrame(targetFrame, display: true)
        }

        scheduleTextInputFadeUpdate()
        AppLog.write("panel shown; isVisible=\(window.isVisible); isKeyWindow=\(window.isKeyWindow); firstResponderSet=\(firstResponderSet)")
    }

    private func buildUI() {
        guard let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = qColor(0xfbfbfc, alpha: 0.995).cgColor
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = qColor(0xffffff, alpha: 0.86).cgColor
        card.layer?.shadowColor = qColor(0x000000).cgColor
        card.layer?.shadowOpacity = 0.22
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = NSSize(width: 0, height: -6)
        self.card = card

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let modeTabs = CASEModeTabs(frame: .zero)
        modeTabs.translatesAutoresizingMaskIntoConstraints = false
        modeTabs.onSelection = { [weak self] selection in
            self?.selectMode(selection)
        }
        self.modeTabs = modeTabs

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = qColor(0x868d97)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        header.addArrangedSubview(modeTabs)
        header.addArrangedSubview(headerSpacer)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 16
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.backgroundColor = qColor(0xffffff).cgColor
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = qColor(0xe2e6ec).cgColor
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        textScroll = scroll

        let topTextInputFade = CASETextInputEdgeFade(edge: .top)
        let bottomTextInputFade = CASETextInputEdgeFade(edge: .bottom)
        // Put the overlays inside the clip view, above the document view. Their
        // frames are updated with the clip bounds so they stay pinned to the
        // visible edges while the text scrolls.
        scroll.contentView.addSubview(topTextInputFade, positioned: .above, relativeTo: textView)
        scroll.contentView.addSubview(bottomTextInputFade, positioned: .above, relativeTo: topTextInputFade)
        self.topTextInputFade = topTextInputFade
        self.bottomTextInputFade = bottomTextInputFade

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 428, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 13, height: 11)
        textView.font = .systemFont(ofSize: 15, weight: .regular)
        textView.textColor = qColor(0x0e1014)
        textView.backgroundColor = .clear
        textView.wantsLayer = true
        textView.insertionPointColor = qColor(0x2d7a4a)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticTextCompletionEnabled = true
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityLabel("Quick Entry")
        textView.setAccessibilityIdentifier("CASEQuickEntryInput")
        textView.placeholder = "Drop the thing before it evaporates…"
        textView.onContentChange = { [weak self] in
            self?.scheduleTextInputFadeUpdate()
        }

        let footer = NSStackView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyWriting))
        configureButton(copyButton, background: qColor(0xf0f2f5), text: qColor(0x555a63))
        copyButton.isHidden = true
        copyButton.isEnabled = false
        self.copyButton = copyButton

        let saveButton = CASERollingActionButton(frame: .zero)
        saveButton.target = self
        saveButton.action = #selector(primaryAction)
        configureButton(saveButton, background: qColor(0x0e1014), text: .white)
        saveButton.setActionTitle("Save")
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        self.saveButton = saveButton

        let polishSpinner = CASESpinnerView(frame: .zero)
        polishSpinner.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addSubview(polishSpinner)
        self.polishSpinner = polishSpinner

        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(footerSpacer)
        footer.addArrangedSubview(copyButton)
        footer.addArrangedSubview(saveButton)

        content.addSubview(card)
        card.addSubview(header)
        card.addSubview(scroll)
        card.addSubview(footer)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            modeTabs.widthAnchor.constraint(equalToConstant: 144),
            modeTabs.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 78),

            // The helper copy is a text label, so align it to the input's
            // text rail rather than the input frame.
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 29),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            copyButton.widthAnchor.constraint(equalToConstant: 64),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
            saveButton.widthAnchor.constraint(equalToConstant: 70),
            saveButton.heightAnchor.constraint(equalToConstant: 28),
            polishSpinner.centerXAnchor.constraint(equalTo: saveButton.centerXAnchor),
            polishSpinner.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            polishSpinner.widthAnchor.constraint(equalToConstant: 15),
            polishSpinner.heightAnchor.constraint(equalToConstant: 15),
        ])

        textScrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateTextInputFades()
        }
        scheduleTextInputFadeUpdate()
    }

    private func configureButton(_ button: NSButton, background: NSColor, text: NSColor) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = background.cgColor
        button.layer?.cornerRadius = 14
        button.layer?.cornerCurve = .continuous
        button.contentTintColor = text
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func positionAtTopCenter() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else {
            AppLog.write("positionAtTopCenter failed: no screen")
            targetFrame = window.frame
            return
        }
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 54
        )
        targetFrame = NSRect(origin: origin, size: size)
        AppLog.write("positioned panel top-center on screen frame=\(frame); targetFrame=\(targetFrame)")
    }

    private func scaledFrame(from frame: NSRect, scale: CGFloat) -> NSRect {
        let newWidth = frame.width * scale
        let newHeight = frame.height * scale
        return NSRect(
            x: frame.midX - newWidth / 2,
            y: frame.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
    }

    private func scheduleTextInputFadeUpdate() {
        guard !isTextInputFadeUpdateScheduled else { return }
        isTextInputFadeUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTextInputFadeUpdateScheduled = false
            self.updateTextInputFades()
        }
    }

    private func updateTextInputFades() {
        guard let textScroll, let documentView = textScroll.documentView else { return }

        textScroll.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = textScroll.contentView
        let visibleBounds = clipView.bounds
        let documentBounds = documentView.convert(documentView.bounds, to: clipView)
        let threshold: CGFloat = 0.5
        let hasTextAbove = visibleBounds.minY > documentBounds.minY + threshold
        let hasTextBelow = visibleBounds.maxY < documentBounds.maxY - threshold
        let fadeHeight = min(textInputFadeHeight, visibleBounds.height)

        topTextInputFade?.frame = NSRect(
            x: visibleBounds.minX,
            y: visibleBounds.minY,
            width: visibleBounds.width,
            height: fadeHeight
        )
        bottomTextInputFade?.frame = NSRect(
            x: visibleBounds.minX,
            y: visibleBounds.maxY - fadeHeight,
            width: visibleBounds.width,
            height: fadeHeight
        )
        topTextInputFade?.alphaValue = hasTextAbove ? 1 : 0
        bottomTextInputFade?.alphaValue = hasTextBelow ? 1 : 0
    }

    private func animateCardScale(
        from: CGFloat,
        to: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        key: String
    ) {
        guard let layer = card?.layer else { return }

        let fromTransform = CATransform3DMakeScale(from, from, 1)
        let toTransform = CATransform3DMakeScale(to, to, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = toTransform
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: fromTransform)
        animation.toValue = NSValue(caTransform3D: toTransform)
        animation.duration = duration
        animation.timingFunction = timingFunction
        layer.add(animation, forKey: key)
    }

    private func resetCardTransform() {
        guard let layer = card?.layer else { return }
        layer.removeAnimation(forKey: "quickEntrySubmitGrow")
        layer.removeAnimation(forKey: "quickEntrySubmitDismiss")
        layer.removeAnimation(forKey: "quickEntryCloseDismiss")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func selectModeFromShortcut(_ selection: CASEModeTabs.Selection) {
        guard !isPolishing else { return }
        selectMode(selection)
    }

    private func selectMode(_ selection: CASEModeTabs.Selection) {
        let selectedMode: EntryMode = selection == .todo ? .todo : .writing
        guard selectedMode != mode else { return }
        mode = selectedMode
        applyMode(animated: true)
        window.makeFirstResponder(textView)
    }

    private func applyMode(animated: Bool = false) {
        hideCopyButton(animated: animated)
        modeTabs?.setSelection(mode == .todo ? .todo : .writing, animated: animated)

        let actionTitle: String
        let statusText: String
        let placeholder: String
        let rollDirection: ModeTextRollDirection
        switch mode {
        case .todo:
            actionTitle = "Save"
            statusText = "Timestamped. Calendar-aware. Routed later."
            placeholder = "Drop the thing before it evaporates…"
            rollDirection = .down
        case .writing:
            actionTitle = "Polish"
            statusText = "Brain dump. Polish for Slack."
            placeholder = "Brain dump with MacWhisper…"
            rollDirection = .up
        }

        saveButton?.setActionTitle(actionTitle, animated: animated, direction: rollDirection)
        statusLabel.setText(statusText, animated: animated, direction: rollDirection)
        textView.setPlaceholder(placeholder, animated: animated, direction: rollDirection)
    }

    private func hideCopyButton(animated: Bool) {
        guard let copyButton else { return }
        copyButton.isEnabled = false

        guard animated, !copyButton.isHidden else {
            copyButton.isHidden = true
            copyButton.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            copyButton.animator().alphaValue = 0
        } completionHandler: {
            copyButton.isHidden = true
            copyButton.alphaValue = 1
        }
    }

    @objc private func primaryAction() {
        guard !isPolishing else { return }
        switch mode {
        case .todo:
            save()
        case .writing:
            polishWriting()
        }
    }

    private func save() {
        let raw = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.write("save requested; rawLength=\(raw.count)")
        guard !raw.isEmpty else {
            AppLog.write("save ignored: empty input")
            NSSound.beep()
            statusLabel.stringValue = "write something first"
            return
        }

        do {
            try QuickEntryStore.append(raw)
            AppLog.write("save succeeded")
            statusLabel.stringValue = "saved ✓"
            submitSuccessAnimation()
        } catch {
            AppLog.write("save failed: \(error.localizedDescription)")
            NSSound.beep()
            statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
        }
    }

    private func estimatedPolishDuration(for raw: String) -> TimeInterval {
        switch raw.count {
        case ..<600:
            return 4
        case ..<1_500:
            return 6
        case ..<3_000:
            return 9
        default:
            return 12
        }
    }

    private var polishElapsedDuration: TimeInterval {
        guard let polishStartedAt else { return 0 }
        return Date().timeIntervalSince(polishStartedAt)
    }

    private func polishStatusText() -> String {
        let estimatedSeconds = Int(polishEstimatedDuration.rounded())
        let elapsedSeconds = Int(polishElapsedDuration.rounded(.down))
        if polishElapsedDuration > polishEstimatedDuration + 1 {
            return "still polishing · \(elapsedSeconds) sec"
        }
        return "polishing · about \(estimatedSeconds) sec"
    }

    private func startPolishStatusUpdates(estimatedDuration: TimeInterval) {
        polishStatusTimer?.invalidate()
        polishStartedAt = Date()
        polishEstimatedDuration = estimatedDuration
        statusLabel.startShimmer(text: polishStatusText())

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusLabel.updateShimmerText(self.polishStatusText())
        }
        polishStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPolishStatusUpdates() {
        polishStatusTimer?.invalidate()
        polishStatusTimer = nil
        polishStartedAt = nil
        polishEstimatedDuration = 0
    }

    private func setPolishLoading(_ loading: Bool, estimatedDuration: TimeInterval = 0) {
        guard let saveButton else { return }
        if loading {
            window.hidesOnDeactivate = false
        } else if window.isKeyWindow {
            window.hidesOnDeactivate = true
        }

        if loading {
            saveButton.setActionTitle("")
            saveButton.layer?.backgroundColor = qColor(0x0e1014).cgColor
            saveButton.contentTintColor = .white
            saveButton.alphaValue = 0.98

            polishSpinner?.alphaValue = 0
            polishSpinner?.startAnimating()
            startPolishStatusUpdates(estimatedDuration: estimatedDuration)

            let press = CABasicAnimation(keyPath: "transform.scale")
            press.fromValue = 0.965
            press.toValue = 1.0
            press.duration = 0.18
            press.timingFunction = CAMediaTimingFunction(name: .easeOut)
            saveButton.layer?.add(press, forKey: "casePolishPress")

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.polishSpinner?.animator().alphaValue = 1
                saveButton.animator().alphaValue = 1
            }
        } else {
            stopPolishStatusUpdates()
            statusLabel.stopShimmer()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.polishSpinner?.animator().alphaValue = 0
            } completionHandler: {
                self.polishSpinner?.stopAnimating()
            }
        }
    }

    private func revealPolishedText(_ polished: String, completion: (() -> Void)? = nil) {
        textView.wantsLayer = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.textView.animator().alphaValue = 0
        } completionHandler: {
            self.textView.string = polished
            self.textView.scrollToBeginningOfDocument(nil)
            self.textView.alphaValue = 0

            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.24
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            self.textView.layer?.add(transition, forKey: "casePolishedTextFade")

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.30
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                self.textView.animator().alphaValue = 1
            } completionHandler: {
                completion?()
            }
        }
    }

    private func finishPolishSuccess(_ polished: String) {
        revealPolishedText(polished) { [weak self] in
            self?.textView.isEditable = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.isPolishing = false
            self.setPolishLoading(false)
            self.saveButton?.isEnabled = true
            self.modeTabs?.setEnabled(true)
            self.applyMode()
            self.revealCopyButton()
            self.statusLabel.stringValue = "polished — review then copy"
        }
    }

    private func revealCopyButton() {
        copyButton?.alphaValue = 0
        copyButton?.isHidden = false
        copyButton?.isEnabled = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.copyButton?.animator().alphaValue = 1
        }
    }

    private func polishWriting() {
        let raw = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.write("polish requested; rawLength=\(raw.count)")
        guard !raw.isEmpty else {
            AppLog.write("polish ignored: empty input")
            NSSound.beep()
            statusLabel.stringValue = "write something first"
            return
        }

        isPolishing = true
        textView.isEditable = false
        copyButton?.isHidden = true
        copyButton?.isEnabled = false
        saveButton?.isEnabled = false
        modeTabs?.setEnabled(false)
        setPolishLoading(true, estimatedDuration: estimatedPolishDuration(for: raw))

        let process = Process()
        guard let scriptURL = Bundle.main.url(forResource: "polish-writing", withExtension: "sh") else {
            NSSound.beep()
            statusLabel.stringValue = "polish helper missing"
            return
        }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        process.terminationHandler = { [weak self] process in
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let polished = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                guard let self else { return }

                guard !polished.isEmpty else {
                    let elapsed = self.polishElapsedDuration
                    self.isPolishing = false
                    self.setPolishLoading(false)
                    self.textView.isEditable = true
                    self.saveButton?.isEnabled = true
                    self.modeTabs?.setEnabled(true)
                    self.applyMode()
                    AppLog.write("polish failed status=\(process.terminationStatus); duration=\(String(format: "%.1f", elapsed))s; error=\(errorText)")
                    NSSound.beep()
                    self.statusLabel.stringValue = "polish failed"
                    return
                }

                if process.terminationStatus != 0 {
                    AppLog.write("polish produced output with nonzero status=\(process.terminationStatus); error=\(errorText)")
                }

                let elapsed = self.polishElapsedDuration
                self.finishPolishSuccess(polished)
                AppLog.write("polish succeeded; duration=\(String(format: "%.1f", elapsed))s; outputLength=\(polished.count)")
            }
        }

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(raw.utf8))
            input.fileHandleForWriting.closeFile()
        } catch {
            AppLog.write("polish launch failed: \(error.localizedDescription)")
            isPolishing = false
            setPolishLoading(false)
            textView.isEditable = true
            saveButton?.isEnabled = true
            modeTabs?.setEnabled(true)
            applyMode()
            NSSound.beep()
            statusLabel.stringValue = "could not start polish"
        }
    }

    @objc private func copyWriting() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "nothing to copy"
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "copied ✓"
        AppLog.write("copy writing succeeded; length=\(text.count)")
    }

    private func submitSuccessAnimation() {
        saveButton?.setActionTitle("Saved ✓")
        saveButton?.layer?.backgroundColor = qColor(0x0e1014).cgColor
        saveButton?.contentTintColor = .white
        saveButton?.isEnabled = false
        copyButton?.isEnabled = false
        cancelButton?.isEnabled = false
        textView.isEditable = false

        // Keep the window's dimensions fixed. Resizing an NSTextView reflows its
        // text mid-animation, which makes a successful save look like a typo.
        animateCardScale(
            from: 1,
            to: 1.015,
            duration: 0.12,
            timingFunction: CAMediaTimingFunction(name: .easeOut),
            key: "quickEntrySubmitGrow"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.animateCardScale(
                from: 1.015,
                to: 0.96,
                duration: 0.18,
                timingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                key: "quickEntrySubmitDismiss"
            )
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.window.animator().alphaValue = 0
            } completionHandler: {
                self.textView.isEditable = true
                self.window.orderOut(nil)
                self.window.alphaValue = 1
                self.resetCardTransform()
                if self.targetFrame != .zero {
                    self.window.setFrame(self.targetFrame, display: false)
                }
                AppLog.write("submit animation complete; panel closed")
            }
        }
    }

    @objc private func close() {
        guard !isPolishing else {
            AppLog.write("panel close blocked while polish is pending")
            rejectDismissal()
            return
        }

        AppLog.write("panel close requested")
        animateCardScale(
            from: 1,
            to: 0.97,
            duration: 0.12,
            timingFunction: CAMediaTimingFunction(name: .easeIn),
            key: "quickEntryCloseDismiss"
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.resetCardTransform()
            if self.targetFrame != .zero {
                self.window.setFrame(self.targetFrame, display: false)
            }
        }
    }

    private func rejectDismissal() {
        guard let layer = window.contentView?.layer else { return }

        let distance: CGFloat = 7
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -distance, distance, -distance * 0.65, distance * 0.65, 0]
        shake.keyTimes = [0, 0.18, 0.42, 0.62, 0.82, 1]
        shake.duration = 0.38
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(shake, forKey: "quickEntryDismissBlocked")
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isPolishing, window.isVisible else { return }
        AppLog.write("panel resigned key while polish is pending; keeping it visible")
        rejectDismissal()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isPolishing else { return }
        window.hidesOnDeactivate = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isPolishing else { return true }
        AppLog.write("window close blocked while polish is pending")
        rejectDismissal()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        AppLog.write("windowWillClose")
        window.orderOut(nil)
    }
}

final class QuickEntryTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTodoMode: (() -> Void)?
    var onWritingMode: (() -> Void)?
    var onContentChange: (() -> Void)?
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override var string: String {
        didSet {
            needsDisplay = true
            onContentChange?()
        }
    }

    func setPlaceholder(
        _ placeholder: String,
        animated: Bool = false,
        direction: ModeTextRollDirection = .up
    ) {
        guard placeholder != self.placeholder else { return }
        guard animated,
              string.isEmpty,
              window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer
        else {
            self.placeholder = placeholder
            return
        }

        addModePlaceholderReveal(to: layer, direction: direction)
        self.placeholder = placeholder
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: qColor(0x868d97, alpha: 0.72),
        ]
        let inset = textContainerInset
        let point = NSPoint(x: inset.width, y: inset.height + 1)
        (placeholder as NSString).draw(at: point, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onContentChange?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "[":
            onTodoMode?()
            return true
        case "]":
            onWritingMode?()
            return true
        case "v":
            paste(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "x":
            cut(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        AppLog.write("textView insertText replacementRange=\(replacementRange); type=\(type(of: insertString))")
        super.insertText(insertString, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        AppLog.write("textView paste invoked")
        super.paste(sender)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        let isCommandReturn = event.modifierFlags.contains(.command) && (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter))
        if isCommandReturn {
            onSave?()
            return
        }
        super.keyDown(with: event)
    }
}

enum QuickEntryStore {
    private static let caseRootURL: URL = {
        if let override = ProcessInfo.processInfo.environment["QUICK_ENTRY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let configuredTodoFile = ProcessInfo.processInfo.environment["QUICK_ENTRY_TODO_FILE"], !configuredTodoFile.isEmpty {
            return URL(fileURLWithPath: configuredTodoFile).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(QuickEntryConfiguration.defaultInboxDirectory)
    }()
    private static let hyperDRefreshInterval: TimeInterval = 30 * 60
    private static let inboxReviewRefreshInterval: TimeInterval = 15 * 60

    static func todoProcessingURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["QUICK_ENTRY_TODO_FILE"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return caseRootURL.appendingPathComponent(QuickEntryConfiguration.defaultInboxFileName)
    }

    static func stateOfTheUnionURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["QUICK_ENTRY_STATE_FILE"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return caseRootURL.appendingPathComponent("state-of-the-union.md")
    }

    static func hyperDCacheURL() -> URL {
        caseRootURL.appendingPathComponent(".cache/quick-entry-hyperd.json")
    }

    static func logbookURL() -> URL {
        caseRootURL.appendingPathComponent(".cache/quick-entry-logbook.json")
    }

    static func inboxReviewCacheURL() -> URL {
        caseRootURL.appendingPathComponent(".cache/quick-entry-inbox-review.json")
    }

    static func url(for source: TodoSource) -> URL {
        switch source {
        case .owing: return stateOfTheUnionURL()
        case .inbox: return todoProcessingURL()
        }
    }

    static func ensureTodoProcessingExists() {
        let url = todoProcessingURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            AppLog.write("creating todo-processing inbox at \(url.path)")
            let initial = "# To-do Inbox\n\nFast capture inbox. Use **Quick Entry** (`Ctrl+Space`, then `Cmd+Return`) from anywhere on the Mac to append here.\n\n## Inbox\n\n<!-- Add raw captures below. -->\n\n## Processed\n\n<!-- Move or summarize processed batches here with date/time when useful. -->\n"
            try? initial.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func todoItems() -> [TodoMenuEntry] {
        TodoSource.allCases.flatMap { todoItems(in: $0) }
    }

    static func actionableTodoItems() -> [TodoMenuEntry] {
        displayTodoItems(in: .owing) + displayTodoItems(in: .inbox)
    }

    static func displayTodoItems(in source: TodoSource) -> [TodoMenuEntry] {
        let items = todoItems(in: source)
        guard source == .inbox,
              let review = inboxReviewCache(),
              review.mode == "agent"
        else {
            return items
        }

        let reviewByID = Dictionary(uniqueKeysWithValues: review.items.map { ($0.id, $0) })
        return items.compactMap { item in
            guard !item.isDone else { return item }
            guard let reviewed = reviewByID[item.id] else { return item }
            guard reviewed.classification == "todo" else { return nil }
            return TodoMenuEntry(
                id: item.id,
                source: item.source,
                lineIndex: item.lineIndex,
                timestamp: item.timestamp,
                text: reviewed.text,
                isDone: item.isDone
            )
        }
    }

    static func todoItems(in source: TodoSource) -> [TodoMenuEntry] {
        if source == .inbox {
            ensureTodoProcessingExists()
        }
        let url = url(for: source)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)

        switch source {
        case .inbox:
            return parseInbox(lines)
        case .owing:
            return parseOwing(lines)
        }
    }

    static func openTodoCount() -> Int {
        actionableTodoItems().filter { !$0.isDone }.count
    }

    static func inboxNotesHeldCount() -> Int {
        guard let review = inboxReviewCache(), review.mode == "agent" else { return 0 }
        return review.nonActionableCount
    }

    static func todoStateFingerprint() -> String {
        let urls = [todoProcessingURL(), stateOfTheUnionURL(), hyperDCacheURL(), logbookURL(), inboxReviewCacheURL()]
        return urls.map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return "\(url.lastPathComponent):\(date):\(size)"
        }.joined(separator: "|")
    }

    static func hyperDNeedsRefresh() -> Bool {
        let url = hyperDCacheURL()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return true
        }
        return Date().timeIntervalSince(modified) >= hyperDRefreshInterval
    }

    static func inboxReviewNeedsRefresh() -> Bool {
        let cacheURL = inboxReviewCacheURL()
        guard let cacheAttributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let cacheModified = cacheAttributes[.modificationDate] as? Date
        else {
            return true
        }
        let inboxModified = ((try? FileManager.default.attributesOfItem(atPath: todoProcessingURL().path))?[.modificationDate] as? Date) ?? .distantPast
        return inboxModified > cacheModified || Date().timeIntervalSince(cacheModified) >= inboxReviewRefreshInterval
    }

    static func hyperDTodos() -> [HyperDTodoEntry] {
        let activeTodos = actionableTodoItems().filter { !$0.isDone }
        let todosByID = Dictionary(uniqueKeysWithValues: activeTodos.map { ($0.id, $0) })

        guard let cache = hyperDCache() else {
            return activeTodos.prefix(3).map { todo in
                HyperDTodoEntry(
                    todo: todo,
                    why: todo.source == .owing ? "Active Owing item" : "Unprocessed inbox capture"
                )
            }
        }

        let matched = cache.items.compactMap { recommendation -> HyperDTodoEntry? in
            guard let todo = todosByID[recommendation.id] else { return nil }
            return HyperDTodoEntry(todo: todo, why: recommendation.why)
        }
        if !matched.isEmpty {
            return matched
        }
        return activeTodos.prefix(3).map { todo in
            HyperDTodoEntry(
                todo: todo,
                why: todo.source == .owing ? "Active Owing item" : "Unprocessed inbox capture"
            )
        }
    }

    static func hyperDStatusText() -> String {
        guard let cache = hyperDCache() else { return "No radar yet" }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: cache.generatedAt) else {
            return cache.mode == "agent" ? "Agent-ranked" : "Local fallback"
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let age: String
        switch seconds {
        case ..<60: age = "now"
        case ..<3_600: age = "\(max(1, seconds / 60))m ago"
        default: age = "\(seconds / 3_600)h ago"
        }
        return cache.mode == "agent" ? "Radar · \(age)" : "Fallback · \(age)"
    }

    static func todayUpdatedText() -> String {
        guard let cache = hyperDCache(), let date = ISO8601DateFormatter().date(from: cache.generatedAt) else {
            return "Updated recently"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mma"
        } else {
            formatter.dateFormat = "MMM d, h:mma"
        }
        return "Updated \(formatter.string(from: date).lowercased())"
    }

    static func refreshInboxReview(completion: @escaping (Bool) -> Void) {
        guard let scriptURL = inboxReviewScriptURL() else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["QUICK_ENTRY_ROOT"] = caseRootURL.path
            environment["PATH"] = "/Users/jasonhuff/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let error = Pipe()
            process.standardError = error
            process.standardOutput = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let succeeded = process.terminationStatus == 0
                if !succeeded {
                    let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
                    AppLog.write("Inbox review failed: \(errorText.prefix(300))")
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .caseInboxReviewChanged, object: nil)
                    completion(succeeded)
                }
            } catch {
                AppLog.write("Could not launch inbox review: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    static func refreshHyperDTodos(completion: @escaping (Bool) -> Void) {
        guard let scriptURL = hyperDRefreshScriptURL() else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["QUICK_ENTRY_ROOT"] = caseRootURL.path
            environment["PATH"] = "/Users/jasonhuff/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let error = Pipe()
            process.standardError = error
            process.standardOutput = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let succeeded = process.terminationStatus == 0
                if !succeeded {
                    let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
                    AppLog.write("HyperD refresh failed: \(errorText.prefix(300))")
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .caseHyperDTodosChanged, object: nil)
                    completion(succeeded)
                }
            } catch {
                AppLog.write("Could not launch HyperD refresh: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    static func completeTodo(_ todo: TodoMenuEntry) throws -> TodoLogbookEntry {
        if todo.source == .inbox {
            ensureTodoProcessingExists()
        }
        let current = todoItems(in: todo.source)
        guard let currentTodo = current.first(where: { $0.id == todo.id }), !currentTodo.isDone else {
            throw todoChangedError()
        }

        let url = url(for: todo.source)
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)
        guard lines.indices.contains(currentTodo.lineIndex) else { throw todoChangedError() }
        guard let range = lines[currentTodo.lineIndex].range(of: "- [ ] ") else {
            throw todoChangedError()
        }
        lines[currentTodo.lineIndex].replaceSubrange(range, with: "- [x] ")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let entry = TodoLogbookEntry(
            id: UUID().uuidString,
            completedAt: isoTimestamp(),
            todoID: currentTodo.id,
            source: currentTodo.source,
            text: todo.text,
            timestamp: currentTodo.timestamp,
            restoredAt: nil
        )
        try appendLogbook(entry)
        return entry
    }

    static func logbookEntries() -> [TodoLogbookEntry] {
        loadLogbookEntries()
            .filter { $0.restoredAt == nil }
            .sorted { $0.completedAt > $1.completedAt }
    }

    static func restoreLogbookEntry(_ entry: TodoLogbookEntry) throws {
        let current = todoItems(in: entry.source)
        guard let todo = current.first(where: { $0.id == entry.todoID }) ?? current.first(where: { $0.text == entry.text && $0.isDone }) else {
            throw todoChangedError()
        }

        let url = url(for: entry.source)
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)
        guard lines.indices.contains(todo.lineIndex) else { throw todoChangedError() }
        if let range = lines[todo.lineIndex].range(of: "- [x] ") {
            lines[todo.lineIndex].replaceSubrange(range, with: "- [ ] ")
        } else if let range = lines[todo.lineIndex].range(of: "- [X] ") {
            lines[todo.lineIndex].replaceSubrange(range, with: "- [ ] ")
        } else {
            throw todoChangedError()
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        var entries = loadLogbookEntries()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].restoredAt = isoTimestamp()
            try writeLogbook(entries)
        }
    }

    static func append(_ note: String) throws {
        let url = todoProcessingURL()
        AppLog.write("append requested to \(url.path); noteLength=\(note.count)")
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var content: String
        if FileManager.default.fileExists(atPath: url.path) {
            content = try String(contentsOf: url, encoding: .utf8)
        } else {
            content = "# Todo Processing\n"
        }

        if !content.contains("\n## Inbox") && !content.hasPrefix("## Inbox") {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n## Inbox\n"
        }

        if !content.contains("\n## Processed") {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n## Processed\n"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let time = timeFormatter.string(from: Date())
        let checkboxText = note.replacingOccurrences(of: "\n", with: "\n  ")
        let entry = "\n### \(time)\n- [ ] \(checkboxText)\n"

        if let processedRange = content.range(of: "\n## Processed") {
            content.insert(contentsOf: entry, at: processedRange.lowerBound)
        } else {
            if !content.hasSuffix("\n") { content += "\n" }
            content += entry
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .caseTodosChanged, object: nil)
        AppLog.write("append wrote inbox successfully")
    }

    private static func parseInbox(_ lines: [String]) -> [TodoMenuEntry] {
        var items: [TodoMenuEntry] = []
        var inInbox = false
        var currentTimestamp: String?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Inbox" {
                inInbox = true
                continue
            }
            if trimmed == "## Processed" {
                break
            }
            guard inInbox else { continue }

            if line.hasPrefix("### ") {
                currentTimestamp = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let item = todoEntry(from: line, index: index, source: .inbox, timestamp: currentTimestamp) {
                items.append(item)
            }
        }
        return items
    }

    private static func parseOwing(_ lines: [String]) -> [TodoMenuEntry] {
        var items: [TodoMenuEntry] = []
        var inOwing = false
        var currentHeading: String?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Owing" {
                inOwing = true
                continue
            }
            guard inOwing else { continue }
            if trimmed.hasPrefix("## ") {
                break
            }
            if trimmed.hasPrefix("### ") {
                currentHeading = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("- **"), trimmed.hasSuffix("**"), !trimmed.contains(":**") {
                currentHeading = String(trimmed.dropFirst(4).dropLast(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("- [") {
                currentHeading = nil
            }
            if let item = todoEntry(from: line, index: index, source: .owing, timestamp: currentHeading) {
                items.append(item)
            }
        }
        return items
    }

    private static func todoEntry(
        from line: String,
        index: Int,
        source: TodoSource,
        timestamp: String?
    ) -> TodoMenuEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isOpen = trimmed.hasPrefix("- [ ] ")
        let isDone = trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ")
        guard isOpen || isDone else { return nil }
        let text = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return TodoMenuEntry(
            id: stableID(source: source, text: text),
            source: source,
            lineIndex: index,
            timestamp: timestamp,
            text: text,
            isDone: isDone
        )
    }

    private static func stableID(source: TodoSource, text: String) -> String {
        let normalized = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let digest = SHA256.hash(data: Data("\(source.rawValue)|\(normalized)".utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(source.rawValue):\(hash)"
    }

    private static func hyperDCache() -> HyperDTodoCache? {
        let url = hyperDCacheURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HyperDTodoCache.self, from: data)
    }

    private static func inboxReviewCache() -> InboxReviewCache? {
        let url = inboxReviewCacheURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InboxReviewCache.self, from: data)
    }

    private static func inboxReviewScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "preprocess-inbox", withExtension: "py") {
            return bundled
        }
        let development = caseRootURL.appendingPathComponent("tools/QuickEntry/preprocess-inbox.py")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static func hyperDRefreshScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "refresh-hyperd-todos", withExtension: "py") {
            return bundled
        }
        let development = caseRootURL.appendingPathComponent("tools/QuickEntry/refresh-hyperd-todos.py")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static func loadLogbookEntries() -> [TodoLogbookEntry] {
        guard let data = try? Data(contentsOf: logbookURL()) else { return [] }
        return (try? JSONDecoder().decode([TodoLogbookEntry].self, from: data)) ?? []
    }

    private static func appendLogbook(_ entry: TodoLogbookEntry) throws {
        var entries = loadLogbookEntries()
        entries.append(entry)
        // Keep a generous local audit trail without allowing an accidental click
        // history to turn into a second task database.
        if entries.count > 1_000 {
            entries.removeFirst(entries.count - 1_000)
        }
        try writeLogbook(entries)
    }

    private static func writeLogbook(_ entries: [TodoLogbookEntry]) throws {
        let url = logbookURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: Date())
    }

    private static func todoChangedError() -> NSError {
        NSError(
            domain: "QuickEntry",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "That to-do changed. Reopen the list and try again."]
        )
    }
}

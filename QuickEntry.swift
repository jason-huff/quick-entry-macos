import AppKit
import Carbon.HIToolbox
import QuartzCore

private let appName = "Quick Entry"
private let hotKeyDescription = "⌃Space"
private let hotKeyID = EventHotKeyID(signature: OSType(0x51454E54), id: 1) // QENT
private let modeContentTransitionDuration: CFTimeInterval = 0.22

private enum QuickEntryConfiguration {
    static let launchAgentLabel = "io.github.jasonhuff.quick-entry"
    static let defaultInboxDirectory = "QuickEntry"
    static let defaultInboxFileName = "todo-processing.md"
}

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

struct TodoMenuEntry {
    let lineIndex: Int
    let timestamp: String?
    let text: String
    let isDone: Bool
}

private extension Notification.Name {
    static let quickEntryTodosChanged = Notification.Name("QuickEntryTodosChanged")
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
    private var todoPopover: NSPopover?
    private var todoPopoverController: TodoPopoverController?
    private var todoEscapeMonitor: Any?

    private var isTodoCompanion: Bool {
        ProcessInfo.processInfo.arguments.contains("--todos-only") ||
            Bundle.main.bundleIdentifier == "io.github.jasonhuff.quick-entry.todos"
    }

    private var embeddedTodoMenuEnabled: Bool {
        // The optional companion owns the to-do surface. Only show the legacy
        // embedded menu when the launch agent explicitly requests it, so a
        // direct/Spotlight launch cannot create a second checklist icon.
        ProcessInfo.processInfo.environment["QUICK_ENTRY_TODOS"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching; launchedByLaunchAgent=\(launchedByLaunchAgent); XPC_SERVICE_NAME=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "nil")")
        NSApp.setActivationPolicy(.accessory)
        if isTodoCompanion {
            setupStatusItem()
            AppLog.write("todo companion launch detected; staying in menu bar")
            return
        }

        setupAppleEventHandlers()
        if embeddedTodoMenuEnabled {
            setupStatusItem()
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.toolTip = "\(appName) — \(hotKeyDescription)"

        item.button?.target = self
        item.button?.action = #selector(toggleTodoPopover)
        statusItem = item
        updateStatusTitle()

        NotificationCenter.default.addObserver(forName: .quickEntryTodosChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatusTitle()
            self?.todoPopoverController?.rebuild()
        }
    }

    @objc private func toggleTodoPopover() {
        guard let button = statusItem?.button else { return }
        if let todoPopover, todoPopover.isShown {
            closeTodoPopover()
            return
        }

        let controller = TodoPopoverController(
            onQuickEntry: { [weak self] in
                self?.closeTodoPopover()
                self?.openQuickEntry()
            },
            onReveal: { [weak self] in
                self?.closeTodoPopover()
                self?.revealTodoInbox()
            },
            onQuit: { [weak self] in
                self?.closeTodoPopover()
                self?.quit()
            },
            onToggle: { [weak self] lineIndex in
                self?.toggleTodoFromPopover(atLineIndex: lineIndex)
            },
            showsQuickEntryAction: !isTodoCompanion
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = controller
        todoPopover = popover
        todoPopoverController = controller
        AppLog.write("showing todo popover")
        installTodoEscapeMonitor()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closeTodoPopover() {
        todoPopover?.performClose(nil)
        removeTodoEscapeMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        removeTodoEscapeMonitor()
    }

    private func installTodoEscapeMonitor() {
        removeTodoEscapeMonitor()
        todoEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape), self?.todoPopover?.isShown == true {
                self?.closeTodoPopover()
                return nil
            }
            return event
        }
    }

    private func removeTodoEscapeMonitor() {
        if let todoEscapeMonitor {
            NSEvent.removeMonitor(todoEscapeMonitor)
            self.todoEscapeMonitor = nil
        }
    }

    private func updateStatusTitle() {
        statusItem?.button?.image = nil
        statusItem?.button?.imagePosition = .noImage
        if isTodoCompanion {
            statusItem?.button?.title = "☑︎"
            statusItem?.button?.font = .systemFont(ofSize: 16, weight: .medium)
            statusItem?.button?.contentTintColor = .labelColor
            statusItem?.button?.toolTip = "Quick Entry To-dos — \(QuickEntryStore.openTodoCount()) open"
        } else {
            statusItem?.button?.title = "Quick"
            statusItem?.button?.toolTip = "\(appName) — \(hotKeyDescription)"
        }
        statusItem?.length = NSStatusItem.variableLength
    }

    private func toggleTodoFromPopover(atLineIndex lineIndex: Int) {
        do {
            try QuickEntryStore.toggleTodo(atLineIndex: lineIndex)
            AppLog.write("toggled todo at lineIndex=\(lineIndex)")
            updateStatusTitle()
            todoPopoverController?.rebuild()
        } catch {
            AppLog.write("failed toggling todo at lineIndex=\(lineIndex): \(error.localizedDescription)")
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

    @objc private func revealTodoInbox() {
        let url = QuickEntryStore.todoProcessingURL()
        AppLog.write("revealTodoInbox url=\(url.path)")
        QuickEntryStore.ensureTodoProcessingExists()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        AppLog.write("quit selected")
        NSApp.terminate(nil)
    }
}

final class TodoPopoverController: NSViewController {
    private let onQuickEntry: () -> Void
    private let onReveal: () -> Void
    private let onQuit: () -> Void
    private let onToggle: (Int) -> Void
    private let showsQuickEntryAction: Bool
    private let stack = NSStackView()

    init(
        onQuickEntry: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onToggle: @escaping (Int) -> Void,
        showsQuickEntryAction: Bool
    ) {
        self.onQuickEntry = onQuickEntry
        self.onReveal = onReveal
        self.onQuit = onQuit
        self.onToggle = onToggle
        self.showsQuickEntryAction = showsQuickEntryAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 420))
        view.wantsLayer = true
        view.layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        rebuild()
    }

    func rebuild() {
        guard isViewLoaded else { return }
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let openTodos = QuickEntryStore.todoItems().filter { !$0.isDone }
        add(QuickEntryMenuHeaderView(openTodoCount: openTodos.count))
        if showsQuickEntryAction {
            add(QuickEntryMenuActionView(title: "Quick Entry", detail: hotKeyDescription, icon: "✎", onPress: onQuickEntry))
        }
        add(QuickEntryMenuSectionView(title: openTodos.isEmpty ? "Today" : "Today"))

        if openTodos.isEmpty {
            add(QuickEntryMenuEmptyView())
        } else {
            for todo in openTodos.prefix(12) {
                add(QuickEntryTodoRowView(todo: todo, onToggle: onToggle))
            }
            if openTodos.count > 12 {
                add(QuickEntryMenuSectionView(title: "\(openTodos.count - 12) more in todo-processing.md"))
            }
        }

        add(QuickEntryMenuActionView(title: "Reveal Todo Inbox", detail: "Markdown", icon: "⌘", onPress: onReveal))

        let quickEntryActionHeight = showsQuickEntryAction ? 34 : 0
        let height = 48 + quickEntryActionHeight + 28 + (openTodos.isEmpty ? 42 : min(openTodos.count, 12) * 39) + (openTodos.count > 12 ? 28 : 0) + 34
        preferredContentSize = NSSize(width: 344, height: min(max(height, 220), 620))
        view.setFrameSize(preferredContentSize)
    }

    private func add(_ arranged: NSView) {
        stack.addArrangedSubview(arranged)
        arranged.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        arranged.heightAnchor.constraint(equalToConstant: arranged.frame.height).isActive = true
    }
}

final class QuickEntryMenuHeaderView: NSView {
    init(openTodoCount: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 48))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let title = NSTextField(labelWithString: "Quick Entry")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = qColor(0x1f2329)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitleText = openTodoCount == 0 ? "No open TODOs" : "\(openTodoCount) open TODO\(openTodoCount == 1 ? "" : "s")"
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = qColor(0x8d949e)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class QuickEntryMenuSectionView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 28))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = qColor(0x4d535c)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class QuickEntryMenuEmptyView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 42))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let label = NSTextField(labelWithString: "Nothing waiting. Nice.")
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

final class QuickEntryMenuActionView: NSView {
    private let onPress: () -> Void

    init(title: String, detail: String, icon: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 34))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let iconView = NSTextField(labelWithString: icon)
        iconView.font = .systemFont(ofSize: 12, weight: .medium)
        iconView.alignment = .center
        iconView.textColor = qColor(0x8d949e)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleView = NSTextField(labelWithString: title)
        titleView.font = .systemFont(ofSize: 12, weight: .medium)
        titleView.textColor = qColor(0x333840)
        titleView.translatesAutoresizingMaskIntoConstraints = false

        let detailView = NSTextField(labelWithString: detail)
        detailView.font = .systemFont(ofSize: 11, weight: .medium)
        detailView.textColor = qColor(0x8d949e)
        detailView.alignment = .right
        detailView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleView)
        addSubview(detailView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 43),
            titleView.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailView.leadingAnchor.constraint(greaterThanOrEqualTo: titleView.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        animatePress()
        onPress()
    }

    private func animatePress() {
        layer?.backgroundColor = qColor(0xf1f3f6).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.layer?.backgroundColor = qColor(0xfbfbfc).cgColor
        }
    }
}

final class QuickEntryCheckboxView: NSView {
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
        (checked ? qColor(0x2d7a4a) : qColor(0xfbfbfc)).setFill()
        path.fill()
        (checked ? qColor(0x2d7a4a) : qColor(0xcfd5df)).setStroke()
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

final class QuickEntryTodoRowView: NSView {
    private let todo: TodoMenuEntry
    private let onToggle: (Int) -> Void
    private let checkbox = QuickEntryCheckboxView()

    init(todo: TodoMenuEntry, onToggle: @escaping (Int) -> Void) {
        self.todo = todo
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 39))
        wantsLayer = true
        layer?.backgroundColor = qColor(0xfbfbfc).cgColor

        let title = NSTextField(labelWithString: clean(todo.text, limit: 58))
        title.font = .systemFont(ofSize: 12, weight: .regular)
        title.textColor = qColor(0x20242a)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let timeText = todo.timestamp.map { Self.displayTimestamp($0) } ?? "Inbox"
        let note = NSTextField(labelWithString: timeText)
        note.font = .systemFont(ofSize: 10, weight: .regular)
        note.textColor = qColor(0xa0a7b0)
        note.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = qColor(0xe8ebef).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkbox)
        addSubview(title)
        addSubview(note)
        addSubview(separator)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 14),
            checkbox.heightAnchor.constraint(equalToConstant: 14),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 43),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: -1),

            separator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = qColor(0xf1f3f6).cgColor
        checkbox.checked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self else { return }
            self.onToggle(self.todo.lineIndex)
        }
    }

    private static func displayTimestamp(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm"

        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d h:mma"
        return formatter.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    private func clean(_ input: String, limit: Int) -> String {
        var text = input.replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        if text.count > limit {
            let end = text.index(text.startIndex, offsetBy: limit)
            text = String(text[..<end]) + "…"
        }
        return text
    }
}

final class QuickEntrySpinnerView: NSView {
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

    func startAnimating() {
        isHidden = false
        updatePath()
        guard arcLayer.animation(forKey: "quickEntrySpin") == nil else { return }

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        arcLayer.add(animation, forKey: "quickEntrySpin")
    }

    func stopAnimating() {
        arcLayer.removeAnimation(forKey: "quickEntrySpin")
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

final class QuickEntryPassiveButtonTitleLabel: NSTextField {
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

final class QuickEntryRollingActionButton: NSButton {
    private let titleLabel = QuickEntryPassiveButtonTitleLabel()
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
            key: "quickEntryActionTitleRoll",
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
        titleLabel.layer?.removeAnimation(forKey: "quickEntryActionTitleRoll")
        titleLabel.alphaValue = currentActionTitle.isEmpty ? 0 : 1
        titleLabel.frame = titleFrame
    }
}

final class QuickEntryShimmerLabel: NSTextField {
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
        gradient.add(animation, forKey: "quickEntryTextShimmer")
    }

    func stopShimmer(restoreTextColor: Bool = true) {
        gradientLayer?.removeAnimation(forKey: "quickEntryTextShimmer")
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
            key: "quickEntryStatusTextRoll",
            subtype: direction.fieldSubtype
        )
        stringValue = text
    }

    private func updateShimmerFrames() {
        gradientLayer?.frame = bounds
        textMaskLayer?.frame = bounds
    }
}

final class QuickEntryModeTabs: NSView {
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

        configure(todoButton, label: "Todo mode", identifier: "QuickEntryModeTodo")
        configure(writingButton, label: "Writing mode", identifier: "QuickEntryModeWriting")
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
        activePill.removeAnimation(forKey: "quickEntryModeTabSlide")
        activePill.removeAnimation(forKey: "quickEntryModeTabImpact")
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
            activePill.add(slide, forKey: "quickEntryModeTabSlide")
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
        activePill.add(slide, forKey: "quickEntryModeTabSlide")

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
        activePill.add(impact, forKey: "quickEntryModeTabImpact")
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

final class QuickEntryTextInputEdgeFade: NSView {
    enum Edge {
        case top
        case bottom
    }

    private let edge: Edge

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let opaque = qColor(0xffffff, alpha: 0.92)
        let gradient: NSGradient
        switch edge {
        case .top:
            gradient = NSGradient(starting: opaque, ending: qColor(0xffffff, alpha: 0))!
        case .bottom:
            gradient = NSGradient(starting: qColor(0xffffff, alpha: 0), ending: opaque)!
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

final class QuickEntryPanelController: NSObject, NSWindowDelegate {
    private enum EntryMode {
        case todo
        case writing
    }

    private let window: NSPanel
    private let textView: QuickEntryTextView
    private let statusLabel: QuickEntryShimmerLabel
    private var card: NSView?
    private var textScroll: NSScrollView?
    private var topTextInputFade: QuickEntryTextInputEdgeFade?
    private var bottomTextInputFade: QuickEntryTextInputEdgeFade?
    private let textInputFadeHeight: CGFloat = 14
    private var textScrollBoundsObserver: NSObjectProtocol?
    private var isTextInputFadeUpdateScheduled = false
    private var saveButton: QuickEntryRollingActionButton?
    private var copyButton: NSButton?
    private var modeTabs: QuickEntryModeTabs?
    private var cancelButton: NSButton?
    private var polishSpinner: QuickEntrySpinnerView?
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
        statusLabel = QuickEntryShimmerLabel(text: "⌘↩ save · esc cancel")
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

        let modeTabs = QuickEntryModeTabs(frame: .zero)
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

        let topTextInputFade = QuickEntryTextInputEdgeFade(edge: .top)
        let bottomTextInputFade = QuickEntryTextInputEdgeFade(edge: .bottom)
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
        textView.setAccessibilityIdentifier("QuickEntryInput")
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

        let saveButton = QuickEntryRollingActionButton(frame: .zero)
        saveButton.target = self
        saveButton.action = #selector(primaryAction)
        configureButton(saveButton, background: qColor(0x0e1014), text: .white)
        saveButton.setActionTitle("Save")
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        self.saveButton = saveButton

        let polishSpinner = QuickEntrySpinnerView(frame: .zero)
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

    private func selectModeFromShortcut(_ selection: QuickEntryModeTabs.Selection) {
        guard !isPolishing else { return }
        selectMode(selection)
    }

    private func selectMode(_ selection: QuickEntryModeTabs.Selection) {
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
            statusText = "Timestamped. Saved to your local inbox."
            placeholder = "Drop the thing before it evaporates…"
            rollDirection = .down
        case .writing:
            actionTitle = "Polish"
            statusText = "Brain dump. Polish for Slack."
            placeholder = "Brain dump or dictate a rough draft…"
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
            saveButton.layer?.add(press, forKey: "quickEntryPolishPress")

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
            self.textView.layer?.add(transition, forKey: "quickEntryPolishedTextFade")

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

        guard let scriptURL = Bundle.main.url(forResource: "polish-writing", withExtension: "sh") else {
            AppLog.write("polish launch failed: bundled polish-writing.sh is missing")
            isPolishing = false
            setPolishLoading(false)
            textView.isEditable = true
            saveButton?.isEnabled = true
            modeTabs?.setEnabled(true)
            applyMode()
            NSSound.beep()
            statusLabel.stringValue = "could not find polish script"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["QUICK_ENTRY_APP_RESOURCES"] = Bundle.main.resourceURL?.path
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(inheritedPath)"
        process.environment = environment

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
    static func todoProcessingURL() -> URL {
        if let configuredPath = ProcessInfo.processInfo.environment["QUICK_ENTRY_TODO_FILE"],
           !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(QuickEntryConfiguration.defaultInboxDirectory)
            .appendingPathComponent(QuickEntryConfiguration.defaultInboxFileName)
    }

    static func ensureTodoProcessingExists() {
        let url = todoProcessingURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            AppLog.write("creating todo-processing inbox at \(url.path)")
            let initial = "# Todo Processing\n\nQuick Entry captures land here. Use **Ctrl+Space**, write a note, then press **Cmd+Return** to save it.\n\n## Inbox\n\n<!-- New captures land below. Process, move, or delete them however you prefer. -->\n\n## Processed\n\n<!-- Move completed or processed items here if useful. -->\n"
            try? initial.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func todoItems() -> [TodoMenuEntry] {
        ensureTodoProcessingExists()
        let url = todoProcessingURL()
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)
        var items: [TodoMenuEntry] = []
        var inInbox = false
        var currentTimestamp: String?

        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "## Inbox" {
                inInbox = true
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "## Processed" {
                inInbox = false
                continue
            }
            guard inInbox else { continue }

            if line.hasPrefix("### ") {
                currentTimestamp = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let isDone = trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ")
                let text = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                items.append(TodoMenuEntry(lineIndex: index, timestamp: currentTimestamp, text: text, isDone: isDone))
            }
        }

        return items
    }

    static func openTodoCount() -> Int {
        todoItems().filter { !$0.isDone }.count
    }

    static func toggleTodo(atLineIndex lineIndex: Int) throws {
        ensureTodoProcessingExists()
        let url = todoProcessingURL()
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)
        guard lines.indices.contains(lineIndex) else { return }

        let line = lines[lineIndex]
        if line.contains("- [ ] ") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [ ] ", with: "- [x] ", options: [], range: line.range(of: "- [ ] "))
        } else if line.contains("- [x] ") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [x] ", with: "- [ ] ", options: [], range: line.range(of: "- [x] "))
        } else if line.contains("- [X] ") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [X] ", with: "- [ ] ", options: [], range: line.range(of: "- [X] "))
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .quickEntryTodosChanged, object: nil)
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
        NotificationCenter.default.post(name: .quickEntryTodosChanged, object: nil)
        AppLog.write("append wrote inbox successfully")
    }
}

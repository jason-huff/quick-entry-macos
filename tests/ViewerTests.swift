// Compiled with QuickEntry.swift by run-tests.py. Uses disposable Markdown only.
@main
struct ViewerTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_ROOT"]!)
        QuickEntryStore.ensureTodoProcessingExists()
        try "# State\n\n## Owing\n- [ ] Review the release\n\n## Done\n".write(to: QuickEntryStore.stateOfTheUnionURL(), atomically: true, encoding: .utf8)
        try QuickEntryStore.append("Read the brief: https://example.com/brief")
        let task = QuickEntryStore.todoItems(in: .inbox).first!
        let before = try String(contentsOf: QuickEntryStore.todoProcessingURL(), encoding: .utf8)
        let parsed = firstURLAndTitle(task.text)
        precondition(parsed.title == "Read the brief.")
        precondition(parsed.url?.absoluteString == "https://example.com/brief")
        precondition(firstURLAndTitle("No link here").title == "No link here")
        let sourced = firstURLAndTitle("Review the brief. Source: https://example.com/brief")
        precondition(sourced.title == "Review the brief.")
        let markdown = firstURLAndTitle("Read [the brief](https://example.com/brief)")
        precondition(markdown.title == "Read the brief")
        precondition(markdown.url?.absoluteString == "https://example.com/brief")
        let parenthesized = firstURLAndTitle("Read the brief (https://example.com/brief)")
        precondition(parenthesized.title == "Read the brief")
        let afterPresentation = try String(contentsOf: QuickEntryStore.todoProcessingURL(), encoding: .utf8)
        precondition(afterPresentation == before)
        let entry = try QuickEntryStore.completeTodo(task)
        precondition(QuickEntryStore.todoItems(in: .inbox).first!.isDone)
        precondition(QuickEntryStore.logbookEntries().count == 1)
        try QuickEntryStore.restoreLogbookEntry(entry)
        precondition(!QuickEntryStore.todoItems(in: .inbox).first!.isDone)
        precondition(QuickEntryStore.logbookEntries().isEmpty)
        // Hiring stays in the same state file, with waiting context excluded.
        let hiringFixture = """
        ## Hiring — active
        ### Immediate outreach
        - [ ] Send portfolio screen
        - [x] Finished screen
        ### Active pipeline and sourcing
        - [ ] Review candidate feedback
        ### Waiting on recruiter / not owned yet
        - Recruiter is arranging an initial chat. Re-enter only if asked for an interview or decision. Source: https://example.com/recruiter/thread
        - [ ] Recruiter-owned follow-up, not an active task

        ## Owing
        ### Week of Sep 8 — immediate follow-through
          - [ ] Review the release. Source: https://example.com/release
        """
        let previousFingerprint = QuickEntryStore.todoStateFingerprint()
        try hiringFixture.write(to: QuickEntryStore.stateOfTheUnionURL(), atomically: true, encoding: .utf8)
        precondition(QuickEntryStore.todoStateFingerprint() != previousFingerprint)
        precondition(QuickEntryStore.hasHiringSection())
        let hiringTasks = QuickEntryStore.todoItems(in: .hiring)
        precondition(hiringTasks.filter { !$0.isDone }.count == 2)
        precondition(hiringTasks.first!.timestamp == "Immediate outreach")
        precondition(QuickEntryStore.todoItems(in: .owing).count == 1)
        precondition(QuickEntryStore.hiringWaitingNotes().count == 2)
        let hiringCompletion = try QuickEntryStore.completeTodo(hiringTasks.first!)
        precondition(QuickEntryStore.todoItems(in: .hiring).filter { !$0.isDone }.count == 1)
        try QuickEntryStore.restoreLogbookEntry(hiringCompletion)
        precondition(QuickEntryStore.todoItems(in: .hiring).filter { !$0.isDone }.count == 2)
        // Duplicate task text must not crash the Today lookup.
        try QuickEntryStore.append("Read the brief: https://example.com/brief")
        _ = QuickEntryStore.hyperDTodos()

        let controller = TodoPopoverController(onRevealSource: { _ in }, onToggle: { _ in }, onRestoreLogbook: { _ in }, onRefreshHyperD: {}, onPreferredSizeChange: { _ in })
        let view = controller.view
        view.layoutSubtreeIfNeeded()
        try render(view, to: root.appendingPathComponent("viewer.png"))
        let overviewActions = descendants(view).compactMap { $0 as? CASEMenuActionView }
        let hiringIndex = overviewActions.firstIndex { $0.accessibilityLabel() == "Hiring" }!
        let owingIndex = overviewActions.firstIndex { $0.accessibilityLabel() == "Owing" }!
        precondition(hiringIndex < owingIndex, "Hiring must precede Owing")
        controller.setHyperDRefreshState(true)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        try render(view, to: root.appendingPathComponent("loading.png"))

        let loading = descendants(view).compactMap { $0 as? CASEMenuLoadingView }.first!
        let labels = descendants(loading).compactMap { $0 as? NSTextField }
        let title = labels.first { $0.stringValue == "Ranking today’s work" }!
        let status = labels.first { $0.stringValue.contains("sec elapsed") }!
        let titleInk = title.convert(title.cell!.drawingRect(forBounds: title.bounds), to: loading)
        let statusInk = status.convert(status.cell!.drawingRect(forBounds: status.bounds), to: loading)
        precondition(abs(titleInk.minX - statusInk.minX) < 0.5, "Loading text ink must align")

        var opened = 0
        let button = CASELinkButton { opened += 1 }
        button.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        button.layoutSubtreeIfNeeded()
        precondition(button.hitTest(NSPoint(x: 15, y: 15)) === button)
        precondition(button.accessibilityPerformPress())
        precondition(opened == 1)

        for text in ["Short task", "Review a reasonably long task title that should wrap naturally without reserving a blank line: https://example.com/path"] {
            let item = TodoMenuEntry(id: text, source: .inbox, lineIndex: 0, timestamp: nil, text: text, isDone: false)
            let row = CASETodoRowView(todo: item, detail: "Due tomorrow", onToggle: { _ in })
            row.layoutSubtreeIfNeeded()
            let field = row.subviews.compactMap { $0 as? NSTextField }.first!
            let width = TodoLayout.titleWidth(hasLink: text.contains("https://"))
            precondition(abs(field.alignmentRect(forFrame: field.frame).width - width) < 0.5)
            let requiredHeight = ceil(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)).height)
            precondition(abs(field.frame.height - requiredHeight) < 0.5)
        }
        let hiringAction = descendants(view).compactMap { $0 as? CASEMenuActionView }.first { $0.accessibilityLabel() == "Hiring" }!
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        hiringAction.mouseDown(with: click)
        view.layoutSubtreeIfNeeded()
        precondition(descendants(view).compactMap { $0 as? CASEContextRowView }.count == 2)
        precondition(descendants(view).compactMap { $0 as? CASETodoRowView }.count == 2)
        try render(view, to: root.appendingPathComponent("hiring.png"))
        let stateBeforeBrowsing = try String(contentsOf: QuickEntryStore.stateOfTheUnionURL(), encoding: .utf8)
        let inboxBeforeBrowsing = try String(contentsOf: QuickEntryStore.todoProcessingURL(), encoding: .utf8)
        func goBack() {
            let back = descendants(view).compactMap { $0 as? CASEHeaderActionView }.first { $0.accessibilityLabel() == "Back to Today" }!
            precondition(back.accessibilityPerformPress())
            view.layoutSubtreeIfNeeded()
        }
        func openSection(_ name: String) {
            let action = descendants(view).compactMap { $0 as? CASEMenuActionView }.first { $0.accessibilityLabel() == name }!
            action.mouseDown(with: click)
            view.layoutSubtreeIfNeeded()
        }
        func verifyHeader() {
            let header = descendants(view).compactMap { $0 as? CASEMenuHeaderView }.first!
            let fields = header.subviews.compactMap { $0 as? NSTextField }
            precondition(abs(fields[0].alignmentRect(forFrame: fields[0].frame).minX - TodoLayout.titleLeading) < 0.5)
            precondition(abs(fields[0].frame.minX - fields[1].frame.minX) < 0.5)
            let back = header.subviews.compactMap { $0 as? CASEHeaderActionView }.first!
            let symbol = back.subviews.compactMap { $0 as? NSImageView }.first!
            precondition(symbol.image != nil)
            let symbolAlignment = symbol.alignmentRect(forFrame: symbol.frame)
            precondition(abs(symbolAlignment.midX - back.bounds.midX) < 0.5)
            precondition(abs(symbolAlignment.midY - back.bounds.midY) < 0.5)
            precondition(abs(back.frame.midY - header.bounds.midY) < 0.5)
            precondition(header.frame.height == 56)
            for label in descendants(view).compactMap({ $0 as? NSTextField }) {
                precondition(!label.stringValue.contains("https://"), "Unpackaged URL in \(label.stringValue)")
            }
        }
        verifyHeader()
        let contexts = descendants(view).compactMap { $0 as? CASEContextRowView }
        precondition(descendants(contexts[0]).contains { $0 is CASELinkButton })
        goBack()
        for name in ["Owing", "Inbox", "Logbook"] {
            openSection(name)
            verifyHeader()
            try render(view, to: root.appendingPathComponent(name.lowercased() + ".png"))
            goBack()
        }
        let stateAfterBrowsing = try String(contentsOf: QuickEntryStore.stateOfTheUnionURL(), encoding: .utf8)
        let inboxAfterBrowsing = try String(contentsOf: QuickEntryStore.todoProcessingURL(), encoding: .utf8)
        precondition(stateAfterBrowsing == stateBeforeBrowsing)
        precondition(inboxAfterBrowsing == inboxBeforeBrowsing)
        _ = try QuickEntryStore.completeTodo(QuickEntryStore.todoItems(in: .owing).first!)
        controller.rebuild()
        openSection("Logbook")
        verifyHeader()
        precondition(descendants(view).contains { $0 is CASELinkButton })
        try render(view, to: root.appendingPathComponent("logbook-populated.png"))
        goBack()
        try "## Owing\n".write(to: QuickEntryStore.stateOfTheUnionURL(), atomically: true, encoding: .utf8)
        openSection("Owing")
        verifyHeader()
        precondition(view.frame.height < 180, "Empty source view reserves unnecessary blank space")
        try render(view, to: root.appendingPathComponent("owing-empty.png"))
        print("PASS: source preservation, completion/restore, duplicate lookup, link action isolation, title sizing, loading ink alignment, Hiring order/sections/waiting/refresh, all section headers/back controls, context and Logbook links, compact empty states")
        print("Snapshots: \(root.path)")
    }

    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    static func render(_ view: NSView, to url: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

import AppKit
import PDFKit
import CoreText

func fixturePDF(at url: URL, title: String, pages: Int = 3) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextAuthor: "PaperShelf sample"] as CFDictionary) else { throw ShelfError.message("Could not create fixture") }
    for i in 0..<pages {
        context.beginPDFPage(nil)
        func line(_ text: String, x: CGFloat = 58, y: CGFloat, size: CGFloat = 12, color: NSColor = .black) {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), context)
        }
        line("P A P E R S H E L F   /   R E A D I N G   R O O M", y: 734, size: 9, color: .systemTeal)
        line(title, y: 676, size: 23)
        line("A sample document · Page \(i + 1)", y: 646, size: 11, color: .gray)
        line("Make room for the ideas that matter.", y: 588, size: 17)
        let lines = ["This is a demonstration PDF, not a research paper.", "Select a sentence and press Highlight to keep a passage.", "Add a margin note to capture a question or a connection.", "Your annotations are saved in a portable PDF on your Mac.", "", "Use collections for projects and tags for themes across papers.", "A paper can belong to several collections without extra PDF copies.", "Mark papers as read when you are done, or star them for later.", "", "Only the current paper is loaded in the reader.", "Close it with the x button to release the document.", "Your place is remembered when you switch to another paper."]
        for (j, text) in lines.enumerated() { line(text, y: CGFloat(550 - j * 25), size: 12) }
        line("LOCAL FILES. QUIET SOFTWARE.", y: 62, size: 9, color: .gray)
        context.endPDFPage()
    }
    context.closePDF()
}

@MainActor func runSelfTests() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("PaperShelf-tests-\(UUID())")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw ShelfError.message(name) }; print("PASS \(name)")
    }
    let input = base.appendingPathComponent("Original paper.pdf")
    try fixturePDF(at: input, title: "A test paper")
    let originalHash = try Importer.hash(input)
    let store = ShelfStore(root: base.appendingPathComponent("Library"))
    let result = Importer.run(urls: [input, input], destination: store.files, known: [], collection: "Research")
    try expect(result.papers.count == 1 && result.duplicates == 1, "Duplicate PDFs imported only once")
    try expect(result.papers[0].title == "A test paper", "PDF title extracted")
    var library = Library(); library.papers = result.papers; library.collections = ["Research"]
    library.papers[0].tags = ["immune cells", "CRISPR"]
    try expect(store.commit(library), "Atomic metadata save")
    let reloaded = ShelfStore(root: store.root)
    try expect(reloaded.library.papers == library.papers, "Metadata and collections survive restart")
    let reader = Reader()
    try expect(reader.open(library.papers[0], in: store.files), "Open managed PDF")
    guard let document = reader.view.document, let selection = document.findString("Select a sentence", fromSelection: nil, withOptions: []) else { throw ShelfError.message("Fixture text not selectable") }
    reader.view.setCurrentSelection(selection, animate: false)
    reader.highlight()
    reader.comment("An important question")
    reader.annotationUndo.undo()
    try expect(reader.annotations.count == 1, "Undo removes a saved note")
    reader.annotationUndo.undo()
    try expect(reader.annotations.isEmpty, "Undo removes a highlight action")
    reader.annotationUndo.redo()
    reader.annotationUndo.redo()
    try expect(reader.annotations.count == 2, "Redo restores highlights and notes")
    try expect(reader.error == nil && !reader.dirty, "Highlight and comment save successfully")
    let savedURL = store.files.appendingPathComponent(library.papers[0].filename)
    let saved = PDFDocument(url: savedURL)!
    let types = saved.page(at: 0)!.annotations.map { $0.type ?? "" }
    try expect(types.contains("Highlight") && types.contains("Text"), "Annotations embedded in saved PDF")
    let afterHash = try Importer.hash(input)
    try expect(afterHash == originalHash, "Original PDF remains byte-for-byte unchanged")
    try expect(reader.open(nil, in: store.files) && reader.view.document == nil && reader.annotations.isEmpty, "Closing reader releases document and annotation references")
    try expect(!reader.annotationUndo.canUndo, "Closing reader releases annotation undo history")
    try expect(reader.open(library.papers[0], in: store.files) && reader.annotations.count == 2, "Saved annotations survive reopen")
    if let note = reader.annotations.first(where: { $0.annotation.type == "Text" }) { reader.delete(note) }
    _ = reader.open(nil, in: store.files)
    _ = reader.open(library.papers[0], in: store.files)
    try expect(reader.annotations.count == 1, "Annotation deletion persists")
    reader.annotations[0].annotation.contents = "Edited through PDFKit"
    reader.syncNativeAnnotations()
    try expect(reader.annotations.first?.text == "Edited through PDFKit", "Sticky-note changes synchronize to sidebar")
    try expect(reader.save(), "Native PDFKit annotation edits are detected on save")
    _ = reader.open(nil, in: store.files)
    _ = reader.open(library.papers[0], in: store.files)
    try expect(reader.annotations.first?.text == "Edited through PDFKit", "Native annotation edits survive reopen")
    for _ in 0..<50 { autoreleasepool { _ = reader.open(nil, in: store.files); _ = reader.open(library.papers[0], in: store.files) } }
    _ = reader.open(nil, in: store.files)
    try expect(reader.view.document == nil && reader.annotations.isEmpty, "50 open/close cycles leave no retained active document")
    _ = reader.open(library.papers[0], in: store.files)
    let originalLayout = reader.continuousScrolling
    reader.view.go(to: reader.view.document!.page(at: 1)!)
    reader.setContinuousScrolling(true)
    try expect(reader.view.displayMode == .singlePageContinuous && reader.view.document!.index(for: reader.view.currentPage!) == 1, "Continuous layout preserves current page")
    reader.setContinuousScrolling(false)
    try expect(reader.view.displayMode == .singlePage, "Page by page layout selected")
    reader.setContinuousScrolling(originalLayout)
    reader.findNext("demonstration PDF")
    try expect(reader.view.currentSelection?.string?.contains("demonstration PDF") == true, "PDF search selects matching passage")
    reader.findNext("no-such-test-phrase-39118")
    try expect(reader.status.hasPrefix("No matches"), "Missing PDF search reports no match")
    let noteDocument = reader.view.document!
    let passage = noteDocument.findString("Select a sentence", fromSelection: nil, withOptions: [])!
    reader.view.setCurrentSelection(passage, animate: false)
    reader.beginNote()
    reader.updateDraft("Question about this passage")
    reader.view.clearSelection()
    reader.view.go(to: noteDocument.page(at: 2)!)
    try expect(reader.finishNote(), "Inline note saves after PDF selection and page change")
    let anchored = reader.annotations.first { $0.text.contains("Question about this passage") }!
    try expect(anchored.page == 1 && anchored.text.contains("Select a sentence"), "Note retains original page and selected quote")
    try expect(anchored.members.contains { $0.type == "Highlight" }, "Passage note automatically highlights its original selection")
    let annotationCount = reader.annotations.count
    reader.beginNote(editing: anchored)
    reader.updateDraft("Revised note")
    try expect(reader.finishNote() && reader.annotations.count == annotationCount, "Inline edit updates the existing annotation without duplication")
    reader.beginNote()
    reader.updateDraft("Unfinished thought")
    _ = reader.open(nil, in: store.files)
    try expect(reader.draft == nil && reader.view.document == nil, "Closing releases draft and PDF references")
    _ = reader.open(library.papers[0], in: store.files)
    try expect(reader.draft?.text == "Unfinished thought", "Unfinished note restores after closing and reopening")
    reader.discardDraft()
    _ = reader.open(nil, in: store.files)
    _ = reader.open(library.papers[0], in: store.files)
    try expect(reader.draft == nil, "Discarded draft does not return")
    let beforePassage = reader.annotations.count
    let multiLine = reader.view.document!.page(at: 0)!.selection(for: CGRect(x: 50, y: 460, width: 510, height: 100))!
    reader.view.setCurrentSelection(multiLine, animate: false)
    reader.highlight()
    try expect(reader.annotations.count == beforePassage + 1 && reader.annotations.last!.members.count > 1, "Multiline highlight appears as one sidebar note")
    _ = reader.open(nil, in: store.files)
    _ = reader.open(library.papers[0], in: store.files)
    try expect(reader.annotations.count == beforePassage + 1, "Highlight grouping survives PDF save and reopen")
    let groupedHighlight = reader.annotations.last!
    reader.delete(groupedHighlight)
    try expect(reader.annotations.count == beforePassage, "Deleting grouped highlight removes all its lines")
    reader.annotationUndo.undo()
    try expect(reader.annotations.count == beforePassage + 1, "Undo restores the complete grouped highlight")
    _ = reader.open(nil, in: store.files)
    let text = "TY  - JOUR\nTI  - RIS title\nAU  - Nguyen, Ben\nPY  - 2026\nKW  - T cells\nN1  - First line\n  continuation\nL1  - Original%20paper.pdf\nER  - \n"
    let ris = base.appendingPathComponent("Export.ris")
    try text.write(to: ris, atomically: true, encoding: .utf8)
    let risResult = Importer.run(urls: [ris], destination: store.files, known: [], collection: nil)
    try expect(risResult.papers.count == 1 && risResult.papers[0].tags == ["T cells"] && risResult.papers[0].title == "RIS title", "Zotero-style RIS metadata and relative PDF paths")
    try expect(risResult.papers[0].notes.contains("continuation"), "Multiline RIS notes preserved")
    let missing = base.appendingPathComponent("Missing.ris")
    try "TY  - JOUR\nTI  - Missing paper\nL1  - absent.pdf\nER  -\n".write(to: missing, atomically: true, encoding: .utf8)
    let missingResult = Importer.run(urls: [missing], destination: store.files, known: [], collection: nil)
    try expect(missingResult.papers.isEmpty && missingResult.warnings.count == 1, "Missing attachments reported, not silently discarded")
    try expect(RIS.attachment("https://example.com/paper.pdf", relativeTo: base) == nil, "RIS import does not download remote files")
    let groupedStore = ShelfStore(root: base.appendingPathComponent("Grouped"))
    var grouped = Library()
    let main = Paper(title: "Main paper", filename: "main.pdf", sourceHash: "main")
    let supplement = Paper(title: "Supplement", filename: "supplement.pdf", sourceHash: "supplement")
    grouped.papers = [main, supplement]
    try expect(groupedStore.commit(grouped), "Create grouping fixture")
    let legacyData = try JSONEncoder().encode(grouped)
    let legacy = try JSONDecoder().decode(Library.self, from: legacyData)
    try expect(legacy.papers.allSatisfy { $0.parentID == nil && $0.lastOpened == nil }, "Existing libraries load without new grouping fields")
    let sidecar = groupedStore.root.appendingPathComponent("organization.json")
    let plan = OrganizationUpdate(version: 1, papers: [.init(id: main.id, priority: 100), .init(id: supplement.id, parentID: main.id)])
    try JSONEncoder().encode(plan).write(to: sidecar, options: .atomic)
    try expect(groupedStore.refreshOrganization() && groupedStore.library.papers[1].parentID == main.id, "Sidecar groups support files under their paper")
    try expect(!groupedStore.refreshOrganization(), "Unchanged sidecar does not rewrite the library")
    groupedStore.markOpened(supplement.id)
    let recent = groupedStore.library.papers[0].lastOpened
    try expect(recent != nil && recent == groupedStore.library.papers[1].lastOpened, "Reading a supplement updates its parent recency")
    let beforeBadPlan = groupedStore.library.papers
    let badPlan = OrganizationUpdate(version: 1, papers: [.init(id: main.id, parentID: supplement.id)])
    try JSONEncoder().encode(badPlan).write(to: sidecar, options: .atomic)
    try expect(!groupedStore.refreshOrganization() && groupedStore.library.papers == beforeBadPlan, "Cyclic organization suggestions are rejected without partial changes")
    let nextPlan = OrganizationUpdate(version: 1, papers: [.init(id: main.id, priority: 90)])
    try JSONEncoder().encode(nextPlan).write(to: sidecar, options: .atomic)
    try expect(groupedStore.refreshOrganization() && groupedStore.library.papers[0].lastOpened == recent, "Background priorities preserve actual reading history")
    groupedStore.setParent(supplement.id, to: nil)
    try expect(groupedStore.library.papers[1].parentID == nil && groupedStore.library.papers[1].organizationLocked == true, "Manual ungrouping locks organization")
    try JSONEncoder().encode(plan).write(to: sidecar, options: .atomic)
    _ = groupedStore.refreshOrganization()
    try expect(groupedStore.library.papers[1].parentID == nil, "Hermes respects manual organization")
    groupedStore.addCollection("Old")
    var collectionPaper = groupedStore.library.papers[0]; collectionPaper.collections = ["Old"]
    groupedStore.update(collectionPaper)
    try expect(groupedStore.renameCollection("Old", to: "New") && groupedStore.library.papers[0].collections == ["New"], "Renaming collection updates all memberships")
    groupedStore.setArchived(main.id, true)
    try expect(groupedStore.library.papers[0].archived == true, "Archive preserves the paper record")
    groupedStore.setArchived(main.id, false)
    try expect(groupedStore.library.papers[0].archived == false, "Restore returns archived record")
    let staleStore = ShelfStore(root: groupedStore.root)
    groupedStore.addCollection("Later")
    try expect(!staleStore.commit(staleStore.library), "Stale writer cannot overwrite newer metadata")
    var invalid = groupedStore.library; invalid.papers.append(invalid.papers[0])
    try expect(!groupedStore.commit(invalid), "Duplicate paper IDs rejected without crashing")
    invalid = groupedStore.library; invalid.papers[0].filename = "../outside.pdf"
    try expect(!groupedStore.commit(invalid), "Managed filename traversal rejected")
    let mcp = MCPServer(root: store.root)
    func request(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        mcp.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])!
    }
    _ = request("initialize", ["protocolVersion": "2025-11-25"])
    let disabled = request("tools/call", ["name": "search_papers"])["result"] as! [String: Any]
    try expect(disabled["isError"] as? Bool == true, "MCP denies library access by default")
    try MCPAccess(enabled: true, includeContent: false).save(store.root)
    let metadata = request("tools/call", ["name": "get_paper", "arguments": ["paper_id": library.papers[0].id.uuidString]])["result"] as! [String: Any]
    try expect(metadata["isError"] as? Bool == false, "MCP metadata access works when enabled")
    let denied = request("tools/call", ["name": "read_pages", "arguments": ["paper_id": library.papers[0].id.uuidString, "start_page": 1]])["result"] as! [String: Any]
    try expect(denied["isError"] as? Bool == true, "MCP text requires separate content permission")
    try MCPAccess(enabled: true, includeContent: true).save(store.root)
    let pages = request("tools/call", ["name": "read_pages", "arguments": ["paper_id": library.papers[0].id.uuidString, "start_page": 1]])["result"] as! [String: Any]
    try expect(pages["isError"] as? Bool == false, "MCP reads a bounded page with content permission")
    let excessive = request("tools/call", ["name": "read_pages", "arguments": ["paper_id": library.papers[0].id.uuidString, "start_page": 1, "page_count": 500]])["result"] as! [String: Any]
    try expect(excessive["isError"] as? Bool == true, "MCP rejects excessive page ranges")
    try MCPAccess().save(store.root)
    let revoked = request("tools/call", ["name": "search_papers"])["result"] as! [String: Any]
    try expect(revoked["isError"] as? Bool == true, "MCP revocation applies to an existing session")
    let corruptRoot = base.appendingPathComponent("Corrupt")
    try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
    let corrupt = corruptRoot.appendingPathComponent("library.json")
    try "broken".write(to: corrupt, atomically: true, encoding: .utf8)
    let brokenStore = ShelfStore(root: corruptRoot)
    try expect(!brokenStore.writable && !brokenStore.commit(Library()), "Corrupt library cannot be overwritten")
    let originalCorrupt = try String(contentsOf: corrupt, encoding: .utf8)
    try expect(originalCorrupt == "broken", "Corrupt index preserved for recovery")
    print("All PaperShelf self-tests passed.")
}

@MainActor func runMemoryTest() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("PaperShelf-memory-\(UUID())")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let url = base.appendingPathComponent("sample.pdf")
    try fixturePDF(at: url, title: "Memory test", pages: 50)
    let paper = Paper(title: "Memory test", filename: "sample.pdf", sourceHash: "test")
    let reader = Reader()
    reader.view.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
    func rss() throws -> Int {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = pipe; try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
    print("Synthetic 50-page PDF, one document at a time; RSS in KiB.")
    for cycle in 1...100 {
        autoreleasepool {
            _ = reader.open(paper, in: base)
            if let page = reader.view.document?.page(at: cycle % 50) {
                reader.view.go(to: page)
                _ = page.thumbnail(of: NSSize(width: 800, height: 1000), for: .cropBox)
            }
            _ = reader.open(nil, in: base)
        }
        if cycle % 10 == 0 { print("cycle=\(cycle) rss_kib=\(try rss()) retained_document=\(reader.view.document != nil)") }
    }
    print("This is a short synthetic regression check, not a guarantee for large scanned PDFs or long reading sessions.")
}

@MainActor func makeDemo(at root: URL) throws {
    guard !FileManager.default.fileExists(atPath: root.path) else { throw ShelfError.message("Demo destination already exists") }
    let store = ShelfStore(root: root)
    var library = Library(); library.collections = ["Reading room", "Methods"]
    for (i, title) in ["A quieter place for your papers", "Questions worth keeping", "From reading to understanding"].enumerated() {
        let id = UUID(), filename = id.uuidString + ".pdf", url = store.files.appendingPathComponent(filename)
        try fixturePDF(at: url, title: title)
        var paper = Paper(id: id, title: title, authors: "PaperShelf · Sample document", year: "2026", tags: i == 0 ? ["getting started", "reading"] : ["ideas"], collections: ["Reading room"], filename: filename, sourceHash: try Importer.hash(url))
        paper.starred = i == 0; paper.unread = i != 2
        library.papers.append(paper)
    }
    guard store.commit(library) else { throw ShelfError.message(store.error ?? "Demo save failed") }
    print("Created demo library at \(root.path)")
}

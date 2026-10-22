import AppKit
import PDFKit
import SwiftUI

final class ReaderPDFView: PDFView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty && event.keyCode == 123 { goToPreviousPage(nil) }
        else if modifiers.isEmpty && event.keyCode == 124 { goToNextPage(nil) }
        else { super.keyDown(with: event) }
    }
}

struct AnnotationRow: Identifiable {
    let id: String
    let page: Int
    let text: String
    let annotation: PDFAnnotation
    let members: [PDFAnnotation]
}

struct PassageBounds: Codable {
    var page: Int
    var bounds: CGRect
}

struct NoteDraft: Codable {
    var text = ""
    var quote = ""
    var page: Int
    var bounds: CGRect
    var editingID: String?
    var originalText: String?
    var passageBounds: [PassageBounds]?
}

@MainActor
final class Reader: NSObject, ObservableObject {
    let view = ReaderPDFView()
    let annotationUndo = UndoManager()
    @Published var paperID: UUID?
    @Published var pageLabel = ""
    @Published var status = "Choose a paper to start reading"
    @Published var annotations: [AnnotationRow] = []
    @Published var dirty = false
    @Published var error: String?
    @Published var draft: NoteDraft?
    @Published private(set) var continuousScrolling = UserDefaults.standard.bool(forKey: "continuousScrolling")
    private var url: URL?
    private var pageCount = 0
    private var savedAnnotationState: [String] = []
    var onPage: ((UUID, Int) -> Void)?

    override init() {
        super.init()
        annotationUndo.groupsByEvent = false
        annotationUndo.levelsOfUndo = 30
        view.autoScales = true
        view.displayMode = continuousScrolling ? .singlePageContinuous : .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
    }

    func setContinuousScrolling(_ enabled: Bool) {
        let page = view.currentPage
        continuousScrolling = enabled
        UserDefaults.standard.set(enabled, forKey: "continuousScrolling")
        view.displayMode = enabled ? .singlePageContinuous : .singlePage
        view.autoScales = true
        if let page { view.go(to: page) }
    }

    @discardableResult func open(_ paper: Paper?, in files: URL) -> Bool {
        if paper?.id == paperID { return true }
        guard saveDraft() else { return false }
        guard save() else { return false }
        rememberPage()
        annotationUndo.removeAllActions()
        view.clearSelection()
        annotations = []
        draft = nil
        // PDFView is reused, but only a single document is retained.
        view.document = nil
        savedAnnotationState = []
        url = nil; paperID = nil; pageCount = 0; pageLabel = ""
        guard let paper else { status = "Reader closed · document released"; return true }
        if !paper.hasPDF { paperID = paper.id; status = "Reference saved · no PDF attached"; return true }
        let file = files.appendingPathComponent(paper.filename)
        guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else {
            error = "Could not open \(paper.title). The PDF may be missing, damaged, or locked."
            return false
        }
        paperID = paper.id; url = file; pageCount = document.pageCount
        view.document = document
        if let page = document.page(at: min(max(paper.page, 0), document.pageCount - 1)) { view.go(to: page) }
        refreshAnnotations(); pageChanged()
        savedAnnotationState = annotationState(document)
        if let draftURL, let data = try? Data(contentsOf: draftURL) {
            draft = try? JSONDecoder().decode(NoteDraft.self, from: data)
        }
        status = "One PDF open · annotations saved locally"
        return true
    }

    func printPaper() {
        guard let document = view.document, let window = view.window else { return }
        guard save() else { return }
        guard let operation = document.printOperation(for: NSPrintInfo.shared,
                                                       scalingMode: .pageScaleToFit,
                                                       autoRotate: true) else {
            error = "This PDF could not be prepared for printing."
            return
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func syncNativeAnnotations() {
        guard let document = view.document, annotationState(document) != savedAnnotationState else { return }
        changed()
    }
    func rememberPage() {
        if let id = paperID, let page = view.currentPage, let document = view.document {
            onPage?(id, document.index(for: page))
        }
    }
    @objc func pageChanged() {
        guard let page = view.currentPage, let document = view.document else { return }
        pageLabel = "\(document.index(for: page) + 1) / \(document.pageCount)"
    }
    @discardableResult func save() -> Bool {
        guard saveDraft() else { return false }
        guard let document = view.document, let url else { return true }
        let state = annotationState(document)
        guard dirty || state != savedAnnotationState else { return true }
        dirty = true
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        do {
            guard document.write(to: temporary) else { throw ShelfError.message("PDFKit could not write the annotated PDF.") }
            // Verify the file is readable before replacing the managed copy.
            guard let check = PDFDocument(url: temporary), check.pageCount == pageCount else {
                throw ShelfError.message("Saved PDF did not pass validation.")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            savedAnnotationState = state
            dirty = false; status = "Saved · \(Date().formatted(date: .omitted, time: .shortened))"
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            self.error = "Could not save annotations: \(error.localizedDescription). Keep this paper open and try again."
            return false
        }
    }
    private var draftURL: URL? {
        guard let url, let paperID else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NoteDrafts", isDirectory: true).appendingPathComponent("\(paperID).json")
    }
    @discardableResult func saveDraft() -> Bool {
        guard let draftURL else { return true }
        do {
            if let draft {
                try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: draftURL.path) {
                try FileManager.default.removeItem(at: draftURL)
            }
            return true
        } catch { self.error = "Could not save note draft: \(error.localizedDescription)"; return false }
    }
    func beginNote(editing row: AnnotationRow? = nil) {
        // Reopening the composer resumes unfinished work instead of replacing it.
        guard draft == nil, let document = view.document,
              let page = row?.annotation.page ?? view.currentSelection?.pages.first ?? view.currentPage else { return }
        let crop = page.bounds(for: .cropBox)
        let selected = view.currentSelection?.bounds(for: page)
        let point = selected.map { NSPoint(x: $0.maxX, y: $0.maxY) } ?? NSPoint(x: crop.minX + 24, y: crop.maxY - 48)
        let bounds = NSRect(x: min(max(point.x, crop.minX), crop.maxX - 24), y: min(max(point.y, crop.minY), crop.maxY - 24), width: 24, height: 24)
        draft = NoteDraft(text: row?.text ?? "", quote: row == nil ? (view.currentSelection?.string ?? "") : "",
                          page: document.index(for: page), bounds: bounds, editingID: row?.id, originalText: row?.text)
        if row == nil, let selection = view.currentSelection {
            draft?.passageBounds = selection.selectionsByLine().flatMap { line in
                line.pages.compactMap { page in
                    let bounds = line.bounds(for: page)
                    return bounds.isEmpty ? nil : PassageBounds(page: document.index(for: page), bounds: bounds)
                }
            }
        }
        _ = saveDraft()
    }
    func updateDraft(_ text: String) { draft?.text = text; _ = saveDraft() }
    func discardDraft() { draft = nil; _ = saveDraft() }
    @discardableResult func finishNote() -> Bool {
        guard let draft, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = view.document?.page(at: draft.page) else { return false }
        if let id = draft.editingID {
            guard let row = annotations.first(where: { $0.id == id && $0.text == draft.originalText }) else {
                error = "This annotation changed. Your draft is saved; copy it before editing the annotation again."; return false
            }
            changeRowText(row, to: draft.text)
        } else {
            let annotation = PDFAnnotation(bounds: draft.bounds, forType: .text, withProperties: nil)
            annotation.contents = draft.quote.isEmpty ? draft.text : "“\(draft.quote)”\n\n\(draft.text)"
            annotation.color = .systemOrange; annotation.userName = "chimpread"; annotation.modificationDate = Date()
            let groupID = UUID().uuidString
            annotation.setValue(groupID, forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup"))
            var additions: [(documentPage: Int, annotation: PDFAnnotation)] = (draft.passageBounds ?? []).map { passage in
                let highlight = PDFAnnotation(bounds: passage.bounds, forType: .highlight, withProperties: nil)
                highlight.color = NSColor.systemYellow.withAlphaComponent(0.45)
                highlight.userName = "chimpread"; highlight.modificationDate = Date()
                highlight.setValue(groupID, forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup"))
                return (passage.page, highlight)
            }
            additions.append((draft.page, annotation))
            changePresence(additions, present: true)
        }
        // Keep the draft if saving the PDF fails; retry must not create a second note.
        dirty = true; refreshAnnotations(); view.needsDisplay = true
        if let annotation = page.annotations.last, draft.editingID == nil,
           let row = annotations.first(where: { $0.annotation === annotation }) {
            self.draft?.editingID = row.id; self.draft?.originalText = row.text
            self.draft?.text = row.text; self.draft?.quote = ""
        } else if let id = draft.editingID {
            self.draft?.originalText = annotations.first(where: { $0.id == id })?.text
        }
        guard save() else { return false }
        discardDraft()
        return true
    }
    func highlight() {
        guard let selection = view.currentSelection, !(selection.string ?? "").isEmpty else {
            status = "Select some text in the PDF, then choose Highlight."; return
        }
        let groupID = UUID().uuidString
        var additions: [(documentPage: Int, annotation: PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.setValue(groupID, forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup"))
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                annotation.contents = line.string
                annotation.userName = "chimpread"
                annotation.modificationDate = Date()
                if let document = view.document { additions.append((document.index(for: page), annotation)) }
            }
        }
        changePresence(additions, present: true)
        view.clearSelection(); changed()
    }
    func comment(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let page = view.currentSelection?.pages.first ?? view.currentPage else { return }
        let crop = page.bounds(for: .cropBox)
        let selected = view.currentSelection?.bounds(for: page)
        let point = selected.map { NSPoint(x: $0.maxX, y: $0.maxY) } ?? NSPoint(x: crop.minX + 24, y: crop.maxY - 48)
        let bounds = NSRect(x: min(max(point.x, crop.minX), crop.maxX - 24), y: min(max(point.y, crop.minY), crop.maxY - 24), width: 24, height: 24)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.contents = text; annotation.color = .systemOrange; annotation.userName = "chimpread"
        annotation.modificationDate = Date()
        if let document = view.document { changePresence([(document.index(for: page), annotation)], present: true) }
        changed()
    }
    func delete(_ row: AnnotationRow) {
        guard let document = view.document else { return }
        changePresence(row.members.compactMap { annotation in
            annotation.page.map { (document.index(for: $0), annotation) }
        }, present: false); changed()
    }
    func edit(_ row: AnnotationRow, text: String) {
        changeRowText(row, to: text)
        changed()
    }
    private func changePresence(_ entries: [(documentPage: Int, annotation: PDFAnnotation)], present: Bool) {
        guard !entries.isEmpty, let document = view.document else { return }
        annotationUndo.beginUndoGrouping()
        annotationUndo.registerUndo(withTarget: self) { target in
            target.changePresence(entries, present: !present)
            target.changed()
        }
        annotationUndo.setActionName(present ? "Add Annotation" : "Delete Annotation")
        annotationUndo.endUndoGrouping()
        for entry in entries {
            guard let page = document.page(at: entry.documentPage) else { continue }
            if present { page.addAnnotation(entry.annotation) }
            else { page.removeAnnotation(entry.annotation) }
        }
    }
    private func changeRowText(_ row: AnnotationRow, to text: String) {
        annotationUndo.beginUndoGrouping()
        // Give legacy line highlights a stable identity before their dates change.
        let groupID = row.id
        for (index, annotation) in row.members.enumerated() {
            if row.members.count > 1 {
                annotation.setValue(groupID, forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup"))
            }
            changeText(annotation, to: index == 0 ? text : "")
        }
        annotationUndo.endUndoGrouping()
    }
    private func changeText(_ annotation: PDFAnnotation, to text: String) {
        let previous = annotation.contents ?? ""
        annotationUndo.beginUndoGrouping()
        annotationUndo.registerUndo(withTarget: self) { target in
            target.changeText(annotation, to: previous)
            target.changed()
        }
        annotationUndo.setActionName("Edit Note")
        annotationUndo.endUndoGrouping()
        annotation.contents = text
        annotation.modificationDate = Date()
    }
    private func annotationState(_ document: PDFDocument) -> [String] {
        var state: [String] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                state.append(contentsOf: [String(index), annotation.type ?? "", annotation.contents ?? "", NSStringFromRect(annotation.bounds), annotation.color.description])
            }
        }
        return state
    }
    func jump(_ row: AnnotationRow) {
        if let page = row.annotation.page { view.go(to: row.annotation.bounds, on: page) }
    }
    private func changed() { dirty = true; refreshAnnotations(); view.needsDisplay = true; _ = save() }
    func refreshAnnotations() {
        guard let document = view.document else { annotations = []; return }
        annotations = Self.annotationRows(in: document)
    }
    static func annotationRows(in document: PDFDocument) -> [AnnotationRow] {
        var groups: [(id: String, page: Int, members: [PDFAnnotation])] = []
        var groupIndices: [String: Int] = [:]
        for index in 0..<document.pageCount {
            for (offset, annotation) in (document.page(at: index)?.annotations ?? []).enumerated() {
                guard ["Highlight", "Text", "Underline", "StrikeOut", "FreeText"].contains(annotation.type ?? "") else { continue }
                var key = "\(index)-\(offset)"
                if let group = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup")) as? String {
                    key = group
                } else if annotation.type == "Highlight", annotation.userName == "chimpread", let date = annotation.modificationDate {
                    // Older builds wrote one annotation per line, all stamped in the same second.
                    key = "legacy-\(index)-\(Int(date.timeIntervalSince1970))"
                }
                if let slot = groupIndices[key] { groups[slot].members.append(annotation) }
                else { groupIndices[key] = groups.count; groups.append((key, index + 1, [annotation])) }
            }
        }
        return groups.map { group in
            let members = group.members.sorted { ($0.type == "Text" ? 0 : 1) < ($1.type == "Text" ? 0 : 1) }
            let first = members[0]
            let text = members.compactMap { $0.contents }.filter { !$0.isEmpty }.joined(separator: "\n")
            return AnnotationRow(id: group.id, page: group.page, text: text.isEmpty ? (first.type ?? "Annotation") : text,
                                 annotation: first, members: members)
        }
    }
    func findNext(_ text: String) {
        guard !text.isEmpty, let document = view.document else { return }
        let found = document.findString(text, fromSelection: view.currentSelection, withOptions: .caseInsensitive)
            ?? document.findString(text, fromSelection: nil, withOptions: .caseInsensitive)
        if let found { view.setCurrentSelection(found, animate: true); view.scrollSelectionToVisible(nil); status = "Found “\(text)”" }
        else { status = "No matches for “\(text)”" }
    }
    func exportPDF() {
        guard save(), let url else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Annotated paper.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if destination.standardizedFileURL == url.standardizedFileURL { return }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

struct PDFCanvas: NSViewRepresentable {
    let reader: Reader
    func makeNSView(context: Context) -> PDFView { reader.view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

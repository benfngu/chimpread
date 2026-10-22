import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum LibraryFilter: Hashable {
    case all, unread, starred, reading, unfiled, archived, collection(String), tag(String)
    var title: String {
        switch self {
        case .all: return "All Papers"
        case .unread: return "Unread"
        case .starred: return "Starred"
        case .reading: return "Continue Reading"
        case .unfiled: return "Unfiled"
        case .archived: return "Archive"
        case .collection(let name), .tag(let name): return name
        }
    }
}

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var reader: Reader
    @State private var filter: LibraryFilter? = .reading
    @State private var selection: UUID?
    @State private var query = ""
    @AppStorage("librarySort") private var sort = "Recent"
    @AppStorage("showLibraryTags") private var showTags = false
    @State private var renamingCollection: String?
    @State private var renameText = ""
    @State private var expandedPapers: Set<UUID> = []
    @State private var newCollection = ""
    @State private var addingCollection = false
    @State private var showAnnotations = false
    @FocusState private var noteFocused: Bool
    @State private var annotationQuery = ""
    @State private var editingPaper: Paper?
    @State private var pdfSearch = ""
    @State private var dropping = false
    private var active: Paper? { store.library.papers.first { $0.id == reader.paperID } }
    private var selectedCollection: String? { if case .collection(let name) = filter { return name }; return nil }
    private var allTags: [String] {
        var seen = Set<String>()
        return store.library.papers.flatMap(\.tags).sorted().filter { seen.insert($0.folding(options: [.caseInsensitive], locale: .current)).inserted }
    }
    private struct PaperGroup: Identifiable {
        var paper: Paper
        var supporting: [Paper]
        var id: UUID { paper.id }
    }
    private var paperGroups: [PaperGroup] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func belongs(_ paper: Paper) -> Bool {
            switch filter ?? .all {
            case .all: return true
            case .unread: return paper.unread
            case .starred: return paper.starred
            case .reading: return paper.lastOpened != nil
            case .unfiled: return paper.collections.isEmpty
            case .archived: return true
            case .collection(let name): return paper.collections.contains(name)
            case .tag(let name): return paper.tags.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
            }
        }
        func matches(_ paper: Paper) -> Bool {
            terms.isEmpty || ([paper.title, paper.authors, paper.year, paper.doi] + paper.tags).joined(separator: " ").localizedCaseInsensitiveContains(terms)
        }
        let showingArchive = filter == .archived
        let source = store.library.papers.filter { paper in
            let parentArchived = store.library.papers.first(where: { $0.id == paper.parentID })?.archived == true
            return (paper.archived == true || parentArchived) == showingArchive
        }
        let ids = Set(source.map(\.id))
        let children = Dictionary(grouping: source.filter { $0.parentID != nil }, by: { $0.parentID! })
        let result = source.filter { $0.parentID == nil || !ids.contains($0.parentID!) }.compactMap { paper -> PaperGroup? in
            let supporting = children[paper.id] ?? []
            let eligible = belongs(paper) ? supporting : supporting.filter(belongs)
            guard belongs(paper) || !eligible.isEmpty else { return nil }
            let visible = matches(paper) ? eligible : eligible.filter(matches)
            guard matches(paper) || !visible.isEmpty else { return nil }
            return PaperGroup(paper: paper, supporting: visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
        return result.sorted { left, right in
            let a = left.paper, b = right.paper
            switch sort {
            case "Recent":
                if a.lastOpened != b.lastOpened { return (a.lastOpened ?? .distantPast) > (b.lastOpened ?? .distantPast) }
                if (a.priority ?? 0) != (b.priority ?? 0) { return (a.priority ?? 0) > (b.priority ?? 0) }
                if a.added != b.added { return a.added > b.added }
            case "Newest": if a.added != b.added { return a.added > b.added }
            case "Author": if a.authors != b.authors { return a.authors.localizedStandardCompare(b.authors) == .orderedAscending }
            case "Year": if a.year != b.year { return a.year > b.year }
            default: break
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 140, idealWidth: 170, maxWidth: 260)
            paperList.frame(minWidth: 200, idealWidth: 270, maxWidth: 440)
            readingPane.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
        }
        .onAppear {
            selection = reader.paperID
            if reader.draft != nil { showAnnotations = true }
            reader.onPage = { id, page in
                if var paper = store.library.papers.first(where: { $0.id == id }), paper.page != page {
                    paper.page = page; store.update(paper)
                }
            }
        }
        .onChange(of: selection) { _, id in
            if id != reader.paperID {
                let paper = store.library.papers.first { $0.id == id }
                if !reader.open(paper, in: store.files) { selection = reader.paperID }
                else if let id { store.markOpened(id) }
            }
        }
        .onChange(of: active?.filename) { old, new in
            if old == "", let new, !new.isEmpty, let paper = active {
                if reader.open(nil, in: store.files) { _ = reader.open(paper, in: store.files) }
            }
        }
        .onChange(of: reader.paperID) { _, id in selection = id; if reader.draft != nil { showAnnotations = true } }
        .onReceive(NotificationCenter.default.publisher(for: .shelfImport)) { _ in chooseImport() }
        .onReceive(NotificationCenter.default.publisher(for: .shelfSave)) { _ in _ = reader.save(); reader.rememberPage() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in reader.syncNativeAnnotations() }
        .onReceive(NotificationCenter.default.publisher(for: .shelfCollection)) { _ in newCollection = ""; addingCollection = true }
        .sheet(item: $editingPaper) { paper in PaperEditor(paper: paper, store: store) }
        .alert("Rename Collection", isPresented: Binding(get: { renamingCollection != nil }, set: { if !$0 { renamingCollection = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let old = renamingCollection, store.renameCollection(old, to: renameText) {
                    filter = .collection(renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renamingCollection = nil
            }
            Button("Cancel", role: .cancel) { renamingCollection = nil }
        }
        .alert("New Collection", isPresented: $addingCollection) {
            TextField("Name", text: $newCollection)
            Button("Create") { let name = newCollection.trimmingCharacters(in: .whitespacesAndNewlines); store.addCollection(name); if store.library.collections.contains(name) { filter = .collection(name) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("chimpread", isPresented: Binding(get: { store.error != nil || reader.error != nil }, set: { if !$0 { store.error = nil; reader.error = nil } })) {
            Button("OK") { store.error = nil; reader.error = nil }
        } message: { Text(store.error ?? reader.error ?? "") }
        .sheet(isPresented: Binding(get: { store.report != nil }, set: { if !$0 { store.report = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import Complete").font(.headline)
                ScrollView { Text(store.report ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(width: 440, height: 200)
                HStack { Spacer(); Button("Done") { store.report = nil }.keyboardShortcut(.defaultAction) }
            }.padding(20)
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $filter) {
                Section("Library") {
                    Label("Continue Reading", systemImage: "book").tag(LibraryFilter.reading)
                    Label("All Papers", systemImage: "doc.on.doc").tag(LibraryFilter.all)
                    Label("Unread", systemImage: "circle").tag(LibraryFilter.unread)
                    Label("Starred", systemImage: "star").tag(LibraryFilter.starred)
                    Label("Unfiled", systemImage: "tray").tag(LibraryFilter.unfiled)
                    Label("Archive", systemImage: "archivebox").tag(LibraryFilter.archived)
                }
                Section("Collections") {
                    ForEach(store.library.collections, id: \.self) { name in
                        Label(name, systemImage: "folder").tag(LibraryFilter.collection(name))
                            .contextMenu { Button("Rename…") { renameText = name; renamingCollection = name } }
                    }
                }
                if !allTags.isEmpty {
                    DisclosureGroup("Tags", isExpanded: $showTags) {
                        ForEach(allTags, id: \.self) { name in Label(name, systemImage: "tag").tag(LibraryFilter.tag(name)) }
                    }
                }
            }.listStyle(.sidebar)
            Divider()
            HStack {
                Button { newCollection = ""; addingCollection = true } label: { Image(systemName: "plus") }.help("New Collection")
                Spacer()
                Button { NSWorkspace.shared.open(store.root) } label: { Image(systemName: "folder") }.help("Show Library in Finder")
            }.buttonStyle(.borderless).padding(9)
        }
    }
    private var paperList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(8)
            Divider()
            if store.importing { ProgressView("Importing…").controlSize(.small).padding(10) }
            List(selection: $selection) {
                ForEach(paperGroups) { group in
                    if group.supporting.isEmpty {
                        paperRow(group.paper).tag(group.id)
                    } else {
                        DisclosureGroup(isExpanded: Binding(
                            get: { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expandedPapers.contains(group.id) },
                            set: { if $0 { expandedPapers.insert(group.id) } else { expandedPapers.remove(group.id) } }
                        )) {
                            ForEach(group.supporting) { paper in paperRow(paper, supporting: true).tag(paper.id) }
                        } label: {
                            paperRow(group.paper).contentShape(Rectangle()).onTapGesture { selection = group.id }
                        }.tag(group.id)
                    }
                }
            }.listStyle(.inset)
            .overlay {
                if paperGroups.isEmpty && !store.importing { Text(query.isEmpty ? "No papers" : "No results").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(paperGroups.count) papers")
                    let supportingCount = paperGroups.reduce(0) { $0 + $1.supporting.count }
                    if supportingCount > 0 { Text("\(supportingCount) supporting files") }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $sort) { Text("Recent").tag("Recent"); Text("Title").tag("Title"); Text("Author").tag("Author"); Text("Newest").tag("Newest"); Text("Year").tag("Year") }.labelsHidden().frame(width: 85).controlSize(.small)
            }.padding(7)
        }
        .overlay { if dropping { Rectangle().stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            guard !store.importing else { return false }
            let group = DispatchGroup(), box = DropURLs()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { box.append(url) }; group.leave() }
            }
            group.notify(queue: .main) { store.importFiles(box.values, collection: selectedCollection) }
            return true
        }
    }
    private func paperRow(_ paper: Paper, supporting: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if supporting { Image(systemName: "doc").font(.caption).foregroundStyle(.secondary) }
                if paper.unread { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                Text(supporting && paper.title.contains(": ") ? String(paper.title.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) : paper.title).fontWeight(paper.unread ? .medium : .regular).lineLimit(2)
                if paper.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary) }
            }
            if !supporting {
                Text([paper.authors, paper.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 3)
        .contextMenu {
            Button("Details…") { editingPaper = paper }
            Button(paper.starred ? "Unstar" : "Star") { var p = paper; p.starred.toggle(); store.update(p) }
            Button(paper.unread ? "Mark as Read" : "Mark as Unread") { var p = paper; p.unread.toggle(); store.update(p) }
            Menu("Add to Collection") {
                ForEach(store.library.collections, id: \.self) { name in Button(name) { var p = paper; if !p.collections.contains(name) { p.collections.append(name); store.update(p) } } }
            }
            if let name = selectedCollection {
                Button("Remove from \(name)") { var p = paper; p.collections.removeAll { $0 == name }; store.update(p) }
            }
            Button(filter == .archived ? "Restore from Archive" : "Archive Paper") {
                if reader.paperID == paper.id || (paper.parentID == nil && active?.parentID == paper.id) {
                    guard reader.open(nil, in: store.files) else { return }
                }
                let archivedParent = store.library.papers.first { $0.id == paper.parentID && $0.archived == true }
                store.setArchived(archivedParent?.id ?? paper.id, filter != .archived)
            }
            Button("Copy Citation") {
                do { let text = try Citations.render([paper], style: .apa, inline: true); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } catch { store.error = error.localizedDescription }
            }
            if paper.hasPDF {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.files.appendingPathComponent(paper.filename)]) }
            } else { Button("Attach PDF…") { attachPDF(paper) } }
        }
    }
    private var readingPane: some View {
        VStack(spacing: 0) {
            if let active, !active.hasPDF {
                VStack(alignment: .leading, spacing: 15) {
                    Text(active.title).font(.title2)
                    Text(active.authors + " · " + active.year).foregroundStyle(.secondary)
                    Text("Reference saved. No PDF attached.").font(.callout)
                    HStack {
                        Button("Attach PDF…") { attachPDF(active) }
                        Button("Details…") { editingPaper = active }
                        if let raw = active.sourceURL, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { Link("Open Source", destination: url) }
                    }
                    if !active.notes.isEmpty { ScrollView { Text(active.notes).textSelection(.enabled) } }
                    Spacer()
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let active {
                HStack(spacing: 12) {
                    Button { reader.highlight() } label: { Image(systemName: "highlighter") }.help("Highlight Selected Text (⌘L)").keyboardShortcut("l", modifiers: .command)
                    Button { startNote() } label: { Image(systemName: "note.text.badge.plus") }.help("New Note (⌘N)").keyboardShortcut("n", modifiers: .command)
                    Divider().frame(height: 16)
                    Button { reader.view.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                    Button { reader.view.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                    Button { reader.view.autoScales = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit Page")
                    Picker("Reading Layout", selection: Binding(get: { reader.continuousScrolling }, set: { reader.setContinuousScrolling($0) })) {
                        Text("Page by Page").tag(false)
                        Text("Continuous Scroll").tag(true)
                    }.labelsHidden().fixedSize().help("Reading Layout")
                    Spacer(minLength: 4)
                    Button { editingPaper = active } label: { Image(systemName: "info.circle") }.help("Paper Details")
                    Button { showAnnotations.toggle() } label: { Image(systemName: "sidebar.right") }.help("Annotations")
                    Button { reader.printPaper() } label: { Image(systemName: "printer") }.help("Print (⌘P)").accessibilityLabel("Print")
                    Button { reader.exportPDF() } label: { Image(systemName: "square.and.arrow.up") }.help("Export PDF")
                    Button { _ = reader.open(nil, in: store.files) } label: { Image(systemName: "xmark") }.help("Close PDF")
                }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 9)
                Divider()
                HSplitView {
                    PDFCanvas(reader: reader)
                    if showAnnotations { notesPane }

                }
                Divider()
                HStack(spacing: 8) {
                    Button { reader.view.goToPreviousPage(nil) } label: { Image(systemName: "chevron.left") }.help("Previous Page")
                    Text(reader.pageLabel).monospacedDigit().font(.caption)
                    Button { reader.view.goToNextPage(nil) } label: { Image(systemName: "chevron.right") }.help("Next Page")
                    Spacer()
                    if reader.dirty { Text("Unsaved").font(.caption).foregroundStyle(.orange) }
                    if reader.status.hasPrefix("No matches") { Text("Not found").font(.caption).foregroundStyle(.secondary) }
                    TextField("Find in PDF", text: $pdfSearch).textFieldStyle(.roundedBorder).frame(width: 140).onSubmit { reader.findNext(pdfSearch) }
                    Button { reader.findNext(pdfSearch) } label: { Image(systemName: "arrow.right") }.disabled(pdfSearch.isEmpty).help("Find Next")
                }.buttonStyle(.borderless).controlSize(.small).padding(8)
            } else {
                VStack(spacing: 10) {
                    Text("Select a paper").foregroundStyle(.secondary)
                    Button("Import…", action: chooseImport).disabled(store.importing)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func attachPDF(_ paper: Paper) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if reader.paperID == paper.id { guard reader.open(nil, in: store.files) else { return } }
        store.attachPDF(url, to: paper.id)
    }
    private func startNote(_ row: AnnotationRow? = nil) {
        reader.beginNote(editing: row)
        showAnnotations = true
        DispatchQueue.main.async { noteFocused = true }
    }
    private var notesPane: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search notes", text: $annotationQuery).textFieldStyle(.roundedBorder)
                Button { startNote() } label: { Image(systemName: "plus") }.help("New Note")
            }.padding(8)
            List(reader.annotations.filter { annotationQuery.isEmpty || $0.text.localizedCaseInsensitiveContains(annotationQuery) }) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Button("Page \(row.page)") { reader.jump(row) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        Spacer()
                        Button { startNote(row) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit Note")
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy Note")
                        Button { reader.delete(row) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete Note (⌘Z to undo)")
                    }.font(.caption)
                    Text(row.text).font(.callout).lineLimit(8).textSelection(.enabled)
                }.padding(.vertical, 4)
                .contextMenu {
                    Button("Go to Passage") { reader.jump(row) }
                    Button("Edit Note…") { startNote(row) }
                    Button("Delete Annotation") { reader.delete(row) }
                }
            }.listStyle(.inset)
            if reader.annotations.isEmpty && reader.draft == nil {
                Text("Select a passage, then press ⌘N.").font(.callout).foregroundStyle(.secondary).padding()
            }
            if let draft = reader.draft {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(draft.editingID == nil ? "New note" : "Edit note") · Page \(draft.page + 1)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(reader.error == nil ? "Draft saved" : "Save needs attention").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !draft.quote.isEmpty {
                        Text(draft.quote).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    TextEditor(text: Binding(get: { reader.draft?.text ?? "" }, set: { reader.updateDraft($0) }))
                        .font(.body).frame(minHeight: 100, idealHeight: 140, maxHeight: 200)
                        .focused($noteFocused).accessibilityLabel("Note text")
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            if reader.finishNote() { noteFocused = false }
                            return .handled
                        }
                    HStack {
                        Button("Discard") { reader.discardDraft(); noteFocused = false }.buttonStyle(.borderless)
                        Spacer()
                        Button("Save Note") { if reader.finishNote() { noteFocused = false } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(10)
            }
        }.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
    }
    private func chooseImport() {
        guard !store.importing else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "ris") ?? .data]
        panel.message = "Choose PDFs or a Zotero RIS export with files and annotations. Originals are kept."
        panel.prompt = "Import"
        if panel.runModal() == .OK { store.importFiles(panel.urls, collection: selectedCollection) }
    }
}

final class DropURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

struct PaperEditor: View {
    @State var paper: Paper
    @ObservedObject var store: ShelfStore
    @State private var tags = ""
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Details").font(.headline)
            Form {
                TextField("Title", text: $paper.title)
                TextField("Authors", text: $paper.authors)
                TextField("Year", text: $paper.year)
                TextField("DOI", text: $paper.doi)
                TextField("Journal", text: Binding(get: { paper.citation?.journal ?? "" }, set: { if paper.citation == nil { paper.citation = CitationMetadata() }; paper.citation?.journal = $0 }))
                HStack {
                    TextField("Volume", text: Binding(get: { paper.citation?.volume ?? "" }, set: { if paper.citation == nil { paper.citation = CitationMetadata() }; paper.citation?.volume = $0 }))
                    TextField("Issue", text: Binding(get: { paper.citation?.issue ?? "" }, set: { if paper.citation == nil { paper.citation = CitationMetadata() }; paper.citation?.issue = $0 }))
                    TextField("Pages", text: Binding(get: { paper.citation?.pages ?? "" }, set: { if paper.citation == nil { paper.citation = CitationMetadata() }; paper.citation?.pages = $0 }))
                }
                TextField("Tags (comma-separated)", text: $tags)
                Picker("Supporting file of", selection: $paper.parentID) {
                    Text("Standalone paper").tag(nil as UUID?)
                    ForEach(store.library.papers.filter { $0.parentID == nil && $0.id != paper.id && ($0.archived != true || $0.id == paper.parentID) }.sorted { $0.title < $1.title }) { parent in
                        Text(parent.title).tag(Optional(parent.id))
                    }
                }.disabled(store.library.papers.contains { $0.parentID == paper.id })
                Toggle("Keep my organization (ignore Hermes suggestions)", isOn: Binding(get: { paper.organizationLocked == true }, set: { paper.organizationLocked = $0 }))
                Toggle("Unread", isOn: $paper.unread)
                Toggle("Starred", isOn: $paper.starred)
            }.textFieldStyle(.roundedBorder)
            Text("Collections").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    if store.library.collections.isEmpty { Text("Add collections in the sidebar.").foregroundStyle(.secondary) }
                    ForEach(store.library.collections, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { paper.collections.contains(name) }, set: { enabled in paper.collections.removeAll { $0 == name }; if enabled { paper.collections.append(name) } }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
            Text("Notes").font(.headline)
            TextEditor(text: $paper.notes).frame(height: 100).border(Color.secondary.opacity(0.2))
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    paper.tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                    if let current = store.library.papers.first(where: { $0.id == paper.id }) {
                        paper.page = current.page
                        if paper.parentID != current.parentID { paper.organizationLocked = true }
                        paper.priority = current.priority
                        paper.lastOpened = current.lastOpened
                    }
                    store.update(paper); if store.error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(paper.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 440).onAppear { tags = paper.tags.joined(separator: ", ") }
    }
}

extension Notification.Name {
    static let shelfImport = Notification.Name("PaperShelf.import")
    static let shelfSave = Notification.Name("PaperShelf.save")
    static let shelfCollection = Notification.Name("PaperShelf.collection")
}

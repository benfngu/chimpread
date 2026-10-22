import Foundation
import PDFKit
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MigrationItem: Sendable {
    var paper: Paper
    var attachments: [(url: URL, title: String)] = []
}
struct MigrationPlan: Sendable {
    var items: [MigrationItem] = []
    var collections: [String] = []
    var warnings: [String] = []
    var source: String = ""
}
// Small RDF graph reader: handles both nested nodes and resource/nodeID references.
// XML external entities and DTDs are rejected before parsing.
enum ZoteroRDF {
    struct Value { var text: String?; var ref: String? }
    struct Node { var type: String; var fields: [String: [Value]] = [:] }
    static func parse(_ url: URL) throws -> MigrationPlan {
        let data = try Data(contentsOf: url)
        guard data.count <= 100_000_000, let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw ShelfError.message("Unsupported or unsafe RDF XML. Export UTF-8 Zotero RDF without a DTD.") }
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.localName == "RDF" else { throw ShelfError.message("Choose a Zotero RDF export (.rdf).") }
        var graph: [String: Node] = [:], sequence = 0
        func attr(_ e: XMLElement, _ name: String) -> String? { e.attributes?.first { $0.localName == name }?.stringValue }
        @discardableResult func node(_ e: XMLElement) -> String {
            sequence += 1
            let id = attr(e, "about") ?? attr(e, "nodeID").map { "_:" + $0 } ?? "_:generated\(sequence)"
            var n = graph[id] ?? Node(type: e.localName ?? "Description")
            for property in (e.children ?? []).compactMap({ $0 as? XMLElement }) {
                let key = property.localName ?? ""
                if let resource = attr(property, "resource") { n.fields[key, default: []].append(Value(ref: resource)) }
                else if let ref = attr(property, "nodeID") { n.fields[key, default: []].append(Value(ref: "_:" + ref)) }
                else if let child = property.children?.compactMap({ $0 as? XMLElement }).first { n.fields[key, default: []].append(Value(ref: node(child))) }
                else { n.fields[key, default: []].append(Value(text: property.stringValue ?? "")) }
            }
            graph[id] = n; return id
        }
        for child in (root.children ?? []).compactMap({ $0 as? XMLElement }) { node(child) }
        func text(_ id: String, _ field: String) -> String { graph[id]?.fields[field]?.first?.text ?? "" }
        func refs(_ id: String, _ field: String) -> [String] { graph[id]?.fields[field]?.compactMap(\.ref) ?? [] }
        func type(_ id: String) -> String { graph[id]?.fields["type"]?.first?.ref?.components(separatedBy: "#").last ?? graph[id]?.type ?? "" }
        var plan = MigrationPlan(source: url.path), memberships: [String: Set<String>] = [:]
        let collections = graph.keys.filter { type($0) == "Collection" }.sorted()
        let nested = Set(collections.flatMap { refs($0, "hasPart").filter { collections.contains($0) } })
        func walk(_ id: String, path: [String], visited: Set<String>) throws {
            guard !visited.contains(id), path.count < 40 else { throw ShelfError.message("Cyclic or excessively nested Zotero collections") }
            let title = text(id, "title"); let names = path + [title.isEmpty ? "Untitled collection" : title]
            let name = names.joined(separator: " / "); plan.collections.append(name)
            for child in refs(id, "hasPart") {
                if collections.contains(child) { try walk(child, path: names, visited: visited.union([id])) }
                else { memberships[child, default: []].insert(name) }
            }
        }
        for id in collections where !nested.contains(id) { try walk(id, path: [], visited: []) }
        if !collections.isEmpty && plan.collections.isEmpty { throw ShelfError.message("Cyclic Zotero collections") }
        let linked = Set(graph.keys.flatMap { refs($0, "link") })
        let childNotes = Set(graph.keys.flatMap { refs($0, "isReferencedBy") })
        for id in graph.keys.sorted() {
            let itemType = text(id, "itemType")
            let standaloneNote = (itemType == "note" || type(id) == "Memo") && !childNotes.contains(id)
            guard standaloneNote || (!itemType.isEmpty && itemType != "note" && (itemType != "attachment" || !linked.contains(id))) else { continue }
            let title = text(id, "title")
            var paper = Paper(title: title.isEmpty ? "Untitled Zotero item" : title, filename: "", sourceHash: "")
            paper.metadataOnly = true
            paper.sourceIDs = [id.hasPrefix("https://") || id.hasPrefix("http://") || id.hasPrefix("urn:") ? "zotero:" + id : "zotero-rdf:\(url.standardizedFileURL.path)#\(id)"]
            paper.collections = (memberships[id] ?? []).sorted()
            var c = CitationMetadata()
            c.type = ["book":"book", "bookSection":"chapter", "conferencePaper":"paper-conference", "webpage":"webpage", "thesis":"thesis", "report":"report" ][itemType] ?? "article-journal"
            for sequenceID in refs(id, "authors") {
                let fields = graph[sequenceID]?.fields ?? [:]
                let keys = fields.keys.sorted { a,b in (Int(a.dropFirst()) ?? 0) < (Int(b.dropFirst()) ?? 0) }
                for key in keys where key == "li" || key.hasPrefix("_") {
                    for authorID in refs(sequenceID, key) {
                        let family = text(authorID, "surname"), given = text(authorID, "givenName")
                        c.creators.append(CitationCreator(family: family, given: given, literal: given.isEmpty ? family : nil))
                    }
                }
            }
            paper.authors = c.creators.map { $0.literal ?? [$0.given, $0.family].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "; "); c.authorDisplay = paper.authors
            let date = text(id, "date")
            if let range = date.range(of: #"\b(1[5-9][0-9]{2}|2[0-9]{3})\b"#, options: .regularExpression) { paper.year = String(date[range]) }
            var containers = [id], seen = Set<String>(), frontier = refs(id, "isPartOf")
            while let next = frontier.first { frontier.removeFirst(); if seen.insert(next).inserted && seen.count < 100 { containers.append(next); frontier += refs(next, "isPartOf") } }
            for container in containers {
                if c.journal.isEmpty && ["Journal", "Periodical", "Newspaper", "Book"].contains(type(container)) && container != id { c.journal = text(container, "title") }
                if c.volume.isEmpty { c.volume = text(container, "volume") }; if c.issue.isEmpty { c.issue = text(container, "number") }
                for value in graph[container]?.fields["identifier"] ?? [] {
                    if let t = value.text, t.uppercased().hasPrefix("DOI ") { paper.doi = String(t.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    if let ref = value.ref, type(ref) == "URI" { paper.sourceURL = text(ref, "value") }
                }
            }
            c.pages = text(id, "pages"); c.publisher = refs(id, "publisher").map { text($0, "name") }.joined(separator: "; ")
            paper.citation = c
            paper.tags = (graph[id]?.fields["subject"] ?? []).compactMap { value in value.text ?? value.ref.flatMap { type($0) == "AutomaticTag" ? text($0, "value") : nil } }
            paper.notes = refs(id, "isReferencedBy").map { plainNote(text($0, "value")) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if standaloneNote {
                paper.notes = plainNote(text(id, "value"))
                paper.title = title.isEmpty ? "Zotero note: " + String(paper.notes.prefix(70)) : title
                paper.citation?.type = "manuscript"
            }
            for attachment in refs(id, "link") {
                let note = plainNote(text(attachment, "description"))
                if !note.isEmpty { paper.notes += (paper.notes.isEmpty ? "" : "\n\n") + text(attachment, "title") + ":\n" + note }
            }
            var item = MigrationItem(paper: paper)
            let attachmentIDs = itemType == "attachment" ? [id] : refs(id, "link")
            for attachment in attachmentIDs {
                let pathValue = graph[attachment]?.fields["path"]?.first
                guard let path = pathValue?.ref ?? pathValue?.text, let file = RIS.attachment(path, relativeTo: url.deletingLastPathComponent()), file.pathExtension.lowercased() == "pdf" else {
                    plan.warnings.append("\(paper.title): attachment '\(text(attachment, "title"))' is not a local exported PDF."); continue
                }
                // Export-contained attachments only. Linked external files must be copied into the export by Zotero.
                let base = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
                guard file.resolvingSymlinksInPath().path.hasPrefix(base), FileManager.default.fileExists(atPath: file.path) else {
                    plan.warnings.append("\(paper.title): missing or external attachment \(file.lastPathComponent). Re-export with Export Files enabled."); continue
                }
                item.attachments.append((file, text(attachment, "title")))
            }
            if item.attachments.isEmpty { plan.warnings.append("\(paper.title): reference only; no PDF available.") }
            plan.items.append(item)
        }
        plan.collections = Array(Set(plan.collections)).sorted()
        guard !plan.items.isEmpty else { throw ShelfError.message("No Zotero items found in this RDF export.") }
        return plan
    }
    static func plainNote(_ html: String) -> String {
        // Do not instantiate a WebView or load external resources from exported note HTML.
        html.replacingOccurrences(of: #"(?i)<(?:br\s*/?|/p|/div)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
struct MigrationResult: Sendable {
    var library: Library
    var created: [URL] = []
    var added = 0
    var merged = 0
    var warnings: [String] = []
}
enum Migration {
    static func doi(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "https://doi.org/", with: "").replacingOccurrences(of: "http://dx.doi.org/", with: "").replacingOccurrences(of: "doi:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static func sameReference(_ a: Paper, _ b: Paper) -> Bool {
        func normalized(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if !(Set(a.sourceIDs ?? []).intersection(b.sourceIDs ?? [])).isEmpty { return true }
        if !doi(a.doi).isEmpty && !doi(b.doi).isEmpty { return doi(a.doi) == doi(b.doi) }
        return !a.authors.isEmpty && !a.year.isEmpty && normalized(a.title) == normalized(b.title) && normalized(a.authors) == normalized(b.authors) && a.year == b.year
    }
    static func merge(_ incoming: Paper, into existing: inout Paper) {
        if existing.authors.isEmpty { existing.authors = incoming.authors }
        if existing.year.isEmpty { existing.year = incoming.year }; if existing.doi.isEmpty { existing.doi = incoming.doi }
        if existing.citation == nil { existing.citation = incoming.citation }
        if existing.sourceURL == nil { existing.sourceURL = incoming.sourceURL }
        existing.collections = Array(Set(existing.collections + incoming.collections)).sorted()
        existing.tags = Array(Set(existing.tags + incoming.tags)).sorted()
        existing.sourceIDs = Array(Set((existing.sourceIDs ?? []) + (incoming.sourceIDs ?? []))).sorted()
        if !incoming.notes.isEmpty && !existing.notes.contains(incoming.notes) { existing.notes += (existing.notes.isEmpty ? "" : "\n\n") + incoming.notes }
    }
    static func run(_ plan: MigrationPlan, library: Library, destination: URL) -> MigrationResult {
        var result = MigrationResult(library: library, warnings: plan.warnings)
        result.library.collections = Array(Set(library.collections + plan.collections)).sorted()
        var hashes: [String: UUID] = [:]
        for p in library.papers where p.hasPDF {
            hashes[p.sourceHash] = p.id
            if let hash = try? Importer.hash(destination.appendingPathComponent(p.filename)) { hashes[hash] = p.id }
        }
        for item in plan.items {
            var incoming = item.paper
            var match = result.library.papers.firstIndex { p in
                p.parentID == nil && sameReference(p, incoming)
            }
            // Hash identity is stronger than a missing or incorrect DOI.
            if match == nil, let first = item.attachments.first, let digest = try? Importer.hash(first.url), let id = hashes[digest], let found = result.library.papers.first(where: { $0.id == id }) {
                match = result.library.papers.firstIndex { $0.id == (found.parentID ?? found.id) }
            }
            let primary: Int
            if let match { primary = match; merge(incoming, into: &result.library.papers[match]); result.merged += 1 }
            else { incoming.metadataOnly = true; incoming.filename = ""; primary = result.library.papers.count; result.library.papers.append(incoming); result.added += 1 }
            let parentID = result.library.papers[primary].id
            for attachment in item.attachments {
                autoreleasepool {
                    do {
                        let hash = try Importer.hash(attachment.url)
                        if let existingID = hashes[hash], let index = result.library.papers.firstIndex(where: { $0.id == existingID }) {
                            merge(incoming, into: &result.library.papers[index]); return
                        }
                        guard let pdf = PDFDocument(url: attachment.url), !pdf.isLocked, pdf.pageCount > 0 else { throw ShelfError.message("Unreadable or locked PDF") }
                        let filename = UUID().uuidString + ".pdf", target = destination.appendingPathComponent(filename)
                        try FileManager.default.copyItem(at: attachment.url, to: target); result.created.append(target)
                        if !result.library.papers[primary].hasPDF {
                            result.library.papers[primary].filename = filename; result.library.papers[primary].sourceHash = hash; result.library.papers[primary].metadataOnly = false
                            hashes[hash] = parentID
                        } else {
                            var child = incoming; child.id = UUID(); child.title = attachment.title.isEmpty ? attachment.url.deletingPathExtension().lastPathComponent : attachment.title
                            child.filename = filename; child.sourceHash = hash; child.metadataOnly = false; child.parentID = parentID; child.sourceIDs = nil
                            result.library.papers.append(child); hashes[hash] = child.id
                        }
                    } catch { result.warnings.append("\(attachment.url.lastPathComponent): \(error.localizedDescription)") }
                }
            }
        }
        return result
    }
}
extension ShelfStore {
    func migrate(_ plan: MigrationPlan) {
        guard !importing, writable else { return }
        importing = true
        let snapshot = library, destination = files
        Task {
            let result = await Task.detached { Migration.run(plan, library: snapshot, destination: destination) }.value
            // Preserve page/annotation-era metadata changes made while the import was running.
            guard library.papers == snapshot.papers && library.collections == snapshot.collections else {
                for url in result.created { try? FileManager.default.removeItem(at: url) }
                importing = false; error = "Library changed during migration. No migration was applied; retry when finished reading."; return
            }
            if commit(result.library) {
                let text = "Added \(result.added) references; merged \(result.merged) existing references; copied \(result.created.count) PDFs.\n\n" + (result.warnings.isEmpty ? "No missing attachments reported." : result.warnings.joined(separator: "\n"))
                report = text
                let logs = root.appendingPathComponent("Migration Reports")
                try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                try? ("Source: \(plan.source)\n\(Date())\n\n" + text).write(to: logs.appendingPathComponent("\(UUID()).txt"), atomically: true, encoding: .utf8)
            } else { for url in result.created { try? FileManager.default.removeItem(at: url) } }
            importing = false
        }
    }
}
struct MigrationView: View {
    @ObservedObject var store: ShelfStore
    @State private var plan: MigrationPlan?
    @State private var message = ""
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Migrate from Zotero").font(.title2)
            Text("In Zotero, choose File → Export Library → Zotero RDF. Enable Export Notes, Export Files, and Include Annotations. Keep the .rdf file beside its exported files folder.")
            Text("chimpread copies PDFs and preserves embedded annotations, notes, tags, and collection paths. References without PDFs remain available for citations. Your Zotero library stays untouched.").foregroundStyle(.secondary)
            Button(loading ? "Reading export…" : "Choose Zotero RDF…") { choose() }.disabled(loading || store.importing)
            if let plan {
                Text("\(plan.items.count) references · \(plan.items.reduce(0) { $0 + $1.attachments.count }) PDFs · \(plan.collections.count) collections").font(.headline)
                Text("Matching DOI/source IDs merge metadata; identical PDF hashes are skipped. Different PDFs are retained as supporting files so existing annotations are never replaced.").font(.caption)
                ScrollView { Text(plan.warnings.isEmpty ? "Ready to migrate." : plan.warnings.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 130)
                Button(store.importing ? "Migrating…" : "Start Migration") { store.migrate(plan); self.plan = nil; message = "Migration started. The result will appear in the main window." }.disabled(store.importing)
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
            Text("Zotero annotations stored only in its database cannot be read from unexported storage PDFs. Include Annotations during export.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 550)
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.allowedContentTypes = [UTType(filenameExtension: "rdf") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }; loading = true; message = ""
        Task {
            do { plan = try await Task.detached { try ZoteroRDF.parse(url) }.value }
            catch { message = error.localizedDescription }
            loading = false
        }
    }
}

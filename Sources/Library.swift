import Foundation
import PDFKit
import CryptoKit
import Combine

struct Paper: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var authors: String = ""
    var year: String = ""
    var doi: String = ""
    var tags: [String] = []
    var collections: [String] = []
    var notes: String = ""
    var filename: String
    var sourceHash: String
    var added: Date = Date()
    var starred: Bool = false
    var unread: Bool = true
    var page: Int = 0
    var parentID: UUID?
    var lastOpened: Date?
    var priority: Int?
    var archived: Bool?
    var organizationLocked: Bool?
    var metadataOnly: Bool?
    var citation: CitationMetadata?
    var sourceIDs: [String]?
    var sourceURL: String?
    var hasPDF: Bool { metadataOnly != true && !filename.isEmpty }
}

struct OrganizationUpdate: Codable {
    struct Entry: Codable {
        var id: UUID
        var parentID: UUID?
        var priority: Int?
    }
    var version: Int
    var papers: [Entry]
}

struct Library: Codable, Sendable {
    var version = 1
    var papers: [Paper] = []
    var collections: [String] = []
}

enum ShelfError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct RISRecord: Sendable {
    var fields: [String: [String]] = [:]
    func first(_ keys: String...) -> String {
        for key in keys { if let value = fields[key]?.first { return value } }
        return ""
    }
}

enum RIS {
    static func parse(_ text: String) -> [RISRecord] {
        var result: [RISRecord] = [], record = RISRecord(), lastKey = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\u{feff}", with: "")
            if line.count >= 6, line.dropFirst(2).prefix(4) == "  - " {
                let key = String(line.prefix(2)), value = String(line.dropFirst(6))
                if key == "TY" { record = RISRecord() }
                if key == "ER" { result.append(record); record = RISRecord(); lastKey = ""; continue }
                record.fields[key, default: []].append(value)
                lastKey = key
            } else if line.hasPrefix("ER  -") {
                result.append(record); record = RISRecord(); lastKey = ""
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !lastKey.isEmpty,
                      let count = record.fields[lastKey]?.count, count > 0 {
                record.fields[lastKey]![count - 1] += "\n" + line.trimmingCharacters(in: .whitespaces)
            }
        }
        if !record.fields.isEmpty { result.append(record) }
        return result
    }

    static func attachment(_ value: String, relativeTo directory: URL) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        if value.contains("://") { return nil }
        let decoded = value.removingPercentEncoding ?? value
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded).standardizedFileURL }
        return directory.appendingPathComponent(decoded).standardizedFileURL
    }
}

struct ImportResult: Sendable {
    var papers: [Paper] = []
    var duplicates = 0
    var warnings: [String] = []
}

enum Importer {
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Runs serially off the UI thread. Never modifies an input document.
    static func run(urls: [URL], destination: URL, known: Set<String>, collection: String?) -> ImportResult {
        var result = ImportResult(), hashes = known
        func add(_ url: URL, record: RISRecord? = nil) {
            autoreleasepool {
                do {
                    guard url.pathExtension.lowercased() == "pdf" else { return }
                    let digest = try hash(url)
                    if hashes.contains(digest) { result.duplicates += 1; return }
                    guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                        throw ShelfError.message("Unreadable or password-locked PDF: \(url.lastPathComponent)")
                    }
                    let metadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? ""
                    let metadataAuthor = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? ""
                    let risTitle = record?.first("TI", "T1", "CT") ?? ""
                    let title = !risTitle.isEmpty ? risTitle : (!metadataTitle.isEmpty ? metadataTitle : url.deletingPathExtension().lastPathComponent)
                    let id = UUID(), filename = id.uuidString + ".pdf"
                    try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(filename))
                    var paper = Paper(id: id, title: title, filename: filename, sourceHash: digest)
                    paper.authors = record.map { ($0.fields["AU"] ?? $0.fields["A1"] ?? []).joined(separator: "; ") } ?? metadataAuthor
                    paper.year = String((record?.first("PY", "Y1", "DA") ?? "").prefix(4))
                    paper.doi = record?.first("DO") ?? ""
                    if let record {
                        var citation = CitationMetadata()
                        citation.journal = record.first("JO", "JF", "T2", "JA")
                        citation.volume = record.first("VL"); citation.issue = record.first("IS")
                        citation.pages = [record.first("SP"), record.first("EP")].filter { !$0.isEmpty }.joined(separator: "-")
                        citation.publisher = record.first("PB")
                        if record.first("TY") == "BOOK" { citation.type = "book" }
                        paper.citation = citation
                        let source = record.first("UR"); if !source.isEmpty { paper.sourceURL = source }
                    }
                    paper.tags = Array(Set(record?.fields["KW"] ?? [])).sorted()
                    paper.notes = (record?.fields["N1"] ?? []).joined(separator: "\n\n")
                    if let collection { paper.collections = [collection] }
                    result.papers.append(paper); hashes.insert(digest)
                } catch { result.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        for url in urls {
            if url.pathExtension.lowercased() == "ris" {
                do {
                    let records = RIS.parse(try String(contentsOf: url, encoding: .utf8))
                    if records.isEmpty { result.warnings.append("\(url.lastPathComponent): no RIS records found.") }
                    for record in records {
                        let attachments = (record.fields["L1"] ?? []).compactMap { RIS.attachment($0, relativeTo: url.deletingLastPathComponent()) }.filter { $0.pathExtension.lowercased() == "pdf" }
                        if attachments.isEmpty {
                            result.warnings.append("No local PDF for: \(record.first("TI", "T1"))")
                        }
                        for attachment in attachments { add(attachment, record: record) }
                    }
                } catch { result.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            } else { add(url) }
        }
        return result
    }
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published var importing = false
    @Published var error: String?
    @Published var report: String?
    let root: URL
    private(set) var writable = true
    private var organizationData: Data?
    private var loadedIndex: Data?
    var files: URL { root.appendingPathComponent("PDFs", isDirectory: true) }
    var index: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PaperShelf", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: index.path) {
                let data = try Data(contentsOf: index)
                library = try JSONDecoder().decode(Library.self, from: data)
                try Self.validate(library)
                loadedIndex = data
                guard library.version == 1 else { throw ShelfError.message("Unsupported library version. Your files have not been changed.") }
            }
        } catch { writable = false; self.error = "Could not open library: \(error.localizedDescription)" }
    }

    static func validate(_ library: Library) throws {
        guard library.version == 1, Set(library.papers.map(\.id)).count == library.papers.count else {
            throw ShelfError.message("Invalid library version or duplicate paper IDs.")
        }
        let papers = Dictionary(uniqueKeysWithValues: library.papers.map { ($0.id, $0) })
        for paper in library.papers {
            guard (paper.metadataOnly == true && paper.filename.isEmpty) || (!paper.filename.isEmpty && paper.filename == URL(fileURLWithPath: paper.filename).lastPathComponent && paper.filename.lowercased().hasSuffix(".pdf")) else { throw ShelfError.message("Invalid managed PDF filename.") }
            if let parent = paper.parentID {
                guard parent != paper.id, let main = papers[parent], main.parentID == nil else {
                    throw ShelfError.message("Invalid supporting-file relationship.")
                }
            }
        }
    }
    @discardableResult func commit(_ value: Library) -> Bool {
        guard writable else { error = "Library is read-only because it could not be loaded safely."; return false }
        do {
            try Self.validate(value)
            let disk = try? Data(contentsOf: index)
            guard disk == loadedIndex else { throw ShelfError.message("The library changed in another process. Reopen chimpread before editing; your files were not overwritten.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            if FileManager.default.fileExists(atPath: index.path) {
                try Data(contentsOf: index).write(to: root.appendingPathComponent("library.previous.json"), options: .atomic)
            }
            try data.write(to: index, options: .atomic)
            library = value
            loadedIndex = data
            error = nil
            return true
        } catch { self.error = "Could not save library: \(error.localizedDescription)"; return false }
    }

    func update(_ paper: Paper) {
        guard let i = library.papers.firstIndex(where: { $0.id == paper.id }) else { return }
        var next = library; next.papers[i] = paper; commit(next)
    }
    func markOpened(_ id: UUID) {
        guard let i = library.papers.firstIndex(where: { $0.id == id }) else { return }
        var next = library
        let now = Date()
        next.papers[i].lastOpened = now
        if let parent = next.papers[i].parentID,
           let j = next.papers.firstIndex(where: { $0.id == parent }) {
            next.papers[j].lastOpened = now
        }
        commit(next)
    }

    // Hermes writes only a small sidecar. The running app remains the sole index writer.
    @discardableResult func refreshOrganization() -> Bool {
        guard writable, !importing,
              let data = try? Data(contentsOf: root.appendingPathComponent("organization.json")),
              data != organizationData else { return false }
        do {
            let plan = try JSONDecoder().decode(OrganizationUpdate.self, from: data)
            guard plan.version == 1, Set(plan.papers.map(\.id)).count == plan.papers.count else { return false }
            var next = library
            let indices = Dictionary(uniqueKeysWithValues: next.papers.enumerated().map { ($0.element.id, $0.offset) })
            for entry in plan.papers {
                guard let i = indices[entry.id], next.papers[i].organizationLocked != true else { continue }
                if let parent = entry.parentID {
                    guard parent != entry.id, indices[parent] != nil else { return false }
                    next.papers[i].parentID = parent
                }
                if let priority = entry.priority { next.papers[i].priority = priority }
            }
            // A single supporting-file level prevents cycles and hidden nested documents.
            for paper in next.papers {
                if let parent = paper.parentID {
                    guard let i = indices[parent], next.papers[i].parentID == nil else { return false }
                }
            }
            if next.papers != library.papers && !commit(next) { return false }
            organizationData = data
            return true
        } catch { return false } // An incomplete/bad suggestion never damages the library.
    }
    @discardableResult func renameCollection(_ old: String, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, library.collections.contains(old) else { return false }
        var next = library
        next.collections = Array(Set(next.collections.map { $0 == old ? name : $0 })).sorted()
        for i in next.papers.indices {
            next.papers[i].collections = Array(Set(next.papers[i].collections.map { $0 == old ? name : $0 })).sorted()
        }
        return commit(next)
    }
    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let paper = library.papers.first(where: { $0.id == id }) else { return }
        var next = library
        // Keep a paper and its attachments together, and preserve each attachment's own status.
        if let i = next.papers.firstIndex(where: { $0.id == paper.id }) { next.papers[i].archived = archived }
        _ = commit(next)
    }
    func setParent(_ id: UUID, to parent: UUID?) {
        guard let i = library.papers.firstIndex(where: { $0.id == id }) else { return }
        var next = library
        next.papers[i].parentID = parent
        next.papers[i].organizationLocked = true
        _ = commit(next)
    }
    func addCollection(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !library.collections.contains(name) else { return }
        var next = library; next.collections.append(name); next.collections.sort(); commit(next)
    }
    func importFiles(_ urls: [URL], collection: String? = nil) {
        guard !importing, writable else { return }
        importing = true
        let destination = files, known = Set(library.papers.map(\.sourceHash))
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Importer.run(urls: urls, destination: destination, known: known, collection: collection)
            }.value
            var next = library; next.papers.append(contentsOf: result.papers)
            if commit(next) {
                report = "Imported \(result.papers.count) PDFs. Skipped \(result.duplicates) identical files." + (result.warnings.isEmpty ? "" : "\n\nNeeds attention:\n" + result.warnings.joined(separator: "\n"))
            } else {
                // Roll back only files created by this import, never existing library data.
                for paper in result.papers { try? FileManager.default.removeItem(at: files.appendingPathComponent(paper.filename)) }
            }
            importing = false
        }
    }
}

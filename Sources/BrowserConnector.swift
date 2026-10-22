import Foundation
import AppKit
import SwiftUI
import PDFKit

struct BrowserAccess: Codable {
    var enabled = false
    static func read(_ root: URL) -> BrowserAccess { (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("browser-access.json")))) ?? Self() }
    func save(_ root: URL) throws { try JSONEncoder().encode(self).write(to: root.appendingPathComponent("browser-access.json"), options: .atomic) }
}
struct BrowserCapture: Codable {
    var title: String
    var authors: [String]
    var year: String
    var doi: String
    var journal: String
    var volume: String
    var issue: String
    var pages: String
    var url: String
    var collection: String
    var localPDF: String?
    var captureID: String
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 2000,
              authors.count <= 200, authors.allSatisfy({ $0.count <= 300 }),
              [year, doi, journal, volume, issue, pages, collection].allSatisfy({ $0.count <= 1000 }),
              url.count <= 8000, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil, parsed.user == nil, parsed.password == nil,
              UUID(uuidString: captureID) != nil else { throw ShelfError.message("Invalid browser capture") }
        if let localPDF { _ = try Self.pdfURL(localPDF) }
    }
    static func pdfURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("chimpread", isDirectory: true).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == downloads, url.pathExtension.lowercased() == "pdf" else { throw ShelfError.message("Browser PDFs must be downloaded into Downloads/chimpread") }
        return url
    }
    var paper: Paper {
        var p = Paper(title: title, filename: "", sourceHash: "")
        p.metadataOnly = true; p.authors = authors.joined(separator: "; "); p.year = year; p.doi = doi; p.sourceURL = url
        p.collections = collection.isEmpty ? [] : [collection]
        p.sourceIDs = ["browser:" + url, "capture:" + captureID]
        var c = CitationMetadata(); c.type = journal.isEmpty && doi.isEmpty ? "webpage" : "article-journal"; c.journal = journal; c.volume = volume; c.issue = issue; c.pages = pages; p.citation = c
        return p
    }
}
@MainActor final class BrowserHost {
    let root: URL
    init(root: URL) { self.root = root }
    static var extensionID: String { ((try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("chrome-extension-id.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func handle(_ request: [String: Any]) -> [String: Any] {
        do {
            guard BrowserAccess.read(root).enabled else { throw ShelfError.message("Enable Chrome Connector in chimpread → Integrations first.") }
            let action = request["action"] as? String ?? ""
            if action == "capture" {
                guard let payload = request["capture"] as? [String: Any] else { throw ShelfError.message("Missing capture") }
                let capture = try JSONDecoder().decode(BrowserCapture.self, from: JSONSerialization.data(withJSONObject: payload))
                try capture.validate()
                let inbox = root.appendingPathComponent("Browser Inbox")
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                guard try FileManager.default.contentsOfDirectory(atPath: inbox.path).count < 1000 else { throw ShelfError.message("Browser inbox is full; open chimpread to process it") }
                try JSONEncoder().encode(capture).write(to: inbox.appendingPathComponent(capture.captureID + ".json"), options: .atomic)
                return ["ok": true, "message": "Queued for chimpread. Open the app to finish importing."]
            }
            let index = root.appendingPathComponent("library.json")
            let library = FileManager.default.fileExists(atPath: index.path) ? try JSONDecoder().decode(Library.self, from: Data(contentsOf: index)) : Library()
            try ShelfStore.validate(library)
            if action == "search" {
                let query = String((request["query"] as? String ?? "").prefix(1000))
                let items = library.papers.filter { $0.parentID == nil && $0.archived != true && (query.isEmpty || ($0.title + " " + $0.authors + " " + $0.doi).localizedCaseInsensitiveContains(query)) }.sorted { $0.title < $1.title }
                return ["ok": true, "total": items.count, "collections": library.collections, "papers": items.prefix(50).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(2000)), "authors": String($0.authors.prefix(2000)), "year": $0.year, "hasPDF": $0.hasPDF] as [String: Any] }]
            }
            if action == "bibliography" || action == "citation" {
                guard let raw = request["ids"] as? [String], !raw.isEmpty, raw.count <= 50, Set(raw).count == raw.count,
                      let style = CitationStyle(rawValue: request["style"] as? String ?? "APA 7") else { throw ShelfError.message("Select 1–50 papers and a supported citation style") }
                let papers = try raw.map { id -> Paper in guard let p = library.papers.first(where: { $0.id.uuidString == id && $0.parentID == nil }) else { throw ShelfError.message("Reference no longer exists") }; return p }
                return ["ok": true, "text": try Citations.render(papers, style: style, inline: action == "citation")]
            }
            throw ShelfError.message("Unknown browser action")
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
    func run() {
        guard CommandLine.arguments.contains("chrome-extension://\(Self.extensionID)/") else { return }
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        func exact(_ count: Int) -> Data? {
            var data = Data()
            while data.count < count { guard let part = try? input.read(upToCount: count - data.count), !part.isEmpty else { return nil }; data.append(part) }
            return data
        }
        while let header = exact(4) {
            let count = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard count > 0, count <= 131072, let data = exact(count) else { return }
            autoreleasepool {
                let response: [String: Any]
                if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { response = handle(request) }
                else { response = ["ok": false, "error": "Invalid JSON"] }
                var encoded = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
                if encoded.count > 900000 { encoded = Data("{\"ok\":false,\"error\":\"Response too large; select fewer papers\"}".utf8) }
                let size = UInt32(encoded.count).littleEndian
                withUnsafeBytes(of: size) { output.write(Data($0)) }; output.write(encoded)
            }
        }
    }
    static func extensionFolder(root: URL) throws -> URL {
        let target = root.appendingPathComponent("Chrome Connector/Extension")
        let source = Bundle.main.resourceURL!.appendingPathComponent("ChromeExtension")
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
        return target
    }
    static func install(root: URL) throws {
        let support = root.appendingPathComponent("Chrome Connector")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let launcher = support.appendingPathComponent("host.sh")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nexec " + quote(Bundle.main.executableURL!.path) + " --native-host --library " + quote(root.path) + " \"$@\"\n"
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": "local.chimpread.connector", "description": "chimpread local library connector", "path": launcher.path, "type": "stdio", "allowed_origins": ["chrome-extension://\(extensionID)/"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("local.chimpread.connector.json"), options: .atomic)
        try BrowserAccess(enabled: true).save(root)
    }
}
extension ShelfStore {
    func processBrowserInbox() {
        guard writable, !importing, BrowserAccess.read(root).enabled else { return }
        let inbox = root.appendingPathComponent("Browser Inbox")
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil), let file = files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else { return }
        importing = true
        let original = library, destination = self.files
        Task {
            do {
                let capture = try JSONDecoder().decode(BrowserCapture.self, from: Data(contentsOf: file)); try capture.validate()
                var item = MigrationItem(paper: capture.paper)
                if let path = capture.localPDF { item.attachments = [(try BrowserCapture.pdfURL(path), capture.title)] }
                let plan = MigrationPlan(items: [item], collections: capture.collection.isEmpty ? [] : [capture.collection], source: "Chrome")
                let result = await Task.detached { Migration.run(plan, library: original, destination: destination) }.value
                if library.papers != original.papers || library.collections != original.collections {
                    for created in result.created { try? FileManager.default.removeItem(at: created) }
                    importing = false; return // Retry next tick without losing the queued capture.
                }
                guard commit(result.library) else { for created in result.created { try? FileManager.default.removeItem(at: created) }; importing = false; return }
                let processed = root.appendingPathComponent("Browser Imports")
                try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: file, to: processed.appendingPathComponent(file.lastPathComponent))
                if !result.warnings.isEmpty { report = result.warnings.joined(separator: "\n") }
            } catch {
                self.error = "Browser import needs attention: \(error.localizedDescription)"
                // Keep rejected payload for inspection without retrying an invalid request every tick.
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("rejected"))
            }
            importing = false
        }
    }
    func attachPDF(_ url: URL, to id: UUID) {
        guard !importing, let paper = library.papers.first(where: { $0.id == id }), !paper.hasPDF else { return }
        let plan = MigrationPlan(items: [MigrationItem(paper: paper, attachments: [(url, paper.title)])], collections: paper.collections, source: url.path)
        // Stable ID makes a reference without DOI match itself.
        var updated = paper; updated.sourceIDs = Array(Set((paper.sourceIDs ?? []) + ["chimpread:" + id.uuidString])); update(updated)
        guard error == nil else { return }
        var input = plan; input.items[0].paper = updated; migrate(input)
    }
}
struct BrowserSettings: View {
    let root: URL
    @State private var enabled = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chrome & Google Docs").font(.headline)
            Text("Chrome can search citation metadata and send papers to your local inbox. PDFs and notes are not exposed to Chrome. Google Docs receives only citations you explicitly insert.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(enabled ? "Disable Chrome Connector" : "Enable Chrome Connector") {
                    do { if enabled { try BrowserAccess().save(root) } else { try BrowserHost.install(root: root) }; enabled.toggle(); message = enabled ? "Local bridge installed. Load the extension folder in chrome://extensions." : "Chrome access disabled." } catch { message = error.localizedDescription }
                }
                Button("Show Extension") { do { NSWorkspace.shared.open(try BrowserHost.extensionFolder(root: root)) } catch { message = error.localizedDescription } }
            }
            Text("Load unpacked in chrome://extensions. Google Docs API setup is in the extension’s Settings; the Docs connection remains off until configured and authorized.").font(.caption)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }.onAppear { enabled = BrowserAccess.read(root).enabled }
    }
}

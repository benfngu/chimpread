import AppKit
import SwiftUI
import CryptoKit

// Immutable per-paper revisions and content-addressed PDFs tolerate reordered iCloud delivery.
// The local library remains authoritative until a complete, validated sync can be committed.
struct CloudRevision: Codable, Sendable {
    var id = UUID()
    var parents: [UUID]
    var date = Date()
    var paper: Paper
    var pdfHash: String?
}
struct CloudState: Codable, Sendable {
    var heads: [String: [UUID]] = [:]
    var fingerprints: [String: String] = [:]
}
struct CloudPlan: Sendable {
    var library: Library
    var state: CloudState
    var staged: [String: URL]
    var conflicts: Int
    var stage: URL
}
enum CloudSync {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func fingerprint(_ paper: Paper, hash: String?) throws -> String {
        var data = try encoded(paper); data.append(Data((hash ?? "").utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func ready(_ url: URL) throws {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]), values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw ShelfError.message("iCloud is downloading files. Keep this Mac online, then Sync Now again.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw ShelfError.message("Waiting for iCloud to deliver \(url.lastPathComponent). Try again after Finder finishes syncing.")
        }
    }
    static func conflictID(_ id: UUID, _ hash: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((id.uuidString + hash).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func run(library: Library, root: URL, cloud: URL) throws -> CloudPlan {
        let fm = FileManager.default
        let records = cloud.appendingPathComponent("Revisions"), blobs = cloud.appendingPathComponent("PDFs")
        for dir in [records, blobs] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let stateURL = root.appendingPathComponent("cloud-state.json")
        let state = fm.fileExists(atPath: stateURL.path) ? try JSONDecoder().decode(CloudState.self, from: Data(contentsOf: stateURL)) : CloudState()
        var localHashes: [UUID: String] = [:]
        for paper in library.papers {
            let key = paper.id.uuidString
            let source = root.appendingPathComponent("PDFs").appendingPathComponent(paper.filename)
            let hash = paper.hasPDF ? try Importer.hash(source) : nil
            localHashes[paper.id] = hash
            if try fingerprint(paper, hash: hash) == state.fingerprints[key] { continue }
            if let hash {
                let target = blobs.appendingPathComponent(hash + ".pdf")
                if !fm.fileExists(atPath: target.path) {
                    let temporary = blobs.appendingPathComponent(".\(UUID()).tmp")
                    try fm.copyItem(at: source, to: temporary)
                    do { try fm.moveItem(at: temporary, to: target) }
                    catch { try? fm.removeItem(at: temporary); if !fm.fileExists(atPath: target.path) { throw error } }
                }
            }
            let parents = (state.heads[key] ?? []).sorted { $0.uuidString < $1.uuidString }
            let versionKey = try fingerprint(paper, hash: hash) + parents.map(\.uuidString).joined()
            let revision = CloudRevision(id: conflictID(paper.id, versionKey), parents: parents, paper: paper, pdfHash: hash)
            let revisionURL = records.appendingPathComponent(revision.id.uuidString + ".json")
            if !fm.fileExists(atPath: revisionURL.path) { try encoded(revision).write(to: revisionURL, options: .atomic) }
        }
        var revisions: [CloudRevision] = []
        for file in try fm.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) {
            if file.lastPathComponent.hasSuffix(".icloud") { try? fm.startDownloadingUbiquitousItem(at: file); throw ShelfError.message("iCloud revisions are still downloading. Try Sync Now again shortly.") }
            guard file.pathExtension == "json" else { continue }
            try ready(file)
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 8_000_000 else { throw ShelfError.message("Sync revision is too large.") }
            let revision = try JSONDecoder().decode(CloudRevision.self, from: Data(contentsOf: file))
            guard file.deletingPathExtension().lastPathComponent == revision.id.uuidString,
                  revision.pdfHash == nil || revision.pdfHash!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  revision.paper.hasPDF == (revision.pdfHash != nil) else { throw ShelfError.message("Invalid cloud revision. Local library unchanged.") }
            revisions.append(revision)
        }
        let stage = root.appendingPathComponent(".sync-stage-\(UUID())")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            var next = library, nextState = CloudState(), staged: [String: URL] = [:], conflicts = 0
            var merged: [UUID: Paper] = [:]
            for (id, history) in Dictionary(grouping: revisions, by: { $0.paper.id }) {
                let ancestors = Set(history.flatMap(\.parents))
                let heads = history.filter { !ancestors.contains($0.id) }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
                guard let newest = heads.last else { throw ShelfError.message("Cyclic cloud history. Local library unchanged.") }
                var paper = newest.paper
                nextState.heads[id.uuidString] = heads.map(\.id)
                if heads.count > 1 {
                    conflicts += 1
                    let notes = Array(Set(heads.map { $0.paper.notes }.filter { !$0.isEmpty })).sorted()
                    if notes.count > 1 { paper.notes = notes.joined(separator: "\n\n— Concurrent note preserved by iCloud sync —\n\n") }
                    paper.tags = Array(Set(heads.flatMap { $0.paper.tags })).sorted()
                    paper.collections = Array(Set(heads.flatMap { $0.paper.collections })).sorted()
                }
                func materialize(_ hash: String, paper: inout Paper) throws {
                    if let local = library.papers.first(where: { $0.id == paper.id }), localHashes[paper.id] == hash {
                        paper.filename = local.filename; return
                    }
                    let source = blobs.appendingPathComponent(hash + ".pdf"); try ready(source)
                    guard try Importer.hash(source) == hash else { throw ShelfError.message("Cloud PDF checksum mismatch. Local files unchanged.") }
                    let filename = paper.id.uuidString + "-" + hash.prefix(12) + ".pdf"
                    let target = stage.appendingPathComponent(filename)
                    if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: source, to: target) }; staged[filename] = target; paper.filename = filename
                }
                if let hash = newest.pdfHash { try materialize(hash, paper: &paper) }
                merged[id] = paper
                nextState.fingerprints[id.uuidString] = try fingerprint(paper, hash: newest.pdfHash)
                // Concurrent annotated PDFs cannot be safely flattened into one PDFKit document.
                // Preserve each distinct version as a deterministic supporting file on every Mac.
                for hash in Set(heads.compactMap(\.pdfHash)).subtracting(Set([newest.pdfHash].compactMap { $0 })) {
                    var alternate = paper
                    alternate.id = conflictID(id, hash); alternate.parentID = paper.parentID ?? id
                    alternate.title += " — sync conflict " + hash.prefix(6)
                    alternate.organizationLocked = true; alternate.sourceHash = hash
                    try materialize(hash, paper: &alternate)
                    if merged[alternate.id] == nil { merged[alternate.id] = alternate }
                }
            }
            // Include records created locally; immutable remote history never deletes a paper.
            for paper in library.papers where merged[paper.id] == nil { merged[paper.id] = paper }
            next.papers = merged.values.sorted { $0.id.uuidString < $1.id.uuidString }
            let byID = Dictionary(uniqueKeysWithValues: next.papers.map { ($0.id, $0) })
            for i in next.papers.indices {
                if let parent = next.papers[i].parentID, parent == next.papers[i].id || byID[parent] == nil || byID[parent]?.parentID != nil {
                    next.papers[i].parentID = nil; conflicts += 1
                }
            }
            next.collections = Array(Set(library.collections + next.papers.flatMap(\.collections))).sorted()
            return CloudPlan(library: next, state: nextState, staged: staged, conflicts: conflicts, stage: stage)
        } catch { try? fm.removeItem(at: stage); throw error }
    }
}

@MainActor final class CloudController: ObservableObject {
    @Published var folder: URL?
    @Published var status = "Off · your library stays on this Mac"
    @Published var busy = false
    private let store: ShelfStore
    private let reader: Reader
    private var timer: Timer?
    private var bookmarkURL: URL { store.root.appendingPathComponent("cloud-folder.bookmark") }
    init(store: ShelfStore, reader: Reader) {
        self.store = store; self.reader = reader
        if let data = try? Data(contentsOf: bookmarkURL) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale), !stale {
                folder = url; status = "Connected · sync resumes when the reader is closed"
            } else { status = "Choose your iCloud folder again to reconnect." }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.folder != nil, self.reader.paperID == nil, !self.store.importing else { return }
                self.sync()
            }
        }
        timer?.tolerance = 15
    }
    func choose() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose or create a dedicated chimpread folder in iCloud Drive. Choose the same folder on your other Mac. Saved papers and notes will be copied to your Apple account."
        panel.prompt = "Use for Sync"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").resolvingSymlinksInPath().path
        let path = selected.resolvingSymlinksInPath().path
        guard path.hasPrefix(drive + "/") else { status = "Choose a dedicated folder inside iCloud Drive, not its root."; return }
        do {
            if let existing = folder, existing.standardizedFileURL != selected.standardizedFileURL {
                status = "Disconnect the current folder before choosing another."; return
            }
            try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).write(to: bookmarkURL, options: .atomic)
            folder = selected; status = "Connected · press Sync Now to copy saved papers and notes"
        } catch { status = error.localizedDescription }
    }
    func disconnect() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: bookmarkURL.path) { try FileManager.default.removeItem(at: bookmarkURL) }
            let state = store.root.appendingPathComponent("cloud-state.json")
            if FileManager.default.fileExists(atPath: state.path) { try FileManager.default.removeItem(at: state) }
            folder = nil; status = "Disconnected · both local and iCloud copies are retained"
        } catch { status = error.localizedDescription }
    }
    func sync() {
        guard let folder, !busy, !store.importing, store.writable else { return }
        guard reader.open(nil, in: store.files) else { status = reader.error ?? "Save the open paper first."; return }
        let original = store.library, root = store.root
        busy = true; store.importing = true; store.syncing = true; status = "Syncing saved papers and notes…"
        Task {
            defer { busy = false; store.importing = false; store.syncing = false }
            do {
                let plan = try await Task.detached(priority: .utility) { try CloudSync.run(library: original, root: root, cloud: folder) }.value
                defer { try? FileManager.default.removeItem(at: plan.stage) }
                guard store.library.papers == original.papers, store.library.collections == original.collections else { throw ShelfError.message("Library changed during sync. Retry; no local edits were replaced.") }
                try ShelfStore.validate(plan.library)
                var copied: [URL] = []
                do {
                    for (name, source) in plan.staged {
                        let target = store.files.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: target.path) {
                            guard try Importer.hash(target) == Importer.hash(source) else { throw ShelfError.message("Local PDF differs from incoming version.") }
                        } else { try FileManager.default.copyItem(at: source, to: target); copied.append(target) }
                    }
                    guard store.commit(plan.library) else { throw ShelfError.message(store.error ?? "Could not commit sync.") }
                } catch { for file in copied { try? FileManager.default.removeItem(at: file) }; throw error }
                try CloudSync.encoded(plan.state).write(to: root.appendingPathComponent("cloud-state.json"), options: .atomic)
                let used = Set(plan.library.papers.map(\.filename))
                for paper in original.papers where paper.hasPDF && !used.contains(paper.filename) {
                    let recovery = root.appendingPathComponent("Sync Recovery")
                    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
                    let old = store.files.appendingPathComponent(paper.filename)
                    if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.moveItem(at: old, to: recovery.appendingPathComponent(UUID().uuidString + ".pdf")) }
                }
                status = "Checked \(Date().formatted(date: .omitted, time: .shortened)) · \(plan.library.papers.count) papers" + (plan.conflicts > 0 ? " · \(plan.conflicts) conflicts preserved; review notes and supporting files" : "") + ". iCloud delivery may still be pending."
            } catch { status = "Sync paused: \(error.localizedDescription)" }
        }
    }
}
struct CloudSettings: View {
    @ObservedObject var cloud: CloudController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iCloud Drive").font(.title2)
            Text("Use the same dedicated iCloud Drive folder on your Macs. Papers, saved annotations, notes, tags, and reading positions sync. Unfinished drafts and integration permissions stay on this Mac.").font(.callout)
            if let folder = cloud.folder { Text(folder.lastPathComponent).font(.headline) }
            HStack {
                if cloud.folder == nil { Button("Choose iCloud Folder…") { cloud.choose() } }
                else {
                    Button("Sync Now") { cloud.sync() }
                    Button("Show Folder") { if let url = cloud.folder { NSWorkspace.shared.open(url) } }
                    Button("Disconnect") { cloud.disconnect() }
                }
                if cloud.busy { ProgressView().controlSize(.small) }
            }.disabled(cloud.busy)
            Text(cloud.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Sync Now saves and closes the current paper. Automatic checks run every minute while the reader is closed. Wait for Finder’s upload to finish before switching Macs. Concurrent notes and PDF versions are retained; other conflicting details use the latest synced revision. This early sync feature has not yet been tested across two real iCloud devices.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 490)
    }
}

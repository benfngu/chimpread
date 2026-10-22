import Foundation
import PDFKit

@MainActor func auditLibrary(_ root: URL) throws {
    let index = root.appendingPathComponent("library.json")
    let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: index))
    try ShelfStore.validate(library)
    var problems: [[String: String]] = [], hashes: [String: [String]] = [:], sourceHashes: [String: [String]] = [:]
    var totalPages = 0, readable = 0, annotated = 0
    for paper in library.papers where paper.hasPDF {
        autoreleasepool {
            let url = root.appendingPathComponent("PDFs").appendingPathComponent(paper.filename)
            do {
                let hash = try Importer.hash(url)
                hashes[hash, default: []].append(paper.id.uuidString)
                sourceHashes[paper.sourceHash, default: []].append(paper.id.uuidString)
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw ShelfError.message("Unreadable or locked PDF") }
                readable += 1; totalPages += document.pageCount
                if !Reader.annotationRows(in: document).isEmpty { annotated += 1 }
                if paper.page < 0 || paper.page >= document.pageCount { problems.append(["id": paper.id.uuidString, "issue": "Saved reading page is outside PDF bounds"]) }
                for collection in paper.collections where !library.collections.contains(collection) { problems.append(["id": paper.id.uuidString, "issue": "Collection missing from sidebar: \(collection)"]) }
            } catch { problems.append(["id": paper.id.uuidString, "issue": error.localizedDescription]) }
        }
    }
    let indexed = Set(library.papers.map(\.filename))
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("PDFs").path)
    let report: [String: Any] = ["papers": library.papers.count, "main_papers": library.papers.filter { $0.parentID == nil }.count,
        "metadata_only": library.papers.filter { !$0.hasPDF }.count, "supporting_files": library.papers.filter { $0.parentID != nil }.count, "readable_pdfs": readable, "pages": totalPages,
        "annotated_pdfs": annotated, "identical_managed_files": Array(hashes.values.filter { $0.count > 1 }),
        "repeated_import_hashes": Array(sourceHashes.values.filter { $0.count > 1 }), "problems": problems,
        "unindexed_pdfs": files.filter { $0.lowercased().hasSuffix(".pdf") && !indexed.contains($0) }.sorted(),
        "collections": library.collections.map { name in ["name": name, "main_papers": library.papers.filter { $0.parentID == nil && $0.collections.contains(name) }.count] as [String: Any] }]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

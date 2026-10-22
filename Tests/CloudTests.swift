import Foundation
import PDFKit

@MainActor func runCloudTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw ShelfError.message(name) }; print("PASS \(name)")
    }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("chimpread-cloud-tests-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), cloud = root.appendingPathComponent("Cloud")
    let sa = ShelfStore(root: a), sb = ShelfStore(root: b)
    let pdf = sa.files.appendingPathComponent("sample.pdf"); try fixturePDF(at: pdf, title: "Sync fixture")
    var p = Paper(title: "Cloud paper", notes: "Original note", filename: "sample.pdf", sourceHash: try Importer.hash(pdf))
    p.collections = ["Reading"]; try check(sa.commit(Library(papers: [p], collections: ["Reading"])), "Create isolated cloud fixture")
    func apply(_ plan: CloudPlan, _ store: ShelfStore) throws {
        defer { try? fm.removeItem(at: plan.stage) }
        for (name, file) in plan.staged {
            let dest = store.files.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: file, to: dest) }
        }
        try check(store.commit(plan.library), "Commit synchronized library")
        try CloudSync.encoded(plan.state).write(to: store.root.appendingPathComponent("cloud-state.json"), options: .atomic)
    }
    try apply(CloudSync.run(library: sa.library, root: a, cloud: cloud), sa)
    try apply(CloudSync.run(library: sb.library, root: b, cloud: cloud), sb)
    try check(sb.library.papers.count == 1 && sb.library.papers[0].notes == p.notes, "Cloud transfers papers and saved notes to a second local replica")
    let copiedHash = try Importer.hash(sb.files.appendingPathComponent(sb.library.papers[0].filename))
    try check(copiedHash == p.sourceHash, "Cloud preserves exact PDF bytes")
    let records = cloud.appendingPathComponent("Revisions")
    let before = try fm.contentsOfDirectory(atPath: records.path).count
    try apply(CloudSync.run(library: sb.library, root: b, cloud: cloud), sb)
    let after = try fm.contentsOfDirectory(atPath: records.path).count
    try check(after == before, "Repeat sync does not create revisions or duplicate papers")
    var pa = sa.library.papers[0]; pa.notes = "Note written on A"; sa.update(pa)
    var pb = sb.library.papers[0]; pb.notes = "Note written on B"; sb.update(pb)
    let altered = PDFDocument(url: sb.files.appendingPathComponent(pb.filename))!
    let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .text, withProperties: nil)
    note.contents = "B PDF edit"; altered.page(at: 0)!.addAnnotation(note)
    try check(altered.write(to: sb.files.appendingPathComponent(pb.filename)), "Create concurrent annotated PDF")
    try apply(CloudSync.run(library: sa.library, root: a, cloud: cloud), sa)
    let conflict = try CloudSync.run(library: sb.library, root: b, cloud: cloud)
    try check(conflict.conflicts == 1 && conflict.library.papers.count == 2, "Concurrent PDF versions retained as supporting files")
    let merged = conflict.library.papers.first { $0.id == p.id }!
    try check(merged.notes.contains("Note written on A") && merged.notes.contains("Note written on B"), "Concurrent note text preserved from both replicas")
    try apply(conflict, sb)
    try apply(CloudSync.run(library: sa.library, root: a, cloud: cloud), sa)
    try apply(CloudSync.run(library: sb.library, root: b, cloud: cloud), sb)
    try apply(CloudSync.run(library: sa.library, root: a, cloud: cloud), sa)
    try check(sa.library.papers.count == 2 && sb.library.papers.count == 2, "Conflicts converge without repeated duplicate attachments")
    let bad = CloudRevision(parents: [], paper: Paper(title: "Pending", filename: "pending.pdf", sourceHash: ""), pdfHash: String(repeating: "a", count: 64))
    try CloudSync.encoded(bad).write(to: records.appendingPathComponent(bad.id.uuidString + ".json"))
    let prior = sa.library.papers
    do { _ = try CloudSync.run(library: sa.library, root: a, cloud: cloud); throw ShelfError.message("Missing cloud blob should stop sync") }
    catch { try check(error.localizedDescription.contains("Waiting for iCloud"), "Incomplete cloud delivery pauses sync") }
    try check(sa.library.papers == prior, "Incomplete sync leaves local library unchanged")
    try Data("corrupt PDF".utf8).write(to: cloud.appendingPathComponent("PDFs").appendingPathComponent(String(repeating: "a", count: 64) + ".pdf"))
    do { _ = try CloudSync.run(library: sa.library, root: a, cloud: cloud); throw ShelfError.message("Corrupt cloud blob should stop sync") }
    catch { try check(error.localizedDescription.contains("checksum mismatch"), "Corrupt cloud content rejected before local merge") }
    print("All cloud sync tests passed.")
}

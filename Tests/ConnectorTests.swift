import Foundation
import PDFKit

@MainActor func runConnectorTests() throws {
    func check(_ value: @autoclosure () -> Bool, _ name: String) throws { guard value() else { throw ShelfError.message(name) }; print("PASS \(name)") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chimpread-connectors-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let export = root.appendingPathComponent("export"); try FileManager.default.createDirectory(at: export.appendingPathComponent("files"), withIntermediateDirectories: true)
    let pdf = export.appendingPathComponent("files/paper.pdf"); try fixturePDF(at: pdf, title: "Migrated paper")
    let document = PDFDocument(url: pdf)!, annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 30, height: 30), forType: .text, withProperties: nil)
    annotation.contents = "Preserve this Zotero note"; document.page(at: 0)!.addAnnotation(annotation); try check(document.write(to: pdf), "Create annotated migration fixture")
    let hash = try Importer.hash(pdf)
    let rdf = """
    <?xml version="1.0"?><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:z="http://www.zotero.org/namespaces/export#" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:bib="http://purl.org/net/biblio#" xmlns:foaf="http://xmlns.com/foaf/0.1/" xmlns:link="http://purl.org/rss/1.0/modules/link/" xmlns:prism="http://prismstandard.org/namespaces/1.2/basic/">
    <z:Collection rdf:about="#c"><dc:title>FITdb</dc:title><dcterms:hasPart rdf:resource="#sub"/></z:Collection>
    <z:Collection rdf:about="#sub"><dc:title>Reading</dc:title><dcterms:hasPart rdf:resource="#item"/><dcterms:hasPart rdf:resource="#missing"/></z:Collection>
    <bib:Article rdf:about="#item"><z:itemType>journalArticle</z:itemType><dc:title>Migrated paper</dc:title><dc:date>2026-10-22</dc:date><bib:authors><rdf:Seq><rdf:li><foaf:Person><foaf:surname>Nguyen</foaf:surname><foaf:givenName>Ben</foaf:givenName></foaf:Person></rdf:li></rdf:Seq></bib:authors><dc:subject>CRISPR</dc:subject><dcterms:isPartOf><bib:Journal><dc:title>Nature</dc:title><dc:identifier>DOI 10.1234/test</dc:identifier><prism:volume>12</prism:volume></bib:Journal></dcterms:isPartOf><bib:pages>1-9</bib:pages><link:link rdf:resource="#pdf"/><dcterms:isReferencedBy><bib:Memo><rdf:value>&lt;p&gt;Keep &amp;amp; read&lt;/p&gt;</rdf:value></bib:Memo></dcterms:isReferencedBy></bib:Article>
    <z:Attachment rdf:about="#pdf"><z:itemType>attachment</z:itemType><dc:title>Full text</dc:title><z:path rdf:resource="files/paper.pdf"/></z:Attachment>
    <bib:Article rdf:about="#missing"><z:itemType>journalArticle</z:itemType><dc:title>Reference without PDF</dc:title></bib:Article>
    </rdf:RDF>
    """
    let source = export.appendingPathComponent("library.rdf"); try rdf.write(to: source, atomically: true, encoding: .utf8)
    let plan = try ZoteroRDF.parse(source)
    try check(plan.items.count == 2 && plan.collections == ["FITdb", "FITdb / Reading"], "RDF imports collection hierarchy and reference-only entries")
    let article = plan.items.first { $0.paper.title == "Migrated paper" }!
    try check(article.paper.authors == "Ben Nguyen" && article.paper.doi == "10.1234/test" && article.paper.citation?.journal == "Nature" && article.paper.notes == "Keep & read", "RDF extracts structured authors, journal DOI, and note text")
    let store = ShelfStore(root: root.appendingPathComponent("Library"))
    let result = Migration.run(plan, library: store.library, destination: store.files)
    try check(result.added == 2 && result.created.count == 1 && store.commit(result.library), "Migration commits PDFs and metadata-only references")
    let migrated = store.library.papers.first { $0.hasPDF }!
    let migratedHash = try Importer.hash(store.files.appendingPathComponent(migrated.filename))
    try check(migratedHash == hash, "Migration preserves annotated PDF bytes")
    let rows = Reader.annotationRows(in: PDFDocument(url: store.files.appendingPathComponent(migrated.filename))!)
    try check(rows.contains { $0.text == "Preserve this Zotero note" }, "Exported Zotero annotation remains readable")
    let again = Migration.run(plan, library: store.library, destination: store.files)
    try check(again.added == 0 && again.created.isEmpty && again.library.papers.count == 2, "Repeated Zotero migration is idempotent")
    var existing = store.library; existing.papers[existing.papers.firstIndex(where: { $0.id == migrated.id })!].notes = "My existing note"
    let merged = Migration.run(plan, library: existing, destination: store.files)
    try check(merged.library.papers.first(where: { $0.id == migrated.id })!.notes.contains("My existing note"), "Migration preserves existing notes")
    var altered = rdf.replacingOccurrences(of: "files/paper.pdf", with: "../outside.pdf"); try altered.write(to: source, atomically: true, encoding: .utf8)
    let unsafe = try ZoteroRDF.parse(source); try check(unsafe.items.allSatisfy { $0.attachments.isEmpty }, "RDF rejects attachment path escape")
    altered = "<!DOCTYPE rdf [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + rdf; try altered.write(to: source, atomically: true, encoding: .utf8)
    do { _ = try ZoteroRDF.parse(source); throw ShelfError.message("DTD accepted") } catch { try check(error.localizedDescription != "DTD accepted", "RDF rejects external entities") }
    let other = export.appendingPathComponent("files/other.pdf"); try fixturePDF(at: other, title: "Different version")
    var changed = plan; let itemIndex = changed.items.firstIndex { $0.paper.title == "Migrated paper" }!
    changed.items[itemIndex].attachments.append((other, "Different version"))
    let versions = Migration.run(changed, library: store.library, destination: store.files)
    try check(versions.created.count == 1 && versions.library.papers.filter { $0.parentID == migrated.id }.count == 1, "Different PDFs of one DOI are retained as supporting files")
    let repeatedVersions = Migration.run(changed, library: versions.library, destination: store.files)
    try check(repeatedVersions.created.isEmpty && repeatedVersions.library.papers.count == versions.library.papers.count, "Repeated multi-attachment migration creates no duplicate PDFs")
    let apa = try Citations.render([migrated], style: .apa), nature = try Citations.render([migrated], style: .nature)
    try check(apa.contains("Nguyen") && apa.contains("2026") && apa.contains("Migrated paper") && apa.contains("10.1234/test"), "Real CSL engine formats APA bibliography")
    try check(nature.contains("Nguyen") && nature.contains("Nature"), "Real CSL engine formats Nature bibliography")
    let html = try Citations.render([migrated], style: .apa, html: true)
    try check(html.contains("<i>Nature") || html.contains("font-style:italic"), "APA rich clipboard output preserves journal italics")
    let inline = try Citations.render([migrated], style: .apa, inline: true)
    try check(inline.contains("Nguyen") && inline.contains("2026"), "CSL engine formats inline citations")
    let csl = try Citations.render([migrated], style: .csl); try check(csl.contains("article-journal") && csl.contains("container-title"), "CSL-JSON export includes structured metadata")
    let bib = try Citations.render([migrated], style: .bibtex); try check(bib.contains("@article") && bib.contains("Nguyen, Ben") && bib.contains("journal = {Nature}"), "BibTeX export includes stable key and journal")
    try check(Citations.bibEscape("A&B_50%{x}") == "A\\&B\\_50\\%\\{x\\}", "BibTeX escapes special characters")
    let reader = Reader(); try check(reader.open(store.library.papers.first { !$0.hasPDF }!, in: store.files) && reader.view.document == nil, "Reader opens reference-only item without a PDF error")
    let host = BrowserHost(root: store.root)
    try check(host.handle(["action":"search"])["ok"] as? Bool == false, "Chrome bridge is disabled by default")
    try BrowserAccess(enabled: true).save(store.root)
    try check(host.handle(["action":"search", "query":"Migrated"])["total"] as? Int == 1, "Chrome searches saved citation metadata")
    try check(host.handle(["action":"citation", "ids":[migrated.id.uuidString], "style":"APA 7"])["text"] as? String == inline, "Chrome and desktop share citation output")
    let capture = BrowserCapture(title:"Browser paper", authors:["Ben Nguyen"], year:"2026", doi:"", journal:"", volume:"", issue:"", pages:"", url:"https://example.org/paper", collection:"Inbox", captureID:UUID().uuidString)
    let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(capture))
    try check(host.handle(["action":"capture", "capture":payload])["ok"] as? Bool == true && store.library.papers.count == 2, "Browser queues capture without writing the library index")
    do { _ = try BrowserCapture.pdfURL("/etc/passwd"); throw ShelfError.message("Path accepted") } catch { try check(error.localizedDescription != "Path accepted", "Browser rejects arbitrary local file reads") }
    try BrowserAccess().save(store.root); try check(host.handle(["action":"search"])["ok"] as? Bool == false, "Chrome revocation applies immediately")
    print("All connector tests passed.")
}

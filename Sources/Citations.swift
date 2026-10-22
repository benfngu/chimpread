import Foundation
import JavaScriptCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CitationCreator: Codable, Equatable, Sendable {
    var family: String
    var given: String = ""
    var literal: String? = nil
}
struct CitationMetadata: Codable, Equatable, Sendable {
    var type = "article-journal"
    var journal = ""
    var volume = ""
    var issue = ""
    var pages = ""
    var publisher = ""
    var creators: [CitationCreator] = []
    var authorDisplay = ""
}
enum CitationStyle: String, CaseIterable, Identifiable {
    case apa = "APA 7", nature = "Nature", bibtex = "BibTeX", csl = "CSL-JSON"
    var id: String { rawValue }
}
enum Citations {
    static func creators(_ paper: Paper) -> [CitationCreator] {
        if let c = paper.citation, !c.creators.isEmpty, c.authorDisplay == paper.authors { return c.creators }
        return paper.authors.split(separator: ";").map { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let comma = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if comma.count == 2 { return CitationCreator(family: comma[0], given: comma[1]) }
            let parts = name.split(separator: " ")
            return CitationCreator(family: String(parts.last ?? ""), given: parts.dropLast().joined(separator: " "))
        }
    }
    static func csl(_ p: Paper) -> [String: Any] {
        let c = p.citation ?? CitationMetadata()
        var item: [String: Any] = ["id": p.id.uuidString, "type": c.type, "title": p.title,
            "author": creators(p).map { a -> [String: String] in
                if let literal = a.literal { return ["literal": literal] }
                return ["family": a.family, "given": a.given]
            }]
        if let year = Int(p.year), year > 0 { item["issued"] = ["date-parts": [[year]]] }
        for (key, value) in [("DOI", p.doi), ("URL", p.sourceURL ?? ""), ("container-title", c.journal), ("volume", c.volume), ("issue", c.issue), ("page", c.pages), ("publisher", c.publisher)] where !value.isEmpty { item[key] = value }
        return item
    }
    static func bibEscape(_ text: String) -> String {
        var out = ""
        for char in text {
            switch char {
            case "\\": out += "\\textbackslash{}"
            case "{", "}", "%", "&", "_", "#", "$": out += "\\" + String(char)
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "\n", "\r": out += " "
            default: out.append(char)
            }
        }
        return out
    }
    static func render(_ papers: [Paper], style: CitationStyle, html: Bool = false, inline: Bool = false) throws -> String {
        guard !papers.isEmpty else { return "" }
        if style == .csl { return String(decoding: try JSONSerialization.data(withJSONObject: papers.map(csl), options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
        if style == .bibtex {
            return papers.map { p in
                let c = p.citation ?? CitationMetadata()
                let type = c.type == "book" ? "book" : c.type == "article-journal" ? "article" : "misc"
                let fields = [("title", p.title), ("author", creators(p).map { $0.literal.map { "{\($0)}" } ?? [$0.family, $0.given].filter { !$0.isEmpty }.joined(separator: ", ") }.joined(separator: " and ")), ("year", p.year), ("journal", c.journal), ("volume", c.volume), ("number", c.issue), ("pages", c.pages), ("publisher", c.publisher), ("doi", p.doi), ("url", p.sourceURL ?? "")]
                return "@\(type){chimp\(p.id.uuidString.replacingOccurrences(of: "-", with: "")),\n" + fields.filter { !$0.1.isEmpty }.map { "  \($0.0) = {\(bibEscape($0.1))}" }.joined(separator: ",\n") + "\n}"
            }.joined(separator: "\n\n")
        }
        // A fresh, short-lived JavaScript context avoids retaining a citation engine while reading.
        guard let context = JSContext() else { throw ShelfError.message("Citation engine unavailable") }
        let base = Bundle.main.resourceURL!.appendingPathComponent("Citations")
        func resource(_ name: String) throws -> String { try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8) }
        var problem: String?
        context.exceptionHandler = { _, exception in problem = exception?.toString() }
        context.evaluateScript("var module = {exports:{}};")
        context.evaluateScript(try resource("citeproc.js"))
        context.setObject(papers.map(csl), forKeyedSubscript: "items" as NSString)
        context.setObject(try resource(style == .apa ? "apa.csl" : "nature.csl"), forKeyedSubscript: "styleXML" as NSString)
        context.setObject(try resource("locales-en-US.xml"), forKeyedSubscript: "localeXML" as NSString)
        context.setObject(html ? "html" : "text", forKeyedSubscript: "outputFormat" as NSString)
        context.evaluateScript("""
        var byID = {}; items.forEach(function(i){byID[i.id]=i;});
        var engine = new CSL.Engine({retrieveLocale:function(){return localeXML;}, retrieveItem:function(id){return byID[id];}}, styleXML, 'en-US');
        engine.setOutputFormat(outputFormat);
        engine.updateItems(items.map(function(i){return i.id;}));
        """)
        let script = inline ? "engine.makeCitationCluster(items.map(function(i){return {id:i.id};}));" : "var b=engine.makeBibliography(); b ? b[1].join(outputFormat === 'html' ? '' : '\\n') : '';"
        let result = context.evaluateScript(script)?.toString()
        if let problem { throw ShelfError.message("Citation formatting failed: \(problem)") }
        return result ?? ""
    }
}

struct BibliographyView: View {
    @ObservedObject var store: ShelfStore
    @State private var selected = Set<UUID>()
    @State private var query = ""
    @State private var collection = "All collections"
    @State private var style = CitationStyle.apa
    @State private var output = ""
    @State private var message = ""
    private var visible: [Paper] { store.library.papers.filter { $0.parentID == nil && $0.archived != true && (collection == "All collections" || $0.collections.contains(collection)) && (query.isEmpty || ($0.title + " " + $0.authors).localizedCaseInsensitiveContains(query)) }.sorted { $0.title < $1.title } }
    private var chosen: [Paper] { store.library.papers.filter { selected.contains($0.id) }.sorted { $0.title < $1.title } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bibliography").font(.title2)
                Spacer()
                Picker("Format", selection: $style) { ForEach(CitationStyle.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 190)
            }
            HStack {
                TextField("Find papers", text: $query).textFieldStyle(.roundedBorder)
                Picker("Collection", selection: $collection) { Text("All collections").tag("All collections"); ForEach(store.library.collections, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                Button("Select shown") { selected.formUnion(visible.map(\.id)); output = "" }
                Button("Clear") { selected.removeAll(); output = "" }
            }
            List(visible) { p in Toggle(isOn: Binding(get: { selected.contains(p.id) }, set: { if $0 { selected.insert(p.id) } else { selected.remove(p.id) }; output = "" })) { VStack(alignment: .leading) { Text(p.title).lineLimit(1); Text(p.authors + " · " + p.year).font(.caption).foregroundStyle(.secondary).lineLimit(1) } } }.frame(minHeight: 170)
            HStack {
                Text("\(selected.count) selected").font(.caption)
                Spacer()
                Button("Generate") { generate() }.disabled(selected.isEmpty)
                Button("Copy") { copy() }.disabled(output.isEmpty)
                Button("Export…") { export() }.disabled(output.isEmpty)
            }
            ScrollView { Text(output.isEmpty ? "Select papers, then generate your bibliography." : output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(10).background(Color.secondary.opacity(0.06)).frame(minHeight: 160)
            Text(message.isEmpty ? "APA and Nature use CSL styles. Check incomplete metadata before submission. Numbered entries follow the selected list; document citations are plain text." : message).font(.caption).foregroundStyle(.secondary)
            Text("Citation formatting: citeproc-js © Frank Bennett · CSL styles and locales © their contributors").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(width: 720, height: 570).onChange(of: style) { _, _ in output = "" }
    }
    private func generate() {
        do { output = try Citations.render(chosen, style: style); let missing = chosen.filter { $0.authors.isEmpty || $0.year.isEmpty }.count; message = missing == 0 ? "" : "\(missing) selected references are missing authors or year. Edit Paper Details to complete them." }
        catch { message = error.localizedDescription }
    }
    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
        if style == .apa || style == .nature {
            do {
                let html = try Citations.render(chosen, style: style, html: true)
                NSPasteboard.general.setString("<html><meta charset=\"utf-8\"><body>" + html + "</body></html>", forType: .html)
                message = "Copied formatted bibliography with a plain-text fallback."
            } catch { message = error.localizedDescription }
        }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "bibliography." + (style == .bibtex ? "bib" : style == .csl ? "json" : "txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8); message = "Exported \(url.lastPathComponent)." } catch { message = error.localizedDescription }
    }
}

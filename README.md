# chimpread

A minimal native macOS app for reading, annotating, organizing, and citing research papers.
SwiftUI and AppKit provide the interface; PDFKit provides PDF reading and standard
PDF annotations. No Electron, web server, required account, telemetry, or third-party app runtime. Citation formatting uses bundled JavaScript in macOS JavaScriptCore. Optional MCP access uses the same native executable over stdio.

## Use

Open `chimpread.app`. Import PDFs or a Zotero RIS export with **File → Import Papers**
(⌘O), the toolbar import button, or drag PDF files into the paper list.

- Create collections with the sidebar +. Use Details or the paper's context menu to
  assign collections. A paper can belong to multiple collections without extra copies.
- Right-click a paper for tags/details, starred/unread status, and Show in Finder.
- Select PDF text, then use the highlighter button (⌘L). Press ⌘N to write a note
  beside the paper, with the selected quote and page attached. Enter saves it and
  highlights the selected passage; Shift+Enter adds a new line. ⌘Return also saves.
- Unfinished note drafts save locally and return when you reopen the paper.
- Show annotations with the right-sidebar button. Search notes, click a page to jump
  to its passage, or use Edit, Copy, and Delete. ⌘Z restores deleted annotations.
- Annotations made with chimpread controls save immediately into the managed PDF.
  Native PDFKit edits are checked every second, on ⌘S, switching papers, exporting, and quitting.
- Close the PDF with × to release the active document. The app remembers its page.
- Export a PDF with embedded annotations using the share button or ⌘E.
- Print the current PDF with the printer button or ⌘P. The native dialog supports page ranges.
- Continue Reading shows previously opened papers. All Papers retains the full active library.
- Tags are collapsed initially and case-only variants share one sidebar entry.
- Right-click a collection to rename it, or a paper to remove its collection membership.
- In Details, choose “Supporting file of” to group or ungroup a document. Manual grouping
  automatically locks that record against Hermes organization updates.
- Archive hides a paper and its attachments without deleting PDFs or notes. Restore them
  from Archive. An independently archived attachment retains its own archive status.
- Sorting by Recent, Title, Author, Newest, or Year persists between launches. Author sort
  uses the stored author string, not an inferred surname.

The panes are resizable. Colors and type follow macOS. The app uses one PDFDocument
at a time, loads imports sequentially off the UI thread, and does not build a global
PDF text index or retain a library of PDF thumbnails.

Reading starts in Page by Page mode. Use the Reading Layout menu beside the zoom
controls to choose Continuous Scroll; your choice is remembered across launches.
Use Left/Right arrow keys while the paper has focus, or the arrows beside the page
number, to turn pages. In text fields, arrow keys still move the cursor.
⌘Z undoes and ⌘⇧Z redoes typing or annotation actions. Annotation undo history is
limited to the current open paper. A highlighted passage appears as one sidebar
entry even when it spans several lines.

## Your files

Default library: `~/Library/Application Support/PaperShelf/`

- `library.json`: titles, authors, tags, collections, notes, reading position.
- `PDFs/`: independent copies, named with UUIDs to avoid filename collisions.
- `NoteDrafts/`: unfinished note drafts, one small JSON file per paper.
- `library.previous.json`: the metadata state before the latest successful save.

Original PDFs and Zotero data are never modified by importing. Identical input PDFs
are detected by SHA-256 streamed in 1 MiB chunks. Back up the whole library folder
while the app is closed; the previous JSON file alone is not a complete backup.
A malformed library index is protected against overwrite and produces an error.

## Zotero migration (0.3.0)

Open **File → Migrate from Zotero…**. In Zotero, export **Zotero RDF** with Export Notes,
Export Files, and Include Annotations enabled. Keep the RDF beside its files folder.
Choose the RDF in chimpread, review the reference/PDF/collection counts and warnings,
then start migration. The full report is saved in `Migration Reports/` in your library.

- Collection hierarchy becomes names such as `Research / Reading`.
- Authors, dates, DOI, journal, volume, issue, pages, source URLs, tags, and note text import.
- References without PDFs remain searchable and citable. Select one to attach a PDF later.
- Main PDFs and supporting attachments stay grouped; embedded PDF annotations are preserved byte-for-byte.
- Existing source identifiers or DOI merge references. Matching title/authors/year provides
  a fallback when a DOI is absent. PDF hashes deduplicate files, including current annotated copies.
- Different PDFs for a matched reference remain supporting files. Existing annotations are
  never replaced. Repeat migration is tested for both single and multiple attachments.
- Existing metadata wins; missing citation metadata fills in. Collections/tags union and notes
  append without duplicating identical imported text. Manual grouping is preserved.
- Original Zotero exports are untouched. Non-PDF, missing, external-linked, or locked attachments
  appear in the report. Download cloud files and export linked attachments first.
- Notes import as plain text; rich layout, Zotero annotation tags/deep links, saved searches,
  sync state, and Zotero-specific attachment types are not reproduced.

This is **export-based migration**, not direct access to a running Zotero database. Zotero
keeps native annotations in its database until exported; use Include Annotations.
[Zotero's annotation explanation](https://www.zotero.org/support/kb/annotations_in_database).
Legacy RIS/PDF import remains available with ⌘O; RDF is the complete migration route.

A read-only preview is also available:

```sh
chimpread --preview-zotero /path/to/library.rdf
```

## Bibliography

**File → Bibliography… (⌘B)** opens a searchable reference picker with collection filtering.
Select papers and generate **APA 7**, **Nature**, **BibTeX**, or **CSL-JSON**. Copy preserves
rich HTML formatting for APA/Nature with a plain-text fallback; export saves text/BibTeX/JSON.
Right-click a paper to copy an APA inline citation. Paper Details includes journal, volume,
issue, and pages. Missing author/year metadata is flagged before use.

Formatting uses bundled citeproc-js and official CSL styles in a temporary JavaScriptCore
context; no model, Node service, or web process is kept running. CSL exports retain structured
authors when available. BibTeX uses stable UUID keys and escapes special characters.
Supplementary attachments are excluded from the bibliography picker.

## Chrome and Google Docs

Open **Integrations (⌘,)** → **Show Extension** and follow the included
[connector setup guide](ChromeExtension/README.md). The Chrome extension saves publisher
metadata or downloads PDFs, searches local references, and copies citations. The optional
native bridge is disabled until enabled and opens no network listener.

Google Docs insertion is implemented in the Chrome extension through Google's API.
It requires a Google Cloud Chrome Extension OAuth client and user authorization; credentials
are not bundled. The connector previews the target document/tab and text, replaces a unique
citation marker, or appends a bibliography. Entries are plain text, without automatic updating
or document-wide citation numbering. Live account insertion remains unverified until configured.

## Build and run

Requires an Apple Silicon Mac with macOS 14+ and Xcode Command Line Tools.

```sh
git clone https://github.com/benfngu/chimpread.git
cd chimpread
./build.sh
open build/chimpread.app
```

The app is ad-hoc signed locally, not notarized. No package installation is needed
for the app. Node.js and Python are only used for optional development tests.

```sh
./build/chimpread.app/Contents/MacOS/chimpread --self-test
python3 Tests/test_native_host.py
node --test Tests/extension.test.mjs
# Optional: install the official Python mcp SDK in a virtual environment first.
python3 Tests/test_mcp.py
```

Tests generate disposable documents; no personal papers or library exports are included.
To create an isolated demo library:

```sh
./build/chimpread.app/Contents/MacOS/chimpread --make-demo /tmp/chimpread-demo
open -n build/chimpread.app --args --library /tmp/chimpread-demo
```

Use one GUI instance per library. Back up your library before migration. The JSON
index has stale-write protection but is not a transactional multi-process database.

## MCP and Hermes

Open **Integrations (⌘,)** and enable MCP access. PDF text and saved notes require
a separate content-access toggle. Use **Copy MCP Config** or **Copy Hermes Config**
to obtain paths for your installation. Merge the Hermes entry into
`~/.hermes/config.yaml`, then reload MCP in Hermes. No client configuration is changed
automatically and no model runs inside chimpread.

The native executable supports `--mcp` over stdio. Tools are read-only:
`search_papers`, `get_paper`, `read_pages`, and `read_notes`. Reading is bounded and
returns page numbers; unfinished drafts are excluded. Disable access to revoke it
on the next request. A connected client can send results to its selected model.
The app also accepts an optional local `organization.json` sidecar; personal
research rules and background schedules are not included in this repository.

## Status and limitations

Version 0.3.0 is an early native application. Migration, bibliography formatting,
reader behavior, Chrome native messaging, and MCP have automated regression tests.
Google Docs request construction is tested; live OAuth and document insertion still
need verification with a configured account. The extension is distributed as unpacked
source, not a Chrome Web Store release.

No OCR, full-library text index, cloud sync, in-app LLM chat, or live citation fields.
Different scans/editions may remain separate despite byte-level deduplication.
Bibliographies depend on the completeness of imported metadata. Only the current
paper stays open; PDFKit can still use substantial memory for complex documents.

## License and credits

chimpread source is licensed under AGPL-3.0-or-later; see [LICENSE](LICENSE).
Copyright 2026 Ben Nguyen. Third-party components retain their own notices:

- citeproc-js 2.4.63 by Frank Bennett, used under AGPL-3.0-or-later.
- APA and Nature CSL styles and the en-US locale by the Citation Style Language
  contributors; license information is embedded in the files.
- See [citation notices](Resources/Citations/NOTICE.txt) and
  [source provenance](Resources/Citations/PROVENANCE.json).

The chimp reading icon adapts the Chimprace face with glasses and a book, created
using OpenAI image generation at the author's request.

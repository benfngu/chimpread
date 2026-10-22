# chimpread Chrome Connector

Manifest V3, no build step, no remote code, no analytics. The extension is local/unpacked;
it is not published to the Chrome Web Store.

## Install

1. Open chimpread → Integrations (⌘,).
2. Click **Show Extension**. This copies the packaged extension to the editable folder
   `~/Library/Application Support/PaperShelf/Chrome Connector/Extension` on first use.
   Keep this folder outside the signed app bundle.
3. Open `chrome://extensions`, enable Developer mode, and click **Load unpacked**.
   Choose that Extension folder.
4. Click **Enable Chrome Connector** in chimpread Integrations. This installs the
   native host registration for this extension ID only:
   `mhkjnamlejbghhclgaingolniglidbkn`.
5. Pin the extension if desired. Open it on a publisher page or direct PDF.

`Show Extension` preserves an existing editable copy, including your OAuth configuration.
For a later extension update, replace its JS/HTML/CSS files from the new bundle and merge
manifest changes while retaining your `oauth2` client ID and the bundled `key`.

## Capture

- **Save reference** queues the page's title, authors, year, DOI, journal, and source URL.
- **Save with PDF** uses Chrome's authenticated download flow when a publisher exposes
  `citation_pdf_url` or the active URL is a PDF. Downloaded files stay in `Downloads/chimpread`;
  chimpread makes independent managed copies and never deletes the downloads.
- Leave chimpread open to process queued captures. It remains the sole writer of `library.json`.
- A failed/HTML/locked download yields a reference plus an import warning, not a fake PDF.
- No paywall bypass, page crawling, or automatic full-text discovery. Browser-internal pages
  cannot be scraped. Missing metadata can be corrected in Paper Details.
- Download status appears the next time the popup opens. Pending completed downloads whose
  native delivery failed retry when Chrome starts again; keep the connector enabled.

## Citations and bibliographies

Search the library and select up to 50 papers. Copy an inline citation or bibliography
in APA 7/Nature, or export BibTeX/CSL-JSON text. Selection lasts for the browser session.
The app and Chrome use the same local CSL engine. The native bridge exposes metadata,
not PDF contents or saved notes. Disable the connector in chimpread to revoke access.

## Google Docs

This is a Google Docs API connector, not a Marketplace add-on. It requires your own
Google Cloud OAuth client because a local unpublished extension cannot reuse another
application's credentials. No client secret belongs in this extension.

1. Create/select a Google Cloud project and enable **Google Docs API**.
2. Configure OAuth consent, including yourself as a test user when using testing mode.
3. Create an OAuth client of type **Chrome Extension** using the extension ID above.
4. In the editable extension folder, run:

   ```sh
   python3 configure_google.py YOUR_CLIENT_ID.apps.googleusercontent.com
   ```

5. Reload the extension at `chrome://extensions`.
6. Open a Google document. Select references, choose APA 7 or Nature, and click
   **Preview insertion**. Complete Google's account authorization.
7. Review the document title, target tab, and text, then click **Insert into this document**.

For citations, type `{{cite}}` exactly once at the target position in the chosen tab before
opening the popup. The connector replaces that marker. Bibliographies append at the end
of the chosen tab. Duplicate/missing markers and stale document revisions are rejected.
There is no simulated keystroke insertion into Google's canvas editor.

Inserted citations are **plain text, not live fields**. Changing metadata or styles later
will not refresh existing citations. Nature numbering starts from the selection on each
operation; use APA for separate citation insertions unless managing numbering yourself.
Select all desired references together for a consistent numbered bibliography.

The API requires the `https://www.googleapis.com/auth/documents` scope. The extension
accesses only the document you preview, reads it to find the marker and revision, and
sends only the text you explicitly insert. No document content is retained in storage.
Google tokens are managed by Chrome Identity, never sent to chimpread. Settings can
clear cached tokens; revoke the grant fully from your Google Account's connections page.

Live OAuth/insertion requires user setup and has not been verified against a real account.
Request generation, nested tabs, unique markers, and revision protection have automated tests.

## Primary references

- [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Chrome OAuth setup](https://developer.chrome.com/docs/extensions/how-to/integrate/oauth)
- [Docs batchUpdate](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/batchUpdate)
- [Docs insertion and replacement requests](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/request)

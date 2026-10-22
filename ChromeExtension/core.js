export function docTarget(raw) {
  const url = new URL(raw);
  if (url.hostname !== 'docs.google.com' || url.protocol !== 'https:') throw new Error('Open a Google document first.');
  const match = url.pathname.match(/^\/document\/d\/([\w-]+)(?:\/|$)/);
  if (!match) throw new Error('This is not a Google document.');
  return {id: match[1], tab: url.searchParams.get('tab')};
}
export function documentTabs(doc) {
  const out = [];
  function visit(tabs) { for (const tab of tabs || []) { if (tab.documentTab) out.push({id: tab.tabProperties.tabId, title: tab.tabProperties.title, body: tab.documentTab.body}); visit(tab.childTabs); } }
  visit(doc.tabs);
  if (!out.length && doc.body) out.push({id: null, title: 'Document', body: doc.body});
  return out;
}
export function bodyText(body) {
  function elements(items) { return (items || []).map(e => e.paragraph ? (e.paragraph.elements || []).map(r => r.textRun?.content || '').join('') : e.table ? e.table.tableRows.map(r => r.tableCells.map(c => elements(c.content)).join('')).join('') : e.tableOfContents ? elements(e.tableOfContents.content) : '').join(''); }
  return elements(body?.content);
}
export function buildUpdate(doc, tabID, text, mode, marker = '{{cite}}') {
  if (!text || text.length > 200000) throw new Error('Empty or oversized citation output.');
  const tabs = documentTabs(doc), tab = tabs.find(t => t.id === tabID);
  if (!tab) throw new Error('Document tab not found. Preview again.');
  if (!doc.revisionId) throw new Error('Google did not return a revision ID; no changes made.');
  let request;
  if (mode === 'citation') {
    if (!marker || marker.length > 100) throw new Error('Enter a short unique citation marker.');
    const count = bodyText(tab.body).split(marker).length - 1;
    if (count !== 1) throw new Error(`Put the marker ${marker} exactly once in the selected document tab (found ${count}).`);
    request = {replaceAllText: {containsText: {text: marker, matchCase: true}, replaceText: text}};
    if (tab.id) request.replaceAllText.tabsCriteria = {tabIds: [tab.id]};
  } else if (mode === 'bibliography') {
    request = {insertText: {endOfSegmentLocation: tab.id ? {tabId: tab.id} : {}, text: '\nReferences\n' + text.trim() + '\n'}};
  } else throw new Error('Unknown insertion mode.');
  return {writeControl: {requiredRevisionId: doc.revisionId}, requests: [request]};
}
export function capturePage() {
  const meta = (names) => { for (const name of names) { const values = Array.from(document.querySelectorAll('meta')).filter(m => (m.getAttribute('name') || m.getAttribute('property') || '').toLowerCase() === name.toLowerCase()).map(m => m.content.trim()).filter(Boolean); if (values.length) return values; } return []; };
  const first = names => meta(names)[0] || '';
  const resolve = value => { try { const u = new URL(value, location.href); return ['https:', 'http:'].includes(u.protocol) && !u.username && !u.password ? u.href : ''; } catch { return ''; } };
  let pdf = first(['citation_pdf_url']);
  if (!pdf && /\.pdf(?:$|[?#])/i.test(location.href)) pdf = location.href;
  const date = first(['citation_publication_date','citation_date','dc.date','article:published_time']);
  return {title: first(['citation_title','dc.title','og:title']) || document.title, authors: meta(['citation_author','dc.creator']), year: date.match(/\b(?:1[5-9]|2\d)\d{2}\b/)?.[0] || '', doi: first(['citation_doi','dc.identifier.doi']), journal: first(['citation_journal_title']), volume: first(['citation_volume']), issue: first(['citation_issue']), pages: [first(['citation_firstpage']), first(['citation_lastpage'])].filter(Boolean).join('-'), url: location.href, pdfURL: pdf ? resolve(pdf) : ''};
}

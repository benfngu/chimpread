const host = 'local.chimpread.connector';
// Downloads continue if the popup closes. No background crawling or broad page access.
chrome.runtime.onMessage.addListener((request, sender, reply) => {
  if (sender.id !== chrome.runtime.id || request.action !== 'downloadPDF') return;
  (async () => {
    const url = new URL(request.url);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) throw new Error('Unsupported PDF URL');
    const capture = request.capture;
    const id = await chrome.downloads.download({url: url.href, filename: `chimpread/${capture.captureID}.pdf`, conflictAction: 'uniquify'});
    await chrome.storage.local.set({['download:' + id]: capture});
    // A tiny download can finish before storage is set; explicitly reconcile it.
    await finish(id);
    return {ok: true, message: 'Download started. It will be queued for chimpread when complete.'};
  })().then(reply).catch(error => reply({ok:false, error:error.message}));
  return true;
});
async function finish(id) {
  const key = 'download:' + id, saved = await chrome.storage.local.get(key), capture = saved[key];
  if (!capture) return;
  const [download] = await chrome.downloads.search({id});
  if (download?.state === 'complete') {
    const result = await chrome.runtime.sendNativeMessage(host, {action:'capture', capture:{...capture, localPDF:download.filename}});
    if (!result.ok) throw new Error(result.error);
    await chrome.storage.local.remove(key);
    await chrome.storage.local.set({lastDownload: 'PDF queued for chimpread.'});
  } else if (download?.state === 'interrupted') {
    await chrome.storage.local.remove(key);
    throw new Error('PDF download interrupted: ' + (download.error || 'unknown reason'));
  }
}
chrome.downloads.onChanged.addListener(delta => {
  if (delta.state) finish(delta.id).catch(error => chrome.storage.local.set({lastDownload:error.message}));
});
chrome.runtime.onStartup.addListener(async () => {
  const values = await chrome.storage.local.get(null);
  for (const key of Object.keys(values).filter(k => k.startsWith('download:'))) await finish(Number(key.slice(9))).catch(error => chrome.storage.local.set({lastDownload:error.message}));
});

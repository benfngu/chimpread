import {capturePage, docTarget, documentTabs, buildUpdate} from './core.js';
const $ = id => document.getElementById(id), selected = new Map();
let page = null, activeTab = null, preview = null, busy = false;
function status(text) { $('status').textContent = text; }
async function native(message) { const result = await chrome.runtime.sendNativeMessage('local.chimpread.connector', message); if (!result.ok) throw new Error(result.error); return result; }
function task(fn) { return async () => { if (busy) return; busy = true; try { await fn(); } catch(e) { status(e.message); } finally { busy = false; } }; }
function invalidate() { preview = null; $('docPreview').hidden = true; $('output').value = ''; }
function count() { chrome.storage.session.set({selectedIDs:[...selected.keys()]}); $('selection').textContent = `${selected.size} selected (maximum 50)`; invalidate(); }
async function search() {
  const r = await native({action:'search', query:$('query').value});
  $('results').replaceChildren();
  for (const p of r.papers) {
    const label=document.createElement('label'); label.className='paper'; const box=document.createElement('input'); box.type='checkbox'; box.checked=selected.has(p.id);
    box.addEventListener('change',()=> { if(box.checked && selected.size >= 50){box.checked=false;status('Select at most 50 papers.');return;} box.checked?selected.set(p.id,p):selected.delete(p.id);count(); });
    const span=document.createElement('span'); span.textContent=p.title; const small=document.createElement('small'); small.textContent=`${p.authors} · ${p.year}`; span.append(small);label.append(box,span);$('results').append(label);
  }
  const collection=$('collection').value;$('collection').replaceChildren(new Option('Unfiled',''));for(const name of r.collections)$('collection').add(new Option(name,name));$('collection').value=collection;
  if(r.total>50)status(`${r.total} matches; showing 50. Narrow your search.`);
}
async function format(action) { if(!selected.size)throw new Error('Select papers first.');return (await native({action,ids:[...selected.keys()],style:$('style').value})).text; }
async function token() {
  if(!chrome.runtime.getManifest().oauth2?.client_id)throw new Error('Google Docs is not configured. Open Settings for the one-time OAuth setup.');
  const r=await chrome.identity.getAuthToken({interactive:true});return typeof r==='string'?r:r.token;
}
async function google(path, auth, body) {
  const response=await fetch('https://docs.googleapis.com/v1/documents/'+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+auth,...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});
  if(response.status===401){await chrome.identity.removeCachedAuthToken({token:auth});throw new Error('Google authorization expired. Preview again to reconnect.');}
  const data=await response.json();if(!response.ok)throw new Error(data.error?.message||`Google Docs error ${response.status}`);return data;
}
$('settings').onclick=()=>chrome.runtime.openOptionsPage();
$('search').onclick=task(search);$('query').onkeydown=e=>{if(e.key==='Enter')$('search').click();};
$('clear').onclick=()=>{selected.clear();count();search().catch(e=>status(e.message));};
$('style').onchange=invalidate;$('mode').onchange=invalidate;$('marker').oninput=invalidate;
for(const action of ['citation','bibliography'])$(action).onclick=task(async()=>{const text=await format(action);$('output').value=text;await navigator.clipboard.writeText(text);status('Copied.');});
async function save(withPDF) {
  if(!page)throw new Error('This page cannot be captured.');
  const capture={title:$('title').value,authors:page.authors,year:page.year,doi:page.doi,journal:page.journal,volume:page.volume,issue:page.issue,pages:page.pages,url:page.url,collection:$('collection').value,captureID:crypto.randomUUID()};
  const r=withPDF?await chrome.runtime.sendMessage({action:'downloadPDF',url:page.pdfURL,capture}):await native({action:'capture',capture});
  if(!r.ok)throw new Error(r.error);status(r.message);
}
$('save').onclick=task(()=>save(false));$('pdf').onclick=task(()=>save(true));
$('preview').onclick=task(async()=>{
  if(!['APA 7','Nature'].includes($('style').value))throw new Error('Choose APA 7 or Nature for Google Docs.');
  const target=docTarget(activeTab.url), mode=$('mode').value, text=await format(mode==='citation'?'citation':'bibliography'), auth=await token();
  const doc=await google(target.id+'?includeTabsContent=true',auth), tabs=documentTabs(doc);
  if(!tabs.length)throw new Error('No editable document tabs found.');
  $('docTitle').textContent=doc.title; $('docTab').replaceChildren();for(const tab of tabs)$('docTab').add(new Option(tab.title,tab.id||''));
  if(target.tab && tabs.some(t=>t.id===target.tab))$('docTab').value=target.tab;
  $('docText').textContent=text;preview={target,mode,text,auth,marker:$('marker').value};$('docPreview').hidden=false;
  status(mode==='citation'?`Place ${preview.marker} once where you want the citation. Then choose the target tab and insert.`:'Review the document, tab, and bibliography before inserting at the end.');
});
$('insert').onclick=task(async()=>{
  if(!preview)throw new Error('Preview the insertion first.');
  const {target,mode,text,auth,marker}=preview;
  const [current]=await chrome.tabs.query({active:true,currentWindow:true});if(docTarget(current.url).id!==target.id)throw new Error('The active document changed; preview again.');
  const doc=await google(target.id+'?includeTabsContent=true',auth), body=buildUpdate(doc,$('docTab').value||null,text,mode,marker);
  await google(target.id+':batchUpdate',auth,body);invalidate();status('Inserted into Google Docs. Use Docs Undo if needed.');
});
(async()=>{
  const {selectedIDs=[]}=await chrome.storage.session.get('selectedIDs');for(const id of selectedIDs)selected.set(id,{id});count();
  [activeTab]=await chrome.tabs.query({active:true,currentWindow:true});
  try {
    const [{result}]=await chrome.scripting.executeScript({target:{tabId:activeTab.id},func:capturePage});page=result;
  }catch(e){if(activeTab.url?.startsWith('https://')||activeTab.url?.startsWith('http://'))page={title:activeTab.title||'Paper',authors:[],year:'',doi:'',journal:'',volume:'',issue:'',pages:'',url:activeTab.url,pdfURL:/\.pdf(?:$|[?#])/i.test(activeTab.url)?activeTab.url:''};}
  if(page){$('title').value=page.title;$('pdf').disabled=!page.pdfURL;$('pageHint').textContent=page.pdfURL?'PDF link found. Save with PDF downloads through Chrome.':'No PDF link detected; you can attach a PDF in chimpread later.';}else{$('save').disabled=true;$('pageHint').textContent='Open a publisher page or PDF to save it.';}
  try{docTarget(activeTab.url);}catch{$('preview').disabled=true;}
  await search();const {lastDownload}=await chrome.storage.local.get('lastDownload');if(lastDownload)status(lastDownload);
})().catch(e=>status(e.message));

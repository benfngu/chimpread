import {test} from 'node:test';
import assert from 'node:assert/strict';
import {docTarget,documentTabs,bodyText,buildUpdate,capturePage} from '../ChromeExtension/core.js';
const doc={title:'Fixture',revisionId:'rev-1',tabs:[{tabProperties:{tabId:'t.a',title:'Main'},documentTab:{body:{content:[{paragraph:{elements:[{textRun:{content:'A {{ci'}},{textRun:{content:'te}} here.\n'}}]}}]}},childTabs:[{tabProperties:{tabId:'t.b',title:'Nested'},documentTab:{body:{content:[{paragraph:{elements:[{textRun:{content:'Other text\n'}}]}}]}}}]}]};
test('Google document URL and tab ID',()=>{assert.deepEqual(docTarget('https://docs.google.com/document/d/abc-123/edit?tab=t.a'),{id:'abc-123',tab:'t.a'});assert.throws(()=>docTarget('https://evil.org/document/d/abc/edit'));assert.throws(()=>docTarget('https://docs.google.com/spreadsheets/d/abc/edit'));});
test('Nested document tabs and split text runs',()=>{assert.equal(documentTabs(doc).length,2);assert.equal(bodyText(documentTabs(doc)[0].body),'A {{cite}} here.\n');});
test('Citation replaces exactly one marker in chosen tab with revision guard',()=>{const update=buildUpdate(doc,'t.a','(Nguyen, 2026)','citation');assert.deepEqual(update,{writeControl:{requiredRevisionId:'rev-1'},requests:[{replaceAllText:{containsText:{text:'{{cite}}',matchCase:true},replaceText:'(Nguyen, 2026)',tabsCriteria:{tabIds:['t.a']}}}]});assert.throws(()=>buildUpdate(doc,'t.b','x','citation'),/found 0/);});
test('Reject repeated marker, unknown tab, empty citation and missing revision',()=>{const repeat=structuredClone(doc);repeat.tabs[0].documentTab.body.content.push({paragraph:{elements:[{textRun:{content:'{{cite}}'}}]}});assert.throws(()=>buildUpdate(repeat,'t.a','x','citation'),/found 2/);assert.throws(()=>buildUpdate(doc,'unknown','x','bibliography'));assert.throws(()=>buildUpdate(doc,'t.a','','bibliography'));assert.throws(()=>buildUpdate({...doc,revisionId:null},'t.a','x','bibliography'));});
test('Bibliography appends to the chosen tab only',()=>{assert.deepEqual(buildUpdate(doc,'t.b','Reference text\n','bibliography').requests,[{insertText:{endOfSegmentLocation:{tabId:'t.b'},text:'\nReferences\nReference text\n'}}]);});
test('Publisher metadata capture resolves relative PDF and never executes page text',()=>{
 const metadata=[['citation_title','A paper'],['citation_author','Nguyen, Ben'],['citation_author','Smith, Jane'],['citation_date','2026/10/22'],['citation_pdf_url','/paper.pdf'],['citation_doi','10.1/test']];
 globalThis.document={title:'Fallback',querySelectorAll:()=>metadata.map(([name,content])=>({content,getAttribute:key=>key==='name'?name:null}))};globalThis.location={href:'https://example.org/article'};
 const captured=capturePage();assert.equal(captured.pdfURL,'https://example.org/paper.pdf');assert.deepEqual(captured.authors,['Nguyen, Ben','Smith, Jane']);assert.equal(captured.year,'2026');
 metadata[4][1]='javascript:alert(1)';assert.equal(capturePage().pdfURL,'');
});

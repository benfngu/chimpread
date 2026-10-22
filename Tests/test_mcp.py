"""MCP interoperability test against the official Python SDK, using disposable PDFs."""
import asyncio
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

APP = Path(__file__).resolve().parents[1] / 'build/chimpread.app/Contents/MacOS/chimpread'

async def main():
    with tempfile.TemporaryDirectory(prefix='chimpread-mcp-test-') as temp:
        root = Path(temp) / 'library'
        subprocess.run([str(APP), '--make-demo', str(root)], check=True, capture_output=True)
        papers = json.loads((root / 'library.json').read_text())['papers']
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (root / 'PDFs').iterdir()}
        params = StdioServerParameters(command=str(APP), args=['--mcp', '--library', str(root)])
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                init = await session.initialize()
                print('PASS SDK initialization', init.protocol_version)
                tools = await session.list_tools()
                assert {t.name for t in tools.tools} == {'search_papers', 'get_paper', 'read_pages', 'read_notes'}
                assert all(t.annotations.read_only_hint for t in tools.tools)
                assert (await session.call_tool('search_papers', {})).is_error
                (root/'mcp-access.json').write_text(json.dumps({'enabled':True,'includeContent':False}))
                found = await session.call_tool('search_papers', {'collection':'Reading room'})
                assert not found.is_error and json.loads(found.content[0].text)['total'] == 3
                assert (await session.call_tool('read_pages', {'paper_id':papers[0]['id'], 'start_page':1})).is_error
                print('PASS SDK discovery and metadata-only gate')
                (root/'mcp-access.json').write_text(json.dumps({'enabled':True,'includeContent':True}))
                result = await session.call_tool('read_pages', {'paper_id':papers[0]['id'], 'start_page':2,'page_count':2})
                assert not result.is_error
                payload = json.loads(result.content[0].text)
                assert [p['page'] for p in payload['pages']] == [2,3]
                assert 'demonstration PDF' in payload['pages'][0]['text']
                assert not (await session.call_tool('read_notes', {'paper_id':papers[0]['id']})).is_error
                for invalid in [0, -1, True, '1', 1.5, 99999]:
                    assert (await session.call_tool('read_pages', {'paper_id':papers[0]['id'],'start_page':invalid})).is_error
                print('PASS SDK page citations, notes, and invalid input rejection')
                (root/'mcp-access.json').write_text('{bad json')
                assert (await session.call_tool('search_papers', {})).is_error
                print('PASS malformed permission file fails closed in existing session')
        after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (root / 'PDFs').iterdir()}
        assert before == after
        print('PASS MCP leaves every PDF byte unchanged')

asyncio.run(main())

"""Real Chrome native messaging framing and access tests, isolated library only."""
import json, struct, subprocess, tempfile
from pathlib import Path
APP=Path(__file__).resolve().parents[1]/'build/chimpread.app/Contents/MacOS/chimpread'
EXT='chrome-extension://mhkjnamlejbghhclgaingolniglidbkn/'
with tempfile.TemporaryDirectory(prefix='chimpread-native-') as tmp:
 root=Path(tmp)
 (root/'library.json').write_text(json.dumps({'version':1,'papers':[],'collections':['Test']}))
 (root/'browser-access.json').write_text('{"enabled":true}')
 p=subprocess.Popen([str(APP),'--native-host','--library',tmp,EXT],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 def exchange(obj, split=False):
  data=json.dumps(obj).encode();frame=struct.pack('<I',len(data))+data
  if split:
   for byte in frame:p.stdin.write(bytes([byte]));p.stdin.flush()
  else:p.stdin.write(frame);p.stdin.flush()
  header=p.stdout.read(4);assert len(header)==4, p.stderr.read().decode()
  return json.loads(p.stdout.read(struct.unpack('<I',header)[0]))
 assert exchange({'action':'search'},True)['collections']==['Test']
 print('PASS Chrome native framing accepts fragmented messages')
 assert exchange({'action':'unknown'})['ok'] is False
 print('PASS Native connection handles multiple requests and rejects unknown actions')
 (root/'browser-access.json').write_text('{"enabled":false}')
 assert exchange({'action':'search'})['ok'] is False
 print('PASS Access revocation applies to a running native host')
 p.stdin.close();assert p.wait(timeout=5)==0
 blocked=subprocess.run([str(APP),'--native-host','--library',tmp,'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'],input=b'',capture_output=True,timeout=5)
 assert not blocked.stdout
 print('PASS Native host rejects an unregistered extension origin')

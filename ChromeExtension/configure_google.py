#!/usr/bin/env python3
"""Configure a public Chrome Extension OAuth client ID; never accepts a client secret."""
import json, re, sys
from pathlib import Path
if len(sys.argv) != 2 or not re.fullmatch(r'[A-Za-z0-9_-]+\.apps\.googleusercontent\.com', sys.argv[1]):
    raise SystemExit('Usage: python3 configure_google.py YOUR_CLIENT_ID.apps.googleusercontent.com')
p = Path(__file__).with_name('manifest.json')
manifest = json.loads(p.read_text())
manifest['oauth2'] = {'client_id': sys.argv[1], 'scopes': ['https://www.googleapis.com/auth/documents']}
p.write_text(json.dumps(manifest, indent=2) + '\n')
print('Configured. Reload this extension folder in chrome://extensions.')

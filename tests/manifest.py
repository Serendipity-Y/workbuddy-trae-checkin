"""Validate the shipped bytes with either Windows or Unix checkout line endings."""
import hashlib
import json
import pathlib
root=pathlib.Path(__file__).resolve().parents[1]
manifest=json.loads((root/'windows/agentrouter/manifest.json').read_text())
for entry in manifest['Files']:
    original=(root/entry['Path']).read_bytes()
    for variant in (original, original.replace(b'\r\n',b'\n').replace(b'\n',b'\r\n')):
        normalized=variant.decode('utf-8-sig').replace('\r\n','\n').rstrip('\r\n')
        assert hashlib.sha256(normalized.encode()).hexdigest()==entry['SHA256'],entry['Path']
print('PASS payload: complete file hashes match with LF and CRLF checkout line endings.')

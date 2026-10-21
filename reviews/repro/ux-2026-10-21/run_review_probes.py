#!/usr/bin/env python3
"""Review-only deterministic probes. macOS/Xcode required; no real inference."""
import ast
import importlib.util
import json
import os
import resource
import subprocess
import tempfile
import threading
import time
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ENV = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=90, **kwargs)

def checked(args):
    p = run(args)
    if p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return p.stdout.strip()

def emit(**obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if 'zero-based' in self.path:
            result = [{'id': 0, 'translation': 'First translation'}, {'id': 1, 'translation': 'Second translation'}]
        elif 'partial' in self.path:
            data = json.loads(req['messages'][1]['content'].split('\n', 1)[1])
            result = [{'id': data[0]['id'], 'translation': 'Only first'}]
        elif 'duplicate-timeline' in self.path:
            result = {'subtitles': [{'id': 0, 'start': 0, 'end': 2}, {'id': 0, 'start': 0, 'end': 2}]}
        elif 'align-stale' in self.path:
            time.sleep(.5)
            result = {'subtitles': [{'id': 0, 'start': 0, 'end': 2}]}
        elif 'segment-stale' in self.path:
            time.sleep(.5)
            result = {'lines': ['Project A']}
        else:
            result = {'lines': ['Goodbye moon']}
        data = json.dumps({'choices': [{'message': {'content': json.dumps(result)}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

def main():
    emit(baseline=checked(['git', 'rev-parse', 'HEAD']))
    with tempfile.TemporaryDirectory(prefix='vat-ux-review-') as temp:
        temp = Path(temp)
        # Remove only init's unrelated service probes from a temporary AppState copy.
        source = (ROOT / 'Sources/VideoAutoTranslateApp/AppState.swift').read_text()
        startup = '''        Task {
            await sidecarManager.probeExistingStatus()
            await probeLocalOllama()
            await probeLocalASR()
        }
'''
        assert source.count(startup) == 1
        app = temp / 'AppState.swift'
        app.write_text(source.replace(startup, '', 1))
        checked(['swift', 'build', '--target', 'VideoAutoTranslateCore'])
        bindir = Path(checked(['swift', 'build', '--show-bin-path']))
        objects = sorted((bindir / 'VideoAutoTranslateCore.build').glob('*.swift.o'))
        exe = temp / 'probe'
        checked(['xcrun', 'swiftc', '-parse-as-library', '-I', str(bindir / 'Modules'), str(Path(__file__).with_name('ReviewProbe.swift')), str(app), *map(str, objects), '-o', str(exe)])
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for mode in ['undo', 'load-undo', 'core', 'translation', 'segment-content', 'segment-stale', 'align-stale', 'duplicate-timeline']:
                p = run([str(exe), mode, f'http://127.0.0.1:{server.server_port}'])
                fatal = next((s for s in p.stderr.splitlines() if 'Fatal error:' in s), '')
                emit(probe=mode, exit=p.returncode, stdout=p.stdout.strip(), fatal=fatal)
        finally:
            server.shutdown()
            server.server_close()
        # Test ASR result semantics with fake inference; no dependencies or weights loaded.
        spec = importlib.util.spec_from_file_location('review_asr', ROOT / 'scripts/asr_server.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.HAS_MLX = True
        mod.find_model_path = lambda repo, **kw: Path('/review/fake') if 'ASR' in repo else None
        mod.get_loaded_model = lambda path: types.SimpleNamespace(generate=lambda *a, **kw: types.SimpleNamespace(text='A full transcript without timing', language='English'))
        result = mod.run_local_transcription('/review/nonexistent-audio')
        emit(probe='asr-no-alignment', result=result)
        for p in (ROOT / 'scripts').glob('*.py'):
            ast.parse(p.read_text())
        emit(probe='python-syntax', status='ok')

if __name__ == '__main__':
    main()

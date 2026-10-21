#!/usr/bin/env python3
"""Build a disposable UI review fixture; never replaces dist or application data."""
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ENV = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}

def checked(args):
    result = subprocess.run(args, cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()

work = Path(tempfile.mkdtemp(prefix='vat-ui-review-'))
video = work / 'disposable-sample.mp4'
checked(['ffmpeg', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=0x243b53:size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=16000', '-t', '20', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', str(video)])
checked(['swift', 'build', '--target', 'VideoAutoTranslateCore'])
bindir = Path(checked(['swift', 'build', '--show-bin-path']))
objects = sorted((bindir / 'VideoAutoTranslateCore.build').glob('*.swift.o'))
sources = []
for p in sorted((ROOT / 'Sources/VideoAutoTranslateApp').glob('*.swift')):
    text = p.read_text()
    if p.name == 'MainView.swift':
        fixture = '''public init() {
        let state = AppState(probeServices: false, recoveryURL: URL(fileURLWithPath: RECOVERY_PATH))
        state.openVideo(url: URL(fileURLWithPath: VIDEO_PATH))
        state.project.llmConfig = LLMConfiguration(providerType: .onlineCustom, onlineBaseURL: "http://127.0.0.1:1", onlineModel: "review-fixture")
        let originals = ["Hello everyone, welcome to our subtitle editing review.", "This line has no translation yet.", "Hello everyone, welcome to our subtitle editing review.", "This long sentence should remain readable while editing and should not hide its ending behind a horizontal single-line input field.", "A short phrase.", "The next sentence discusses video timing and natural pauses.", "Another untranslated line.", "Final sentence of the review sample."]
        state.project.subtitles = originals.enumerated().map { idx, text in
            SubtitleItem(startTime: .from(seconds: Double(idx) * 2), endTime: .from(seconds: Double(idx) * 2 + 1.8), originalText: text, translatedText: idx < 3 ? "这是第\\(idx + 1)句的人工译文，用来检查实际显示与操作。" : "")
        }
        self._appState = StateObject(wrappedValue: state)
    }'''.replace('VIDEO_PATH', '"' + str(video) + '"').replace('RECOVERY_PATH', '"' + str(work / 'Recovery.vatproject') + '"')
        assert text.count('public init() {}') == 1
        text = text.replace('public init() {}', fixture, 1)
    q = work / p.name
    q.write_text(text)
    sources.append(q)
app = work / 'VideoReviewPreview.app'
exe = app / 'Contents/MacOS/VideoReviewPreview'
exe.parent.mkdir(parents=True)
checked(['xcrun', 'swiftc', '-parse-as-library', '-I', str(bindir / 'Modules'), *map(str, sources), *map(str, objects), '-o', str(exe)])
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'VideoReviewPreview','CFBundleIdentifier':'com.videoautotranslate.preview','CFBundleName':'VideoReviewPreview','CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'14.0'}))
checked(['codesign', '--force', '--deep', '--sign', '-', str(app)])
print(app)

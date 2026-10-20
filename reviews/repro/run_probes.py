#!/usr/bin/env python3
"""Run isolated review probes; a completed probe is not a passing product test.

Requires macOS, Xcode and Python packages fastapi, uvicorn, httpx,
python-multipart. No model weights or external API service are used.
"""
import asyncio
import importlib.util
import json
import os
import platform
import resource
import subprocess
import sys
import tempfile
import threading
import time
import types
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = os.environ.copy()
if "DEVELOPER_DIR" not in ENV and Path("/Applications/Xcode.app/Contents/Developer").exists():
    ENV["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def command(args, timeout=120):
    return subprocess.run(args, cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=timeout)


def checked(args):
    p = command(args)
    if p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return p.stdout.strip()


def emit(**values):
    print(json.dumps(values, ensure_ascii=False), flush=True)


class MockTranslation(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        entries = json.loads(body["messages"][1]["content"].split("\n", 1)[1])
        cue_id = entries[0]["id"]
        if "/duplicate/" in self.path:
            result = [{"id": cue_id, "translation": "One"}, {"id": cue_id, "translation": "Two"}]
        elif "/missing/" in self.path:
            result = [{"id": "unknown-id", "translation": "Unrelated"}]
        else:
            time.sleep(0.45)
            result = [{"id": cue_id, "translation": "Generated from old source"}]
        data = json.dumps({"choices": [{"message": {"content": json.dumps(result)}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def swift_probes(work):
    scratch = work / "build"
    checked(["swift", "build", "--scratch-path", str(scratch), "--target", "VideoAutoTranslateCore"])
    bin_dir = Path(checked(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"]))
    objects = sorted((bin_dir / "VideoAutoTranslateCore.build").glob("*.swift.o"))
    if not objects:
        raise RuntimeError("Core object files not found")
    compiler = ["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macosx14.0", "-I", str(bin_dir / "Modules")]

    def compile_probe(source, destination):
        checked(compiler + [str(source)] + [str(o) for o in objects] + ["-o", str(destination)])

    core = work / "core-probe"
    audio = work / "audio-probe"
    compile_probe(Path(__file__).with_name("CoreProbe.swift"), core)
    compile_probe(Path(__file__).with_name("AudioProbe.swift"), audio)
    for name, executable in [("core", core), ("audio", audio)]:
        args = [str(executable)] + (["core"] if name == "core" else [])
        p = command(args, timeout=30)
        emit(probe=name, returncode=p.returncode, stdout=p.stdout.strip(), stderr=p.stderr[-1000:])

    server = ThreadingHTTPServer(("127.0.0.1", 0), MockTranslation)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for mode in ["duplicate", "missing", "stale", "huge-time"]:
            p = command([str(core), mode, f"http://127.0.0.1:{server.server_port}"], timeout=20)
            fatal = next((line for line in p.stderr.splitlines() if "Fatal error:" in line), "")
            emit(probe=mode, returncode=p.returncode, stdout=p.stdout.strip(), fatal=fatal)
    finally:
        server.shutdown()
        server.server_close()

    # Inject deterministic speech callbacks into a temporary source copy.
    # The original continuation/error handling is left unchanged.
    source = (ROOT / "Sources/VideoAutoTranslateCore/TTS/SystemTTSService.swift").read_text()
    source = source.replace("SystemTTSService", "ProbeTTSService").replace("AVSpeechSynthesizer()", "FakeSynthesizer()")
    source += '''
import VideoAutoTranslateCore
final class FakeSynthesizer {
    func write(_ utterance: AVSpeechUtterance, callback: (AVAudioBuffer) -> Void) {
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
        let chunk=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:100)!
        chunk.frameLength=100
        callback(chunk)
        let done=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1)!
        done.frameLength=0
        callback(done)
    }
}
@main struct TTSProbe {
    static func main() async {
        do {
            _ = try await ProbeTTSService().synthesize(text:"test",voice:"en-US",outputURL:URL(fileURLWithPath:CommandLine.arguments[1]))
        } catch { print(error) }
    }
}
'''
    tts_source = work / "TTSProbe.swift"
    tts_source.write_text(source)
    tts = work / "tts-probe"
    compile_probe(tts_source, tts)
    p = command([str(tts), str(work / "nonexistent-parent/audio.wav")], timeout=10)
    fatal = next((line for line in p.stderr.splitlines() if "CONTINUATION MISUSE" in line), "")
    emit(probe="tts-write-error-injected-callbacks", returncode=p.returncode, fatal=fatal)


async def api_probes(asr, work, audio):
    import httpx
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=asr.app), base_url="http://review.local") as client:
        destination = work / "website-created"
        response = await client.post("/v1/models/storage", json={"storage_dir": str(destination)}, headers={"Origin": "https://review.invalid"})
        emit(probe="untrusted-origin-storage-write", status=response.status_code,
             allow_origin=response.headers.get("access-control-allow-origin"),
             allow_credentials=response.headers.get("access-control-allow-credentials"),
             directory_created=destination.exists())
        def slow_inference(*args, **kwargs):
            time.sleep(0.35)
            return {"text": "test", "words": []}
        asr.run_local_transcription = slow_inference
        started = time.monotonic()
        observed = []
        asyncio.get_running_loop().call_later(0.02, lambda: observed.append(time.monotonic() - started))
        await client.post("/v1/audio/transcriptions", files={"file": ("silence.wav", audio.read_bytes(), "audio/wav")})
        await asyncio.sleep(0.01)
        emit(probe="inference-event-loop-stall", timer_due_seconds=0.02, timer_actual_seconds=round(observed[0], 3))


def python_probes(work):
    # No native inference package is loaded, and no model is downloaded.
    sys.modules["mlx_audio"] = types.ModuleType("mlx_audio")
    spec = importlib.util.spec_from_file_location("review_asr_server", ROOT / "scripts/asr_server.py")
    asr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asr)
    asr.CURRENT_STORAGE_DIR = work / "cache"
    asr.DEFAULT_SHARED_DIR = work / "shared"
    asr.DEFAULT_DEDICATED_DIR = work / "dedicated"
    audio = work / "silence.wav"
    with wave.open(str(audio), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(b"\0\0" * 16000 * 3)
    asr.HAS_MLX = False
    result = asr.run_local_transcription(str(audio))
    emit(probe="silence-without-models", text=result["text"], words=len(result["words"]))
    incomplete = asr.CURRENT_STORAGE_DIR / "models--review--incomplete"
    (incomplete / "refs").mkdir(parents=True)
    (incomplete / "refs/main").write_text("not-downloaded")
    emit(probe="incomplete-model-locator", path=str(asr.find_model_path("review/incomplete")))
    asyncio.run(api_probes(asr, work, audio))


def main():
    emit(baseline=checked(["git", "rev-parse", "HEAD"]), platform=platform.platform(), python=sys.version.split()[0])
    with tempfile.TemporaryDirectory(prefix="vat-review-") as temp:
        work = Path(temp)
        swift_probes(work)
        python_probes(work)


if __name__ == "__main__":
    main()

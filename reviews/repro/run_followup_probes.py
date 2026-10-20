#!/usr/bin/env python3
"""Follow-up probes for the review baseline; no production code is modified."""
import asyncio
import importlib.util
import platform
import shutil
import sys
import tempfile
import threading
import time
import types
import wave
from http.server import ThreadingHTTPServer
from pathlib import Path

from run_probes import ROOT, MockTranslation, checked, command, emit


def native_probes(work):
    scratch = work / "build"
    checked(["swift", "build", "--scratch-path", str(scratch), "--target", "VideoAutoTranslateCore"])
    bin_dir = Path(checked(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"]))
    objects = [str(p) for p in sorted((bin_dir / "VideoAutoTranslateCore.build").glob("*.swift.o"))]
    if not objects:
        raise RuntimeError("Core objects missing")
    compiler = ["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine()+"-apple-macosx14.0", "-I", str(bin_dir / "Modules")]

    def compile_probe(sources, output):
        checked(compiler + [str(s) for s in sources] + objects + ["-o", str(output)])

    def run_probe(name, args):
        p = command(args, timeout=35)
        fatal = next((line for line in p.stderr.splitlines() if "Fatal error:" in line), "")
        emit(probe=name, exit=p.returncode, stdout=p.stdout.strip(), fatal=fatal)

    folder = Path(__file__).parent
    core, audio, app = work / "core", work / "audio", work / "app"
    compile_probe([folder / "FollowupProbe.swift"], core)
    compile_probe([folder / "AudioProbe.swift"], audio)
    run_probe("core", [str(core), "core"])
    run_probe("audio", [str(audio)])

    # Preserve cancellation logic; disable only init's unrelated local-service probes.
    source = (ROOT / "Sources/VideoAutoTranslateApp/AppState.swift").read_text()
    startup = '''        Task {
            await sidecarManager.probeExistingStatus()
            await probeLocalOllama()
            await probeLocalASR()
        }
'''
    if startup not in source:
        raise RuntimeError("AppState startup changed; update the explicit test seam")
    app_state = work / "AppState.swift"
    app_state.write_text(source.replace(startup, "", 1))
    compile_probe([folder / "FollowupAppProbe.swift", app_state], app)
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockTranslation)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        for mode in ["duplicate", "missing", "stale", "clear", "cancel", "format-huge"]:
            run_probe(mode, [str(core), mode, base])
        run_probe("app-cancel", [str(app), base])
    finally:
        server.shutdown()
        server.server_close()

    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        video = work / "sample.mp4"
        checked([ffmpeg, "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(video)])
        run_probe("alias-export", [str(core), "alias-export", str(video)])
    else:
        emit(probe="alias-export", skipped="ffmpeg unavailable")

    # Only the synthesizer is replaced; error/continuation/file logic is unchanged.
    source = (ROOT / "Sources/VideoAutoTranslateCore/TTS/SystemTTSService.swift").read_text()
    source = source.replace("SystemTTSService", "ProbeTTSService").replace("AVSpeechSynthesizer()", "FakeSynthesizer()")
    source += '''
import VideoAutoTranslateCore
final class FakeSynthesizer {
 private var saved: ((AVAudioBuffer) -> Void)?
 func write(_ utterance: AVSpeechUtterance, callback: @escaping (AVAudioBuffer) -> Void) {
  saved=callback
  let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
  let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:24000)!
  buffer.frameLength=24000
  for i in 0..<24000 {buffer.floatChannelData![0][i]=0.1}
  callback(buffer)
  let end=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1)!
  end.frameLength=0
  callback(end)
 }
}
@main struct Probe {
 static func main() async {
  let service=ProbeTTSService()
  do {
   let url=try await service.synthesize(text:"test",voice:"en-US",outputURL:URL(fileURLWithPath:CommandLine.arguments[1]))
   let file=try AVAudioFile(forReading:url)
   print("success frames=\\(file.length), header=\\(String(data:try Data(contentsOf:url).prefix(4),encoding:.ascii) ?? "?")")
   withExtendedLifetime(service) {}
  } catch { print("synthesis returned error without crash: \\(error.localizedDescription)") }
 }
}
'''
    tts_source, tts = work / "TTS.swift", work / "tts"
    tts_source.write_text(source)
    compile_probe([tts_source], tts)
    run_probe("tts-callback-success", [str(tts), str(work / "valid.wav")])
    run_probe("tts-callback-write-error", [str(tts), str(work / "missing/audio.wav")])


async def api_probes(asr, work, audio):
    import httpx
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=asr.app), base_url="http://review.local") as c:
        r = await c.post("/v1/audio/transcriptions", files={"file": ("silence.wav", audio.read_bytes(), "audio/wav")})
        emit(probe="as-is-asr-route", status=r.status_code, body=r.json())
        original_home = Path.__dict__["home"]
        Path.home = classmethod(lambda cls: work)
        try:
            destination = work / "untrusted-origin"
            r = await c.post("/v1/models/storage", json={"storage_dir": str(destination)}, headers={"Origin": "https://review.invalid"})
            emit(probe="untrusted-origin-storage", status=r.status_code, allow_origin=r.headers.get("access-control-allow-origin"), created=destination.exists())
            r = await c.options("/v1/models/storage", headers={"Origin": "https://review.invalid", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"})
            emit(probe="untrusted-origin-preflight", status=r.status_code)
        finally:
            Path.home = original_home
        # Explicit injection tests the intended worker path, not the as-is endpoint.
        asr.asyncio = asyncio
        active, peak = 0, 0
        lock = threading.Lock()
        def fake(*args, **kwargs):
            nonlocal active, peak
            with lock:
                active += 1
                peak = max(peak, active)
            time.sleep(0.2)
            with lock:
                active -= 1
            return {"text": "mock", "words": []}
        asr.run_local_transcription = fake
        responses = await asyncio.gather(*[c.post("/v1/audio/transcriptions", files={"file": ("a.wav", b"abc", "audio/wav")}) for _ in range(2)])
        emit(probe="thread-offload-with-import-injected", statuses=[r.status_code for r in responses], max_parallel_inferences=peak)


def python_probes(work):
    sys.modules["mlx_audio"] = types.ModuleType("mlx_audio")
    spec = importlib.util.spec_from_file_location("followup_asr", ROOT / "scripts/asr_server.py")
    asr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asr)
    asr.CURRENT_STORAGE_DIR, asr.DEFAULT_SHARED_DIR, asr.DEFAULT_DEDICATED_DIR = work / "cache", work / "shared", work / "dedicated"
    asr.HAS_MLX = False
    audio = work / "silence.wav"
    with wave.open(str(audio), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(b"\0\0" * 16000 * 3)
    try:
        asr.run_local_transcription(str(audio))
        emit(probe="no-model-production", unexpected_success=True)
    except Exception as exc:
        emit(probe="no-model-production", error=str(exc))
    asr.ENABLE_MOCK_FALLBACK = True
    emit(probe="explicit-mock", flag=asr.run_local_transcription(str(audio)).get("is_mock"))
    model = work / "cache/models--review--fake"
    model.mkdir(parents=True)
    (model / "config.json").write_text("{}")
    (model / "model.safetensors").write_bytes(b"")
    emit(probe="empty-weight-model", accepted=asr.find_model_path("review/fake") is not None)
    asyncio.run(api_probes(asr, work, audio))


def main():
    emit(baseline=checked(["git", "rev-parse", "HEAD"]), python=sys.version.split()[0])
    with tempfile.TemporaryDirectory(prefix="vat-followup-review-") as temp:
        work = Path(temp)
        native_probes(work)
        python_probes(work)


if __name__ == "__main__":
    main()

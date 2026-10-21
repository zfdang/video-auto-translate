#!/usr/bin/env python3
"""
本地轻量级 ASR 服务 (兼容 OpenAI /v1/audio/transcriptions 标准接口)
支持模型下载、多路径存储管理 (共享/私有/自定义)、国内镜像加速 (hf-mirror.com)

运行方式:
  python3 scripts/asr_server.py
  或指定端口与模型目录:
  python3 scripts/asr_server.py --port 8765 --models-dir ~/.cache/huggingface/hub
"""

import os
import sys
import time
import shutil
import asyncio
import tempfile
import argparse
import threading
from pathlib import Path
from typing import Optional, Dict, Any, List

import uvicorn
from fastapi import FastAPI, File, UploadFile, Form, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(title="VideoAutoTranslate Local ASR Service", version="1.1.0")

# R12: 收紧 CORS，仅允许本机 Loopback 来源，杜绝任意第三方网页跨域发起的未授权请求
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://127.0.0.1",
        "http://localhost",
        "http://127.0.0.1:8765",
        "http://localhost:8765"
    ],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# 动态探测本地可用的识别引擎
HAS_MLX = False
try:
    import mlx_audio
    HAS_MLX = True
except ImportError:
    pass

# 全局模拟开关 (默认关闭，仅在传入 --mock 时启用，杜绝生产环境伪造识别结果，R02)
ENABLE_MOCK_FALLBACK = False

# 全局存储配置与下载状态跟踪
HOME = Path.home()
DEFAULT_SHARED_DIR = HOME / ".cache" / "huggingface" / "hub"
DEFAULT_DEDICATED_DIR = HOME / "Library" / "Application Support" / "VideoAutoTranslate" / "models"

CURRENT_STORAGE_DIR = DEFAULT_SHARED_DIR

# 下载进度字典: model_id -> dict(status, progress, speed, error, local_path)
DOWNLOAD_TASKS: Dict[str, Dict[str, Any]] = {}

PRESET_MODELS = [
    {
        "id": "qwen3-asr-1.7b",
        "displayName": "Qwen3-ASR (1.7B MLX 8-bit)",
        "repoId": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "isRepo": True,
        "size": "~1.8 GB"
    },
    {
        "id": "qwen3-aligner-0.6b",
        "displayName": "Qwen3-ForcedAligner (0.6B 8-bit)",
        "repoId": "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
        "isRepo": True,
        "size": "~600 MB"
    }
]

def has_non_empty_weights(dir_path: Path) -> bool:
    """FU09: 校验目录中是否存在有效的大于 1MB 的实体权重文件，防止 0 字节虚假文件通过"""
    for pattern in ("*.safetensors", "*.bin", "*.npz"):
        for f in dir_path.glob(pattern):
            try:
                if f.is_file() and f.stat().st_size > 1024 * 1024:
                    return True
            except OSError:
                continue
    return False


def has_valid_model_files(p: Path) -> bool:
    """R26 / FU09: 严格检验模型完整性，仅当存在配置文件和非空权重文件时才视为就绪"""
    if not p.exists() or not p.is_dir():
        return False
    # 检查当前目录
    cfg = p / "config.json"
    if cfg.exists() and cfg.stat().st_size > 10 and has_non_empty_weights(p):
        return True
    # 检查 snapshots 目录
    snapshots_dir = p / "snapshots"
    if snapshots_dir.exists() and snapshots_dir.is_dir():
        for snap in snapshots_dir.iterdir():
            if snap.is_dir():
                s_cfg = snap / "config.json"
                if s_cfg.exists() and s_cfg.stat().st_size > 10 and has_non_empty_weights(snap):
                    return True
    return False


def find_model_path(repo_or_filename: str, is_repo: bool = True) -> Optional[Path]:
    """多目录扫描模型是否存在并自动定位快照或实体目录 (R26 / FU09: 增加非空权重完整性校验)"""
    candidate_dirs = [
        CURRENT_STORAGE_DIR,
        DEFAULT_SHARED_DIR,
        DEFAULT_DEDICATED_DIR
    ]

    def resolve_snapshot_or_target(p: Path) -> Optional[Path]:
        snapshots_dir = p / "snapshots"
        if snapshots_dir.exists() and any(snapshots_dir.iterdir()):
            snapshots = sorted(snapshots_dir.glob("*"), key=os.path.getmtime)
            for snap in reversed(snapshots):
                if snap.is_dir() and (snap / "config.json").exists() and (snap / "config.json").stat().st_size > 10 and has_non_empty_weights(snap):
                    return snap
        cfg = p / "config.json"
        if cfg.exists() and cfg.stat().st_size > 10 and has_non_empty_weights(p):
            return p
        return None

    safe_repo = "models--" + repo_or_filename.replace("/", "--")
    for d in candidate_dirs:
        if not d.exists():
            continue
        if is_repo:
            target = d / safe_repo
            if target.exists():
                resolved = resolve_snapshot_or_target(target)
                if resolved:
                    return resolved
            direct = d / repo_or_filename
            if direct.exists():
                resolved = resolve_snapshot_or_target(direct)
                if resolved:
                    return resolved
        else:
            file_path = d / repo_or_filename
            if file_path.exists() and file_path.stat().st_size > 1024 * 1024:
                return file_path
    return None


LOADED_MODELS: Dict[str, Any] = {}
MODEL_LOCK = threading.Lock()

def get_loaded_model(model_path: str):
    """线程安全并单例复用已载入的 ASR 与对齐模型"""
    with MODEL_LOCK:
        if model_path not in LOADED_MODELS:
            from mlx_audio import stt
            print(f"[ASR Server] 正在载入本地推理模型至 Apple Silicon 显存: {model_path}", flush=True)
            LOADED_MODELS[model_path] = stt.load_model(model_path)
            print(f"[ASR Server] 模型载入完成并热驻留显存: {model_path}", flush=True)
        return LOADED_MODELS[model_path]


LANGUAGE_NAMES = {
    "zh": "Chinese",
    "en": "English",
    "ja": "Japanese",
    "ko": "Korean",
    "yue": "Cantonese",
    "fr": "French",
    "de": "German",
    "es": "Spanish",
    "ru": "Russian",
}


@app.get("/health")
def health_check():
    return {
        "status": "ok",
        "engine": "mlx-audio (Apple Silicon)" if HAS_MLX else "fallback-engine",
        "device": "Apple Silicon (Metal)" if HAS_MLX else "CPU",
        "current_storage_dir": str(CURRENT_STORAGE_DIR)
    }


class StorageConfigRequest(BaseModel):
    storage_dir: str


@app.get("/v1/models/storage")
def get_storage():
    return {
        "current_dir": str(CURRENT_STORAGE_DIR),
        "shared_dir": str(DEFAULT_SHARED_DIR),
        "dedicated_dir": str(DEFAULT_DEDICATED_DIR)
    }


@app.post("/v1/models/storage")
def set_storage(req: StorageConfigRequest):
    global CURRENT_STORAGE_DIR
    target = Path(req.storage_dir).expanduser().resolve()
    # R12: 限制目录范围，仅允许设置在用户主目录或 /Volumes 外接磁盘下，拒绝系统关键目录
    home_path = Path.home().resolve()
    if not (str(target).startswith(str(home_path)) or str(target).startswith("/Volumes/")):
        raise HTTPException(status_code=403, detail="模型存储目录只能设置在当前用户主目录或 /Volumes 下")
    target.mkdir(parents=True, exist_ok=True)
    CURRENT_STORAGE_DIR = target
    return {"status": "ok", "current_dir": str(CURRENT_STORAGE_DIR)}


@app.get("/v1/models/list")
def list_models_status():
    result = []
    for m in PRESET_MODELS:
        path = find_model_path(m["repoId"], m["isRepo"])
        state = "ready" if path else "not_downloaded"
        result.append({
            "id": m["id"],
            "displayName": m["displayName"],
            "repoId": m["repoId"],
            "isRepo": m["isRepo"],
            "size": m["size"],
            "state": state,
            "localPath": str(path) if path else None
        })
    return {"models": result, "storage_dir": str(CURRENT_STORAGE_DIR)}


@app.get("/v1/models")
def list_models():
    return {
        "data": [
            {"id": "qwen3-asr-1.7b", "object": "model", "owned_by": "local"},
            {"id": "qwen3-asr-0.6b", "object": "model", "owned_by": "local"},
            {"id": "whisper-small", "object": "model", "owned_by": "local"}
        ]
    }


class DownloadRequest(BaseModel):
    model_id: str
    repo_id: str
    storage_dir: Optional[str] = None
    mirror: Optional[str] = "https://hf-mirror.com"


MODEL_APPROX_SIZES = {
    "qwen3-asr-1.7b": 2_460_000_000,
    "mlx-community/Qwen3-ASR-1.7B-8bit": 2_460_000_000,
    "qwen3-aligner-0.6b": 1_220_000_000,
    "mlx-community/Qwen3-ForcedAligner-0.6B-8bit": 1_220_000_000,
    "qwen3-asr-0.6b": 1_000_000_000,
    "mlx-community/Qwen3-ASR-0.6B-8bit": 1_000_000_000,
}


def get_dir_size(path: Path) -> int:
    total = 0
    try:
        if not path.exists():
            return 0
        if path.is_file():
            return path.stat().st_size
        for p in path.rglob("*"):
            try:
                if p.is_file():
                    total += p.stat().st_size
            except (OSError, PermissionError):
                pass
    except (OSError, PermissionError):
        pass
    return total


def background_repo_download(model_id: str, repo_id: str, dest_dir: Path, mirror: str):
    """后台执行模型下载任务，并动态监控下载进度与速率"""
    DOWNLOAD_TASKS[model_id] = {
        "status": "downloading",
        "progress": 0.05,
        "speed": "正在连接下载源...",
        "error": None,
        "local_path": None
    }
    
    # 注入环境变量镜像
    if mirror:
        os.environ["HF_ENDPOINT"] = mirror

    stop_event = threading.Event()
    folder_safe_name = "models--" + repo_id.replace("/", "--")
    repo_folder = dest_dir / folder_safe_name
    expected_size = MODEL_APPROX_SIZES.get(model_id) or MODEL_APPROX_SIZES.get(repo_id, 2_000_000_000)

    def monitor():
        prev_size = get_dir_size(repo_folder)
        prev_time = time.time()
        while not stop_event.is_set():
            time.sleep(0.8)
            if stop_event.is_set():
                break
            now = time.time()
            dt = max(0.1, now - prev_time)
            cur_size = get_dir_size(repo_folder)
            delta = max(0, cur_size - prev_size)
            speed_mb_s = (delta / dt) / (1024 * 1024)
            
            cur_mb = cur_size / (1024 * 1024)
            tot_mb = expected_size / (1024 * 1024)
            prog = min(0.98, max(0.05, cur_size / expected_size))
            
            speed_text = f"{speed_mb_s:.1f} MB/s ({cur_mb:.1f} MB / {tot_mb:.1f} MB)" if delta > 0 else f"下载传输中 ({cur_mb:.1f} MB)"
            DOWNLOAD_TASKS[model_id]["progress"] = prog
            DOWNLOAD_TASKS[model_id]["speed"] = speed_text
            
            prev_size = cur_size
            prev_time = now

    mon_thread = threading.Thread(target=monitor, daemon=True)

    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
        mon_thread.start()

        # 尝试使用 huggingface_hub snapshot_download
        try:
            from huggingface_hub import snapshot_download
            downloaded_path = snapshot_download(
                repo_id=repo_id,
                cache_dir=dest_dir,
                endpoint=mirror if mirror else None,
                resume_download=True
            )
            stop_event.set()
            mon_thread.join(timeout=1.0)
            DOWNLOAD_TASKS[model_id] = {
                "status": "ready",
                "progress": 1.0,
                "speed": "下载完成",
                "error": None,
                "local_path": str(downloaded_path)
            }
            return
        except ImportError:
            pass

        # 若未安装 huggingface_hub，使用 git 或 curl 备用下载
        DOWNLOAD_TASKS[model_id]["speed"] = "调用 git clone 拉取权重..."
        clone_url = f"{mirror.rstrip('/')}/{repo_id}.git"
        import subprocess
        res = subprocess.run(["git", "clone", "--depth", "1", clone_url, str(repo_folder)], capture_output=True, text=True)
        stop_event.set()
        mon_thread.join(timeout=1.0)
        if res.returncode == 0:
            DOWNLOAD_TASKS[model_id] = {
                "status": "ready",
                "progress": 1.0,
                "speed": "下载完成",
                "error": None,
                "local_path": str(repo_folder)
            }
        else:
            raise RuntimeError(f"Git clone 失败: {res.stderr}")

    except Exception as exc:
        stop_event.set()
        DOWNLOAD_TASKS[model_id] = {
            "status": "failed",
            "progress": 0.0,
            "speed": "下载出错",
            "error": str(exc),
            "local_path": None
        }


@app.post("/v1/models/download")
def start_model_download(req: DownloadRequest, background_tasks: BackgroundTasks):
    dest = Path(req.storage_dir).expanduser().resolve() if req.storage_dir else CURRENT_STORAGE_DIR
    background_tasks.add_task(
        background_repo_download,
        model_id=req.model_id,
        repo_id=req.repo_id,
        dest_dir=dest,
        mirror=req.mirror or "https://hf-mirror.com"
    )
    return {"status": "started", "model_id": req.model_id, "dest_dir": str(dest)}


@app.get("/v1/models/download/status")
def get_download_status(model_id: str):
    if model_id not in DOWNLOAD_TASKS:
        # 检查是否已在本地磁盘存在
        preset = next((m for m in PRESET_MODELS if m["id"] == model_id), None)
        if preset:
            path = find_model_path(preset["repoId"], preset["isRepo"])
            if path:
                return {"status": "ready", "progress": 1.0, "speed": "已存在", "local_path": str(path)}
        return {"status": "not_downloaded", "progress": 0.0, "speed": ""}

    return DOWNLOAD_TASKS[model_id]


@app.post("/v1/audio/transcriptions")
async def create_transcription(
    file: UploadFile = File(...),
    model: str = Form("qwen3-asr"),
    response_format: str = Form("verbose_json"),
    language: Optional[str] = Form(None)
):
    """
    处理标准 OpenAI Audio API 转录请求
    返回带有每个词精确时间戳的 verbose_json (R21: 异步线程池执行，不阻塞事件循环)
    """
    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp_path = tmp.name
        content = await file.read()
        tmp.write(content)

    try:
        # R21: 移至工作线程执行 CPU/GPU 同步密集型推理，避免卡死 ASGI 事件循环导致 /health 离线
        result = await asyncio.to_thread(run_local_transcription, tmp_path, model=model, language=language)
        return result
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def generate_mock_transcription(audio_path: str) -> dict:
    """仅在显式传入 --mock 时启用的模拟数据生成器 (R02)"""
    import wave
    import contextlib

    duration = 5.0
    try:
        with contextlib.closing(wave.open(audio_path, 'r')) as f:
            frames = f.getnframes()
            rate = f.getframerate()
            duration = frames / float(rate)
    except Exception:
        pass

    words = []
    current = 0.5
    demo_sentences = [
        "Welcome", "to", "the", "native", "video", "auto", "translate", "application.",
        "This", "audio", "has", "been", "successfully", "processed", "by", "the", "local", "ASR", "service.",
        "You", "can", "now", "proceed", "with", "editing", "and", "translating", "these", "subtitles."
    ]

    for w in demo_sentences:
        if current >= duration - 0.5:
            break
        w_dur = 0.35
        words.append({
            "word": w,
            "start": round(current, 3),
            "end": round(current + w_dur, 3)
        })
        current += w_dur + 0.1

    full_text = " ".join(w["word"] for w in words)
    return {
        "text": full_text,
        "words": words,
        "is_mock": True,
        "segments": [
            {
                "id": 0,
                "text": full_text,
                "start": words[0]["start"] if words else 0.0,
                "end": words[-1]["end"] if words else duration,
                "words": words
            }
        ]
    }


def run_local_transcription(audio_path: str, model: str = "qwen3-asr", language: Optional[str] = None) -> dict:
    """
    执行物理音频转录并提取逐词时间戳 (使用 Qwen3-ASR 与 Qwen3-ForcedAligner)
    R02: 杜绝在生产中伪造成功，无模型或异常时明确抛错，仅显式开启 --mock 时允许模拟
    """
    qwen_asr_path = find_model_path("mlx-community/Qwen3-ASR-1.7B-8bit", is_repo=True)
    qwen_aligner_path = find_model_path("mlx-community/Qwen3-ForcedAligner-0.6B-8bit", is_repo=True)

    if not HAS_MLX:
        if ENABLE_MOCK_FALLBACK:
            return generate_mock_transcription(audio_path)
        raise RuntimeError("mlx_audio 依赖库未就绪，无法在 Apple Silicon 上执行物理模型转录")

    if not qwen_asr_path:
        if ENABLE_MOCK_FALLBACK:
            return generate_mock_transcription(audio_path)
        raise RuntimeError("未在本地模型目录中找到 Qwen3-ASR-1.7B 识别模型，请先下载模型")

    try:
        asr_model = get_loaded_model(str(qwen_asr_path))
        kwargs = {}
        if language and language != "auto":
            kwargs["language"] = language

        print(f"[ASR Server] 开始转录音频: {audio_path}, 参数: {kwargs}", flush=True)
        res = asr_model.generate(audio_path, **kwargs)
        transcribed_text = res.text.strip() if hasattr(res, "text") and res.text else ""
        
        detected_lang = getattr(res, "language", None)
        if isinstance(detected_lang, list) and detected_lang:
            detected_lang = detected_lang[0]
        print(f"[ASR Server] 转录完成 (文本字数: {len(transcribed_text)}, 检测语种: {detected_lang})", flush=True)

        words = []
        # 如果转录产生文本且对齐模型就绪，使用 Qwen3-ForcedAligner 提取精确逐词时间戳
        if transcribed_text and qwen_aligner_path:
            try:
                aligner_model = get_loaded_model(str(qwen_aligner_path))
                align_lang = "English"
                if language and language != "auto":
                    align_lang = LANGUAGE_NAMES.get(language, language)
                elif detected_lang:
                    align_lang = LANGUAGE_NAMES.get(detected_lang, str(detected_lang))

                print(f"[ASR Server] 开始词级时间戳强制对齐 (对齐语言: {align_lang})...", flush=True)
                aligned = aligner_model.generate(audio_path, text=transcribed_text, language=align_lang)

                align_items = getattr(aligned, "items", []) or []
                if not align_items and hasattr(aligned, "segments"):
                    align_items = aligned.segments or []

                for it in align_items:
                    it_text = getattr(it, "text", "") if hasattr(it, "text") else it.get("text", "")
                    it_start = getattr(it, "start_time", None) if hasattr(it, "start_time") else it.get("start", 0.0)
                    it_end = getattr(it, "end_time", None) if hasattr(it, "end_time") else it.get("end", 0.0)

                    if it_text and str(it_text).strip():
                        words.append({
                            "word": str(it_text).strip(),
                            "start": round(float(it_start), 3),
                            "end": round(float(it_end), 3)
                        })
                print(f"[ASR Server] 强制对齐完成，共提取 {len(words)} 个词/字时间序列", flush=True)
            except Exception as align_err:
                print(f"[ASR Server] 词级对齐异常 (回退至 ASR 片段): {align_err}", file=sys.stderr)

        # 提取 segments
        segments = []
        if hasattr(res, "segments") and res.segments:
            for idx, s in enumerate(res.segments):
                s_text = s.get("text", "") if isinstance(s, dict) else getattr(s, "text", "")
                s_start = s.get("start", 0.0) if isinstance(s, dict) else getattr(s, "start", 0.0)
                s_end = s.get("end", 0.0) if isinstance(s, dict) else getattr(s, "end", 0.0)
                segments.append({
                    "id": idx,
                    "text": s_text,
                    "start": round(float(s_start), 3),
                    "end": round(float(s_end), 3),
                    "words": []
                })

        if words:
            start_t = words[0]["start"]
            end_t = words[-1]["end"]
            if not segments:
                segments = [{
                    "id": 0,
                    "text": transcribed_text,
                    "start": start_t,
                    "end": end_t,
                    "words": words
                }]
            return {
                "text": transcribed_text,
                "words": words,
                "segments": segments
            }
        elif transcribed_text:
            return {
                "text": transcribed_text,
                "words": [],
                "segments": segments if segments else [{
                    "id": 0,
                    "text": transcribed_text,
                    "start": 0.0,
                    "end": 5.0,
                    "words": []
                }]
            }
        else:
            return {
                "text": "",
                "words": [],
                "segments": []
            }
    except Exception as e:
        if ENABLE_MOCK_FALLBACK:
            print(f"[ASR Server] MLX 识别处理失败，回退至模拟时序 (--mock 已启用): {e}", file=sys.stderr)
            return generate_mock_transcription(audio_path)
        raise RuntimeError(f"ASR 识别处理失败: {e}")


def main():
    parser = argparse.ArgumentParser(description="VideoAutoTranslate Local Lightweight ASR Service")
    parser.add_argument("--host", default="127.0.0.1", help="绑定监听 IP")
    parser.add_argument("--port", type=int, default=8765, help="监听端口 (默认 8765)")
    parser.add_argument("--models-dir", default=None, help="模型存储目录 (默认 ~/.cache/huggingface/hub)")
    parser.add_argument("--mock", action="store_true", help="允许在无模型或异常时回退至模拟数据 (仅限开发调试)")
    args = parser.parse_args()

    global CURRENT_STORAGE_DIR, ENABLE_MOCK_FALLBACK
    if args.mock:
        ENABLE_MOCK_FALLBACK = True
        print("[ASR Server] 警告: 已开启 --mock 模拟回退模式 (开发调试专属)", file=sys.stderr)

    if args.models_dir:
        CURRENT_STORAGE_DIR = Path(args.models_dir).expanduser().resolve()
        CURRENT_STORAGE_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("  VideoAutoTranslate 本地轻量 ASR & 模型管理服务")
    print("=" * 60)
    print(f"  监听地址: http://{args.host}:{args.port}")
    print(f"  当前模型存储目录: {CURRENT_STORAGE_DIR}")
    print(f"  OpenAI 兼容端点: http://{args.host}:{args.port}/v1/audio/transcriptions")
    print(f"  模型列表与状态: http://{args.host}:{args.port}/v1/models/list")
    print(f"  健康探测端点:   http://{args.host}:{args.port}/health")
    print("=" * 60)

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
端到端完整管线测试脚本 (End-to-End Pipeline Test)
测试流程：
1. 提取视频音频至 16kHz 单声道 WAV
2. 调用本地 Qwen3-ASR (1.7B) + Qwen3-ForcedAligner (0.6B) 进行语音识别与词级时间戳对齐
3. 执行智能自然语言语义断句，生成标准单行字幕
4. 调用本地 Ollama (Qwen2.5) 进行地道影视双语翻译
5. 导出双语标准 SRT 文件并输出测试总结
"""

import os
import sys
import json
import time
import subprocess
import urllib.request
import urllib.error
from pathlib import Path


def format_srt_time(seconds: float) -> str:
    hrs = int(seconds // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int(round((seconds - int(seconds)) * 1000))
    if millis >= 1000:
        millis = 999
    return f"{hrs:02d}:{mins:02d}:{secs:02d},{millis:03d}"


def extract_audio(video_path: str, output_wav: str):
    cmd = [
        "ffmpeg", "-y", "-i", video_path,
        "-vn", "-ar", "16000", "-ac", "1",
        "-c:a", "pcm_s16le", output_wav
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        raise RuntimeError(f"FFmpeg 音频提取失败: {res.stderr.decode('utf-8', errors='ignore')}")


def call_asr_api(wav_path: str, asr_url: str = "http://127.0.0.1:8765/v1/audio/transcriptions") -> dict:
    import requests

    with open(wav_path, "rb") as f:
        files = {"file": (os.path.basename(wav_path), f, "audio/wav")}
        data = {
            "model": "qwen3-asr",
            "response_format": "verbose_json"
        }
        resp = requests.post(asr_url, files=files, data=data, timeout=300)

    if resp.status_code != 200:
        raise RuntimeError(f"ASR 服务报错 (HTTP {resp.status_code}): {resp.text}")
    return resp.json()


def segment_tokens(words: list, max_chars_per_line: int = 24, max_pause_gap: float = 0.35) -> list:
    """语义与停顿断句器"""
    if not words:
        return []

    lines = []
    curr = []
    curr_len = 0

    for i, w in enumerate(words):
        curr.append(w)
        curr_len += len(w["word"])
        is_last = (i == len(words) - 1)
        split = False

        if is_last:
            split = True
        else:
            next_w = words[i + 1]
            gap = next_w["start"] - w["end"]
            if gap >= max_pause_gap:
                split = True
            elif any(punct in w["word"] for punct in "。！？.!?"):
                split = True
            elif curr_len >= max_chars_per_line:
                split = True

        if split and curr:
            start_t = curr[0]["start"]
            end_t = max(curr[0]["start"] + 0.1, curr[-1]["end"])
            # 智能拼接 CJK / 英文
            text = " ".join(item["word"] for item in curr)
            lines.append({
                "id": str(len(lines) + 1),
                "start": start_t,
                "end": end_t,
                "text": text,
                "words": curr[:]
            })
            curr.clear()
            curr_len = 0

    return lines


def translate_with_ollama(subtitles: list, model: str = "qwen2.5:latest", target_lang: str = "简体中文") -> list:
    """使用本地 Ollama Qwen2.5 进行影视级双语字幕翻译"""
    import requests
    ollama_url = "http://localhost:11434/v1/chat/completions"

    chunk_size = 10
    chunks = [subtitles[i:i + chunk_size] for i in range(0, len(subtitles), chunk_size)]

    for chunk_idx, chunk in enumerate(chunks):
        input_list = [{"id": s["id"], "text": s["text"]} for s in chunk]
        system_prompt = f"""你是一名顶级的专业影视字幕翻译家。请将输入的字幕列表翻译为【{target_lang}】。

【翻译规范】
1. 保持原文的语气、情感和语境，口语化、接地气，绝不要生硬直译。
2. 字符长度限制：每行译文长度必须适中，杜绝长篇大论，方便观众快速阅读。
3. 必须输出严格的 JSON 数组格式，不要输出任何其他的解释或 Markdown 代码块以外的内容。

输出示例：
[
  {{"id": "...", "translation": "..."}}
]"""
        user_prompt = f"待翻译字幕列表：\n{json.dumps(input_list, ensure_ascii=False, indent=2)}"

        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ],
            "temperature": 0.3
        }

        try:
            resp = requests.post(ollama_url, json=payload, timeout=120)
            if resp.status_code == 200:
                data = resp.json()
                content = data["choices"][0]["message"]["content"].strip()
                if content.startswith("```json"):
                    content = content[7:]
                elif content.startswith("```"):
                    content = content[3:]
                if content.endswith("```"):
                    content = content[:-3]
                content = content.strip()

                entries = json.loads(content)
                trans_map = {str(item["id"]): item.get("translation", "") for item in entries if "id" in item}
                for s in chunk:
                    s["translation"] = trans_map.get(s["id"], "")
            else:
                print(f"[Warning] 批次 {chunk_idx + 1} 翻译 HTTP {resp.status_code}: {resp.text}", file=sys.stderr)
        except Exception as e:
            print(f"[Warning] 批次 {chunk_idx + 1} 翻译失败: {e}", file=sys.stderr)
            for s in chunk:
                if "translation" not in s:
                    s["translation"] = ""

    return subtitles


def export_srt(subtitles: list, out_path: str):
    lines = []
    for i, s in enumerate(subtitles, 1):
        lines.append(str(i))
        start_str = format_srt_time(s["start"])
        end_str = format_srt_time(s["end"])
        lines.append(f"{start_str} --> {end_str}")
        if s.get("translation"):
            lines.append(s["translation"])
        lines.append(s["text"])
        lines.append("")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    video_path = sys.argv[1] if len(sys.argv) > 1 else "/Users/zfdang/workspaces/video-auto-translate/Tests/Fme9C5ShSr2fuWQ8_Translated.mp4"
    if not os.path.exists(video_path):
        print(f"错误: 视频文件不存在: {video_path}")
        sys.exit(1)

    print("=" * 68)
    print("  VideoAutoTranslate 端到端完整管线真实测试 (E2E Test)")
    print("=" * 68)
    print(f"  源视频文件: {video_path}")
    print(f"  视频大小:   {os.path.getsize(video_path) / (1024*1024):.2f} MB")
    print("=" * 68)

    # 1. 抽取音频
    temp_wav = f"/tmp/e2e_test_{int(time.time())}.wav"
    print("\n[阶段 1/5] 正在提取 16kHz 单声道 LinearPCM 音频...")
    t0 = time.time()
    extract_audio(video_path, temp_wav)
    t1 = time.time()
    wav_size = os.path.getsize(temp_wav) / (1024 * 1024)
    print(f"  ✓ 音频提取完成: {temp_wav} ({wav_size:.2f} MB, 耗时: {t1 - t0:.2f}s)")

    # 2. ASR 语音识别与词级对齐
    print("\n[阶段 2/5] 正在调用本地 Qwen3-ASR + Qwen3-ForcedAligner 进行物理转录...")
    t2 = time.time()
    asr_res = call_asr_api(temp_wav)
    t3 = time.time()
    words = asr_res.get("words", [])
    full_text = asr_res.get("text", "")
    print(f"  ✓ 转录与对齐完成 (词数: {len(words)}, 耗时: {t3 - t2:.2f}s)")
    print(f"  文本预览: {full_text[:120]}...")

    # 3. 语义与停顿断句
    print("\n[阶段 3/5] 正在执行语义断句与单行字幕规整...")
    subtitles = segment_tokens(words, max_chars_per_line=28, max_pause_gap=0.35)
    print(f"  ✓ 成功规整为 {len(subtitles)} 行字幕")

    # 4. Ollama LLM 翻译
    print("\n[阶段 4/5] 正在调用本地 Ollama (qwen2.5:latest) 进行智能双语影视翻译...")
    t4 = time.time()
    subtitles = translate_with_ollama(subtitles, model="qwen2.5:latest", target_lang="简体中文")
    t5 = time.time()
    print(f"  ✓ 全量字幕翻译完成 (共 {len(subtitles)} 行, 耗时: {t5 - t4:.2f}s)")

    # 5. 导出双语 SRT
    base_name = os.path.splitext(os.path.basename(video_path))[0]
    out_dir = os.path.dirname(os.path.abspath(video_path))
    srt_path = os.path.join(out_dir, f"{base_name}.srt")
    export_srt(subtitles, srt_path)
    print(f"\n[阶段 5/5] 正在导出双语标准 SRT 文件...")
    print(f"  ✓ SRT 文件已生成至: {srt_path}")

    # 清理临时 wav
    if os.path.exists(temp_wav):
        os.remove(temp_wav)

    # 打印前 10 行成果
    print("\n" + "=" * 68)
    print("  端到端生成成果预览 (前 10 行双语字幕)")
    print("=" * 68)
    for i, s in enumerate(subtitles[:10], 1):
        start_str = format_srt_time(s["start"])
        end_str = format_srt_time(s["end"])
        print(f"[{i:02d}] {start_str} --> {end_str}")
        print(f"     原文: {s['text']}")
        print(f"     译文: {s.get('translation', '')}")
        print("-" * 50)

    total_time = (t1 - t0) + (t3 - t2) + (t5 - t4)
    translated_count = sum(1 for s in subtitles if s.get("translation", "").strip())
    if not subtitles or (len(subtitles) > 0 and translated_count == 0):
        print(f"\n❌ 端到端测试失败: 字幕集为空或未成功生成任何译文！", file=sys.stderr)
        sys.exit(1)

    print(f"\n★ 端到端全流程测试全部成功！(成功翻译 {translated_count}/{len(subtitles)} 行，总处理耗时: {total_time:.2f}s)")
    print("=" * 68)


if __name__ == "__main__":
    main()

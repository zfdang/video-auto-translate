#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?Supply the managed runtime directory}"
PYTHON="${2:-}"
if [ -z "$PYTHON" ]; then
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c 'import sys; assert (3,10) <= sys.version_info < (3,14)' 2>/dev/null; then
      PYTHON="$candidate"
      break
    fi
  done
fi
if [ -z "$PYTHON" ]; then
  echo "需要 Python 3.10–3.13（建议 3.12）。请安装后在设置中选择解释器，再重试。" >&2
  exit 1
fi
"$PYTHON" -c 'import sys; assert (3,10) <= sys.version_info < (3,14), "需要 Python 3.10–3.13"'
mkdir -p "$(dirname "$TARGET")"
"$PYTHON" -m venv "$TARGET"
"$TARGET/bin/python" -m pip install --disable-pip-version-check -r "$SCRIPT_DIR/runtime-requirements.txt"
"$TARGET/bin/python" -c 'import fastapi, uvicorn, multipart, mlx_audio, huggingface_hub, edge_tts'
echo "识别与配音环境已准备完成；接下来请下载识别与对齐模型。"

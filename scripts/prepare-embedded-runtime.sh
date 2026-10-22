#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-$PROJECT_DIR/.build/embedded-runtime}"

echo "============================================================"
echo "  准备 VideoAutoTranslate 内嵌独立 Portable Python 运行环境"
echo "  目标路径: $TARGET"
echo "============================================================"

# 1. 快速检查目标环境是否已经准备就绪且功能完整 (目标必须是真实物理目录，绝不能是符号链接)
if [ -x "$TARGET/bin/python3" ] && [ ! -L "$TARGET" ]; then
    echo "==> 检测到已有环境，正在校验核心依赖完整性..."
    if "$TARGET/bin/python3" -c "import fastapi, uvicorn, edge_tts, mlx_audio" 2>/dev/null; then
        echo "==> 内嵌独立运行环境校验通过，直接复用！"
        exit 0
    else
        echo "==> 依赖不完整，正在重新配置..."
    fi
fi

# 解析目录真实物理路径 (避免指向 uv 缓存中的符号链接)
resolve_real_dir() {
    local target_path="$1"
    if [ -d "$target_path" ]; then
        (cd -P "$target_path" && pwd)
    else
        echo "$target_path"
    fi
}

# 2. 定位或下载 Python Standalone (arm64 Apple Silicon)
UV_BIN=""
if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
    UV_BIN="$HOME/.local/bin/uv"
fi

BASE_PYTHON_DIR=""

# 优先检查本地 uv 已经下载好的 standalone python
if [ -n "$UV_BIN" ]; then
    UV_SHARE_PYTHONS=("$HOME/.local/share/uv/python"/cpython-3.12*-macos-aarch64-none)
    for p in "${UV_SHARE_PYTHONS[@]}"; do
        if [ -d "$p" ] && [ -x "$p/bin/python3" ]; then
            BASE_PYTHON_DIR="$(resolve_real_dir "$p")"
            break
        fi
    done
fi

# 若本地尚无，通过 uv 自动下载独立 portable python
if [ -z "$BASE_PYTHON_DIR" ] && [ -n "$UV_BIN" ]; then
    echo "==> 正在通过 uv 获取官方可重定位独立 Python 3.12 (arm64)..."
    "$UV_BIN" python install 3.12 >/dev/null 2>&1 || true
    UV_SHARE_PYTHONS=("$HOME/.local/share/uv/python"/cpython-3.12*-macos-aarch64-none)
    for p in "${UV_SHARE_PYTHONS[@]}"; do
        if [ -d "$p" ] && [ -x "$p/bin/python3" ]; then
            BASE_PYTHON_DIR="$(resolve_real_dir "$p")"
            break
        fi
    done
fi

# 若依然未找到，直接通过 curl 下载 Astral python-build-standalone
if [ -z "$BASE_PYTHON_DIR" ]; then
    echo "==> 正在从 GitHub Release 下载自包含 Standalone Python (aarch64-apple-darwin)..."
    TMP_DL="$(mktemp -d)"
    STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20241016/cpython-3.12.7+20241016-aarch64-apple-darwin-install_only.tar.gz"
    curl -fSL "$STANDALONE_URL" -o "$TMP_DL/python-standalone.tar.gz"
    tar -xzf "$TMP_DL/python-standalone.tar.gz" -C "$TMP_DL"
    BASE_PYTHON_DIR="$(resolve_real_dir "$TMP_DL/python")"
fi

if [ ! -d "$BASE_PYTHON_DIR" ] || [ ! -x "$BASE_PYTHON_DIR/bin/python3" ]; then
    echo "错误: 无法获取有效的 Standalone Python 解释器" >&2
    exit 1
fi

BASE_PYTHON_DIR="$(resolve_real_dir "$BASE_PYTHON_DIR")"
echo "==> 使用基础独立解释器物理路径: $BASE_PYTHON_DIR"

# 3. 复制完整的独立 Python 树至目标目录 (必须是真实独立物理目录，绝不能是符号链接)
rm -rf "$TARGET"
mkdir -p "$(dirname "$TARGET")"
cp -R "$BASE_PYTHON_DIR" "$TARGET"

if [ -L "$TARGET" ]; then
    echo "错误: 复制失败，目标环境为符号链接 ($TARGET)" >&2
    exit 1
fi

# 确保独立运行环境目录及文件具有写权限
chmod -R u+w "$TARGET"

# 移除 EXTERNALLY-MANAGED 限制文件，允许直接安装依赖到其内部 site-packages
rm -f "$TARGET/lib/python3.12/EXTERNALLY-MANAGED"

# 4. 安装运行必须依赖
echo "==> 正在安装运行时依赖 (fastapi, uvicorn, edge-tts, mlx-audio 等)..."
if [ -n "$UV_BIN" ]; then
    "$UV_BIN" pip install --python "$TARGET/bin/python3" --disable-pip-version-check -r "$SCRIPT_DIR/runtime-requirements.txt"
else
    "$TARGET/bin/python3" -m pip install --disable-pip-version-check -r "$SCRIPT_DIR/runtime-requirements.txt"
fi

# 5. 精简体积：删除测试文件与缓存
echo "==> 正在精简内嵌运行环境体积..."
find "$TARGET" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$TARGET" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$TARGET" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
rm -rf "$TARGET/share/man" "$TARGET/share/doc" 2>/dev/null || true

# 6. 最终验证
echo "==> 正在校验内嵌独立运行环境可用性..."
"$TARGET/bin/python3" -c "import fastapi, uvicorn, edge_tts, mlx_audio; print('✔ 内嵌独立 Python 环境配置成功！全部模块加载无误。')"

echo "============================================================"
echo "  内嵌运行环境就绪: $TARGET"
echo "============================================================"

#!/usr/bin/env bash
# 复现 whisper.cpp 在 loongarch64 上的中文转写测试
set -euo pipefail

MODEL="${MODEL:-$HOME/models/ggml-small.bin}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT='以下是普通话的句子，使用简体中文。'

if [[ ! -f "$MODEL" ]]; then
  echo "模型不存在: $MODEL" >&2
  echo "下载: curl -L -o ~/models/ggml-small.bin https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" >&2
  exit 1
fi

for name in zh-long zh-short; do
  echo "== $name"
  time whisper-cli -m "$MODEL" -f "$DIR/test/$name.wav" -l zh -t 8 -np \
    --prompt "$PROMPT" -otxt -osrt -of "$DIR/test/$name-rerun"
done

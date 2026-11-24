#!/usr/bin/env bash
# ホストからではなく、compose の edge ネット内でベンチを走らせる。
# Docker Desktop の localhost ポート転送による接続リセットを避けるため。
# 使い方: リポジトリルート、またはこのスクリプトを直接実行する。
# 先に compose.override.mac.example.yaml を compose.override.yaml へコピーし、
# docker compose up 済みであること。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ ! -f compose.override.yaml ]]; then
  echo "compose.override.yaml がありません。次を実行してからやり直してください:" >&2
  echo "  cp compose.override.mac.example.yaml compose.override.yaml" >&2
  exit 1
fi

case "$(uname -m)" in
  arm64|aarch64) goarch=arm64 ;;
  x86_64|amd64) goarch=amd64 ;;
  *)
    echo "未対応のアーキテクチャです: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p bin
echo "building linux/${goarch} bench -> bin/bench-linux" >&2
GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 go -C bench build -o bin/bench-linux

# 進捗は stderr、結果 JSON は stdout。-scale は datagen と同じにすること（既定 small）。
docker compose --profile bench run --rm --no-deps bench "$@"

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

# go -C bench は bench/ をカレントにするので、出力先はリポジトリルートからの絶対パスにする。
# 相対パス bin/bench-linux だと bench/bin/bench-linux に落ち、compose がマウントする
# ルートの bin/bench-linux が存在せず、Docker がディレクトリを作って実行に失敗する。
out="$root/bin/bench-linux"
mkdir -p "$root/bin"
if [[ -d "$out" ]]; then
  echo "removing leftover directory $out (created by a previous failed docker mount)" >&2
  rmdir "$out" 2>/dev/null || rm -rf "$out"
fi

echo "building linux/${goarch} bench -> $out" >&2
GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 go -C bench build -o "$out"
if [[ ! -f "$out" || -d "$out" ]]; then
  echo "bench binary was not written to $out" >&2
  exit 1
fi

# 進捗は stderr、結果 JSON は stdout。-scale は datagen と同じにすること（既定 small）。
docker compose --profile bench run --rm --no-deps bench "$@"

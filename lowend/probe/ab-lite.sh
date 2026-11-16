#!/bin/bash
# 同一台机器、同一页面，只改一个变量，量出 lite.css 自身的收益。
# 两次测量之间彻底关掉前一个浏览器实例，避免动画互相抢帧。
set -u

DIR="/c/Users/wisdo/Documents/github/dsh-lowend/lowend/probe"
EDGE="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
NODE="/c/Users/wisdo/bin/node-v24.22.3-win-x64/node.exe"
FLAGS=(
  --ignore-gpu-blocklist
  --enable-gpu-rasterization
  --enable-zero-copy
  --disable-gpu-driver-bug-workarounds
  --use-angle=d3d11
  --enable-features=CanvasOopRasterization
  --no-first-run
  --no-default-browser-check
  --window-size=1280,760
  # 窗口被遮挡时 Chromium 会暂停 rAF，不关掉这三个就量不到帧
  --disable-backgrounding-occluded-windows
  --disable-renderer-backgrounding
  --disable-background-timer-throttling
)

cd "$DIR" || exit 1

run() {
  local label="$1" url="$2" mode="${3:-flags}"
  local out="out-$label.txt"
  # 每次用全新 profile 目录：旧目录体积大，删除会被安全策略拦下
  local profile="$DIR/p-${label}-$(date +%s)"
  rm -f "$out"
  "$NODE" server.mjs > "$out" 2>&1 &
  local spid=$!

  for _ in $(seq 1 30); do grep -q LISTEN "$out" && break; sleep 0.5; done

  if [ "$mode" = "none" ]; then
    "$EDGE" --user-data-dir="$profile" --no-first-run --no-default-browser-check \
      --window-size=1280,760 --disable-backgrounding-occluded-windows \
      --disable-renderer-backgrounding --disable-background-timer-throttling \
      --app="$url" >/dev/null 2>&1 &
  else
    "$EDGE" --user-data-dir="$profile" "${FLAGS[@]}" --app="$url" >/dev/null 2>&1 &
  fi

  for _ in $(seq 1 90); do grep -q RESULT "$out" && break; sleep 1; done

  kill "$spid" 2>/dev/null
  result=$(grep RESULT "$out" | tail -1)
  echo "[$label] ${result:-NO_RESULT}"

  powershell -NoProfile -ExecutionPolicy Bypass -File "$DIR/kill-edge.ps1" -Profile "$profile" >/dev/null 2>&1
  sleep 3
}

run "default" "http://127.0.0.1:8899/" "none"
run "flags" "http://127.0.0.1:8899/"
run "flags-lite" "http://127.0.0.1:8899/?lite=1"
echo "DONE"

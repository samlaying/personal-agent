#!/bin/zsh
# Smoke test for the packaged app: points it at a local mock model, launches it, and
# checks that it stays resident, initializes its storage, and reports its memory.
set -e
cd "$(dirname "$0")/.."

BUNDLE_ID="com.sam.personal-agent"
PORT=18731
APP=".build/app/PersonalAgent.app"

[[ -d "$APP" ]] || { echo "error: run scripts/build-app.sh first" >&2; exit 1; }

swift build -c release --product mock-llm >/dev/null
./.build/release/mock-llm --port $PORT --chunk-delay 0.01 >/tmp/pa-mock.log 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; true' EXIT
sleep 1
echo "==> mock provider: $(cat /tmp/pa-mock.log)"

# 暂改 provider 指向 mock；结束后恢复原值，不碰用户其它设置
OLD_BASE=$(defaults read $BUNDLE_ID provider.baseURL 2>/dev/null || true)
OLD_MODEL=$(defaults read $BUNDLE_ID provider.model 2>/dev/null || true)
restore_provider() {
  if [[ -n "$OLD_BASE" ]]; then defaults write $BUNDLE_ID provider.baseURL "$OLD_BASE"; else defaults delete $BUNDLE_ID provider.baseURL 2>/dev/null || true; fi
  if [[ -n "$OLD_MODEL" ]]; then defaults write $BUNDLE_ID provider.model "$OLD_MODEL"; else defaults delete $BUNDLE_ID provider.model 2>/dev/null || true; fi
}
restore_provider
defaults write $BUNDLE_ID provider.baseURL "http://127.0.0.1:$PORT/v1"
defaults write $BUNDLE_ID provider.model "mock-model"

open "$APP"
APP_PID=$(pgrep -x PersonalAgent | head -1)
for _ in {1..40}; do
    [[ -n "$APP_PID" ]] && break
    sleep 0.5
    APP_PID=$(pgrep -x PersonalAgent | head -1)
done

sleep 4
if [[ -z "$APP_PID" ]]; then
    echo "FAIL: app process not found"
    restore_provider
    exit 1
fi

RSS_KB=$(ps -o rss= -p "$APP_PID" | tr -d ' ')
THREADS=$(ps -M -p "$APP_PID" | tail -n +2 | wc -l | tr -d ' ')
DB="$HOME/Library/Application Support/PersonalAgent/memory.sqlite"
DB_OK="no"
[[ -f "$DB" ]] && DB_OK="yes ($(du -h "$DB" | cut -f1))"

sleep 3
RSS_IDLE=$(ps -o rss= -p "$APP_PID" | tr -d ' ')

echo "==> app pid: $APP_PID"
echo "==> memory after launch: $(( RSS_KB / 1024 )) MB (${RSS_KB} KB)"
echo "==> memory after idle:   $(( RSS_IDLE / 1024 )) MB (${RSS_IDLE} KB)"
echo "==> threads: $THREADS"
echo "==> storage initialized: $DB_OK"
echo "==> still running: $(ps -p "$APP_PID" > /dev/null && echo yes || echo no)"

kill "$APP_PID" 2>/dev/null || true
sleep 1
restore_provider
echo "==> done（provider 设置已恢复原值）"

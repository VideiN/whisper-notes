#!/bin/bash
# CI: 시뮬레이터에서 앱을 띄워 본다 (.github/workflows/ios.yml의 simulator 잡)
#   scripts/ci-run-simulator.sh <시뮬레이터 UDID> <.app 경로> <결과 폴더>
# 앱을 설치해 띄우고, 앱 로그(표준 출력)에 이 실행의 빌드 줄("build: #<실행 번호> ")이 나오는지 확인한다.
# 앱 로그(app.log)와 스크린숏(screen.png)은 결과 폴더에 남긴다 (아티팩트 app-simulator-run)
set -euo pipefail

udid=$1
app=$2
out=$3
mkdir -p "$out"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
expected="build: #${GITHUB_RUN_NUMBER:-0} "

time xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"

# 앱의 표준 출력(로그)을 app.log로 받는다
xcrun simctl launch --console-pty "$udid" "$bundle_id" > "$out/app.log" 2>&1 &
launch_pid=$!

for _ in $(seq 1 60); do
  grep -q "$expected" "$out/app.log" && break
  sleep 1
done
sleep 3 # 첫 화면이 그려지도록
xcrun simctl io "$udid" screenshot "$out/screen.png" > /dev/null 2>&1 || true
xcrun simctl terminate "$udid" "$bundle_id" || true
kill "$launch_pid" 2> /dev/null || true

echo "--- app"
cat "$out/app.log"
echo "---"

if grep -q "$expected" "$out/app.log"; then
  echo "ok: the app is this run's build"
else
  echo "::error::the app did not start, or it is not this run's build (no '$expected' in app log)"
  exit 1
fi

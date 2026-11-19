#!/bin/bash
# 성능 체크 (PR마다 필수, CLAUDE.md 참고).
#   tools/perf.sh            지금 브랜치(build/MacSnow.app)와 main을 같은 조건에서 번갈아 재서 비교해요
#   tools/perf.sh --only     지금 브랜치만 재요
# 환경변수: SECS(상황당 측정 초, 기본 20) WARM(실행·전환 뒤 예열 초, 기본 15) ROUNDS(번갈아 잴 횟수, 기본 2) BASE(비교 기준, 기본 main)
# 앱을 여러 번 껐다 켜고 미션 컨트롤을 열어요(약 7~10분): 사용자가 맥을 안 쓸 때만, 허락받고 돌려요. 측정 중에는 맥을 건드리지 마세요. 눈 켜기 설정은 끝나면 원래대로 돌려놔요.
set -euo pipefail
cd "$(dirname "$0")/.."
SECS="${SECS:-20}"; WARM="${WARM:-15}"; ROUNDS="${ROUNDS:-2}"; BASE="${BASE:-main}"
ONLY=0; [ "${1:-}" = "--only" ] && ONLY=1
MC="/System/Applications/Mission Control.app"
TMP="$(mktemp -d)"; trap 'restore; [ -d "$TMP/base" ] && git worktree remove --force "$TMP/base" >/dev/null 2>&1; rm -rf "$TMP"' EXIT
was_on="$(defaults read com.coldtbrew.macsnow snowOn 2>/dev/null || echo 1)"
restore() { defaults write com.coldtbrew.macsnow snowOn -bool "$([ "$was_on" = 0 ] && echo false || echo true)"; }

RUNNING="$(ps -o comm= -p "$(pgrep -x MacSnow | head -1)" 2>/dev/null | sed 's|/Contents/MacOS/MacSnow$||' || true)"
./build.sh >/dev/null 2>&1 || { echo "빌드 실패" >&2; exit 1; }
cp -R build/MacSnow.app "$TMP/PR.app"
if [ $ONLY = 0 ]; then
  git worktree add -q "$TMP/base" "$BASE"
  (cd "$TMP/base" && ./build.sh >/dev/null 2>&1) || { echo "${BASE} 빌드 실패" >&2; exit 1; }
  cp -R "$TMP/base/build/MacSnow.app" "$TMP/BASE.app"
fi

# top 샘플 평균 (첫 샘플은 0이라 버림) → CPU 숫자 하나
cpu() { top -l $((SECS + 1)) -s 1 -pid "$(pgrep -x MacSnow)" -stats cpu | awk '$1 ~ /^[0-9.]+$/ { n++; if (n > 1) c += $1 } END { printf "%.2f", (n > 1 ? c / (n - 1) : 0) }'; }
mem() { top -l 1 -pid "$(pgrep -x MacSnow)" -stats mem | tail -1 | tr -d '+-'; }
# run the binary directly: `open` would register the temp copies with LaunchServices
launch() { pkill -x MacSnow 2>/dev/null || true; sleep 1; nohup "$TMP/$1.app/Contents/MacOS/MacSnow" >/dev/null 2>&1 & sleep "$WARM"; }
# one pass: prints "idle mc off mem"
pass() {
  defaults write com.coldtbrew.macsnow snowOn -bool true; launch "$1"
  local a b c m; a=$(cpu); m=$(mem)
  open "$MC"; sleep 1; b=$(cpu); open "$MC"
  defaults write com.coldtbrew.macsnow snowOn -bool false; sleep "$WARM"; c=$(cpu)
  echo "$a $b $c $m"
}
declare -a R_PR=() R_BASE=()
for r in $(seq "$ROUNDS"); do
  echo "round $r/$ROUNDS: PR…" >&2; R_PR+=("$(pass PR)")
  [ $ONLY = 0 ] && { echo "round $r/$ROUNDS: ${BASE}…" >&2; R_BASE+=("$(pass BASE)"); }
done
avg() { printf '%s\n' "$@" | awk -v k="$K" '{ s += $k; n++ } END { printf "%.1f%%", s / n }'; }
memof() { printf '%s\n' "$@" | tail -1 | awk '{ print $4 }'; }
restore
pkill -x MacSnow 2>/dev/null || true; sleep 1
# put back what was running before (or the installed app)
if [ -n "$RUNNING" ] && [ -d "$RUNNING" ] && [[ "$RUNNING" != "$TMP"* ]]; then open "$RUNNING"
elif [ -d /Applications/MacSnow.app ]; then open /Applications/MacSnow.app; fi

echo
echo "### Performance"
echo
echo "$(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Connected:/ {print ($2=="Yes"?"전원 연결":"배터리"); exit}'), 상황당 ${SECS}s × ${ROUNDS}회 평균 (예열 ${WARM}s)"
echo
if [ $ONLY = 0 ]; then
  echo "| 상황 | $BASE | 이 PR |"; echo "|---|---|---|"
  for k in 1 2 3; do K=$k; name=("" "눈 내리는 중, 가만히" "미션 컨트롤 열림" "눈 끔, 쌓인 눈만"); echo "| ${name[$k]} | $(avg "${R_BASE[@]}") | $(avg "${R_PR[@]}") |"; done
  echo "| 메모리 | $(memof "${R_BASE[@]}") | $(memof "${R_PR[@]}") |"
else
  echo "| 상황 | CPU |"; echo "|---|---|"
  for k in 1 2 3; do K=$k; name=("" "눈 내리는 중, 가만히" "미션 컨트롤 열림" "눈 끔, 쌓인 눈만"); echo "| ${name[$k]} | $(avg "${R_PR[@]}") |"; done
  echo "| 메모리 | $(memof "${R_PR[@]}") |"
fi
echo
echo "드래그를 건드린 PR은 README '드래그 지연 측정'(tools/testwin.swift, tools/lagstats.py) 결과도 붙여요."

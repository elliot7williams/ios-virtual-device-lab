#!/bin/zsh
set -euo pipefail
app="${1:?Pass the packaged app path}"
fixture_tmp="$(mktemp -d -t vdl-fixture-smoke)"
fixture_pid=''
function cleanup {
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  if [[ "$fixture_tmp" == */vdl-fixture-smoke.* ]]; then rm -rf "$fixture_tmp"; fi
}
trap cleanup EXIT
"$app/Contents/MacOS/vdlctl" fixture template --output "$fixture_tmp/scenario.json"
"$app/Contents/MacOS/vdl-fixture" --scenario "$fixture_tmp/scenario.json" > "$fixture_tmp/server.log" 2>&1 &
fixture_pid=$!
for attempt in {1..30}; do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8787/health > "$fixture_tmp/health.json"; then break; fi
  sleep 0.2
done
kill -0 "$fixture_pid"
health="$(cat "$fixture_tmp/health.json")"
[[ "$health" == '{"ok":true}' ]]
answer="$(dig @127.0.0.1 -p 53535 radio.test A +short +time=2 +tries=1)"
[[ "$answer" == '127.0.0.1' ]]
"$app/Contents/MacOS/vdlctl" fixture record --url http://127.0.0.1:8787/health --path /replay --output "$fixture_tmp/recorded.json"
test -s "$fixture_tmp/recorded.json"
print 'Network fixture smoke PASS — loopback HTTP, DNS, and response recording'

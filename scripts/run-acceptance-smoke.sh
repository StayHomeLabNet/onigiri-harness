#!/bin/zsh
set -euo pipefail

base_url="${ONIGIRI_BASE_URL:-http://127.0.0.1:18080}"
failures=0

check() {
  local label="$1"
  local endpoint_path="$2"
  local output
  if output="$(curl --silent --show-error --fail --max-time 10 "$base_url$endpoint_path")"; then
    if print -r -- "$output" | /usr/bin/python3 -m json.tool >/dev/null 2>&1; then
      print "[PASS] $label"
    else
      print "[FAIL] $label: response is not JSON"
      failures=$((failures + 1))
    fi
  else
    print "[FAIL] $label: request failed"
    failures=$((failures + 1))
  fi
}

check "health" "/health"
check "providers" "/providers"
check "models" "/models"
check "OpenAI models" "/v1/models"
check "AI task providers" "/agents/status"
check "knowledge status" "/knowledge"
check "decision providers" "/decision/providers"

if (( failures > 0 )); then
  print "Smoke test failed: $failures check(s) failed."
  exit 1
fi

print "Smoke test passed."

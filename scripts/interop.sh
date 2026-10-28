#!/bin/sh
# rayobs with a real app: raystat runs under `rayobs ship` (its log lines go to rayobs), rayobs
# scrapes its /metrics every second, and `raystat blast` sends it a known rate of statsd lines.
# The counter rayobs stores must grow by exactly what was sent; a trace posted by hand comes back as a tree; stopping
# ship stops raystat too, and `up` turns 0.
# Usage: scripts/interop.sh [RAYSTAT_BINARY]   (needs ./rayobs: make build; default ../raystat/raystat)
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HERE/rayobs"
RAYSTAT="${1:-$HERE/../raystat/raystat}"
[ -x "$RAYSTAT" ] || { echo "interop: no raystat binary at $RAYSTAT" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rayobs-interop.XXXXXX")"
OP=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 5000))
UP=$((45000 + $(od -An -N2 -tu2 /dev/urandom) % 5000))
HP=$((50000 + $(od -An -N2 -tu2 /dev/urandom) % 5000))
API="http://127.0.0.1:$OP"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
wait_http() { i=0; until curl -s -o /dev/null "$1"; do i=$((i + 1)); [ $i -gt 50 ] && return 1; sleep 0.2; done; }

cat >"$WORK/rayobs.toml" <<EOF
[server]
listen = "127.0.0.1:$OP"
data = "$WORK/data"

[[scrape]]
job = "raystat"
url = "http://127.0.0.1:$HP/metrics"
interval = "1s"
EOF
"$BIN" serve --config "$WORK/rayobs.toml" >"$WORK/rayobs.log" 2>&1 &
PIDS="$PIDS $!"
wait_http "$API/v1/stats" || { cat "$WORK/rayobs.log"; exit 1; }
"$BIN" ship --api "$API" --service raystat -- "$RAYSTAT" serve --udp "127.0.0.1:$UP" --http "127.0.0.1:$HP" --flush 1s >"$WORK/raystat.out" 2>&1 &
SHIP=$!
PIDS="$PIDS $SHIP"
wait_http "http://127.0.0.1:$HP/metrics" || { cat "$WORK/raystat.out"; exit 1; }

pass=0
expect() { # expect NAME CONDITION-COMMAND...
    name=$1; shift
    if "$@" >"$WORK/out" 2>&1; then pass=$((pass + 1)); printf "  ok    %s\n" "$name"
    else printf "  FAIL  %s\n" "$name"; sed 's/^/        /' "$WORK/out"; exit 1; fi
}
value() { # value QUERY: the last point of the first series
    curl -s "$API/v1/query?$1" | python3 -c 'import json,sys; s=json.load(sys.stdin)["series"]; print(s[0]["points"][-1][1] if s and s[0]["points"] else "none")'
}
peak() { # peak QUERY: the highest point of the first series
    curl -s "$API/v1/query?$1" | python3 -c 'import json,sys; s=json.load(sys.stdin)["series"]; print(max(p[1] for p in s[0]["points"]) if s and s[0]["points"] else "none")'
}
is() { # is VALUE OP NUMBER
    python3 -c "import sys; v='$1'; sys.exit(0 if v != 'none' and float(v) $2 $3 else 1)"
}

echo "rayobs interop: raystat (udp $UP, metrics $HP) shipped and scraped by rayobs on $API"
# 2 senders × 200 datagrams/s × 10 lines = 4000 lines/s, for 8 s.
"$RAYSTAT" blast "127.0.0.1:$UP" -n 32000 -s 2 -b 10 --rate 200 >"$WORK/blast.out"
sleep 2.5
# The counter before and after: it must have grown by exactly what was sent (UDP on loopback at
# this rate loses nothing). A rate over short steps aliases with raystat's 1 s flush, so the
# check is on the increase, and the rate is the increase over the blast's 8 s.
GREW=$(curl -s "$API/v1/query?m=raystat_lines_total&fn=last&step=1s&since=15s&sum=1" | python3 -c 'import json,sys; p=json.load(sys.stdin)["series"][0]["points"]; print(p[-1][1]-p[0][1])')
echo "        raystat_lines_total grew by $GREW while 32000 lines were sent: $(python3 -c "print(round($GREW/8))") lines/s over the blast"
expect "the scraped counter grew by what was sent" is "$GREW" "==" 32000
expect "up{job=\"raystat\"} is 1 while raystat runs" is "$(value 'm=up%7Bjob%3D%22raystat%22%7D&fn=last&step=10s&since=10s')" "==" 1
expect "scrape_samples counts raystat's series" is "$(value 'm=scrape_samples&fn=last&step=10s&since=10s')" ">" 5
expect "raystat's startup line arrived as a log" sh -c "'$BIN' logs --api '$API' --service raystat | grep -q 'statsd on udp'"
expect "ship passed the output through" grep -q 'statsd on udp' "$WORK/raystat.out"

T=0123456789abcdef0123456789abcdef
NOW=$(python3 -c 'import time; print(int(time.time()*1000))')
curl -sf -o /dev/null -X POST "$API/v1/spans" -d "[{\"trace_id\":\"$T\",\"span_id\":\"1000000000000001\",\"service\":\"front\",\"name\":\"GET /\",\"start_ms\":$NOW,\"duration_ms\":40},{\"trace_id\":\"$T\",\"span_id\":\"1000000000000002\",\"parent_id\":\"1000000000000001\",\"service\":\"api\",\"name\":\"query\",\"start_ms\":$((NOW + 5)),\"duration_ms\":20,\"status\":\"error\"}]"
curl -sf -o /dev/null -X POST "$API/v1/logs?service=api" -d "{\"level\":\"ERROR\",\"trace_id\":\"$T\",\"msg\":\"query timed out\"}"
"$BIN" trace "$T" --api "$API" >"$WORK/trace.out"
sed 's/^/        /' "$WORK/trace.out"
expect "the trace prints as a waterfall with its log" sh -c "grep -q '  api query' '$WORK/trace.out' && grep -q 'query timed out' '$WORK/trace.out'"

kill "$SHIP"; wait "$SHIP" 2>/dev/null || true
expect "stopping ship stopped raystat" sh -c "! curl -s -m 2 -o /dev/null 'http://127.0.0.1:$HP/metrics'"
sleep 2.5
expect "up turns 0" is "$(value 'm=up&fn=last&step=2s&since=2s')" "==" 0
echo "$pass checks passed"

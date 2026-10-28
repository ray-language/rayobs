#!/bin/sh
# rayobs ingestion: a fresh server on a random high port, then `rayobs blast` with more clients
# and bigger requests; every request is answered after its lines are synced.
# Usage: scripts/bench.sh   (needs ./rayobs: make build; COMMIT_MS=50 to try a fixed window)
set -eu
BIN="$(cd "$(dirname "$0")/.." && pwd)/rayobs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rayobs-bench.XXXXXX")"
P=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
printf '[server]\nlisten = "127.0.0.1:%s"\ndata = "%s/data"\ncommit_ms = %s\n' "$P" "$WORK" "${COMMIT_MS:-0}" >"$WORK/rayobs.toml"
"$BIN" serve --config "$WORK/rayobs.toml" >"$WORK/serve.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT
i=0; until curl -s -o /dev/null "http://127.0.0.1:$P/v1/stats"; do i=$((i + 1)); [ $i -gt 50 ] && exit 1; sleep 0.1; done
for run in "1 100 50000" "1 500 100000" "8 500 400000" "32 500 800000" "32 5000 1600000"; do
    set -- $run
    "$BIN" blast --api "http://127.0.0.1:$P" -c "$1" -b "$2" -n "$3"
done
curl -s "http://127.0.0.1:$P/v1/stats" | python3 -c 'import json,sys; s=json.load(sys.stdin)["logs"]; print("%d records in %d syncs (%d per sync), %d MB written" % (s["records"], s["syncs"], s["records"]//max(s["syncs"],1), s["bytes_written"]//1000000))'
echo "server RSS $(( $(ps -o rss= -p "$SRV") / 1024 )) MiB"

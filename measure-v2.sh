#!/usr/bin/env bash
# measure-v2.sh {system} {module_count}
#
# V2 benchmark: sustained throughput under concurrency with a 1 GB FPM budget.
#
# Steps:
#   1. Configure production env (APP_ENV=production, APP_DEBUG=false)
#   2. Run artisan optimize (+ modules:cache for internachi)
#   3. Probe actual FPM worker RSS to derive pm.max_children for 1 GB budget
#   4. Reconfigure FPM with pm=static, pm.max_children=N; restart
#   5. Warm up, then run wrk for 60 s
#   6. Write JSON + CSV
#
# Prerequisites: wrk installed on host (brew install wrk)

set -euo pipefail

SYSTEM="${1:-}"
MODULE_COUNT="${2:-}"
if [ -z "$SYSTEM" ] || [ -z "$MODULE_COUNT" ]; then
  echo "Usage: $0 <internachi|nwidart> <module_count>" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_FILE="$SCRIPT_DIR/v2/docker-compose.override.yml"
OUTPUT_DIR="$SCRIPT_DIR/v2/$SYSTEM"
HOST="https://localhost"
MEMORY_BUDGET_MB=1024
WRK_THREADS=4
WRK_DURATION=60

case "$SYSTEM" in
  internachi) APP_DIR="$SCRIPT_DIR/internachi/application" ;;
  nwidart)    APP_DIR="$SCRIPT_DIR/nwidart/application" ;;
  *) echo "ERROR: system must be 'internachi' or 'nwidart'" >&2; exit 1 ;;
esac

compose() {
  docker compose \
    -f "$APP_DIR/docker-compose.yml" \
    -f "$OVERRIDE_FILE" \
    "$@"
}

update_env() {
  local key="$1" val="$2" file="$APP_DIR/.env"
  if grep -q "^$key=" "$file" 2>/dev/null; then
    sed -i '' "s|^$key=.*|$key=$val|" "$file"
  else
    echo "$key=$val" >> "$file"
  fi
}

echo "==> [$SYSTEM] v2 measure: $MODULE_COUNT modules"

# --- 1. Production environment ---
echo "  Configuring production environment..."
cp "$APP_DIR/docker/php.ini.opcache-on" "$APP_DIR/docker/php.ini"
update_env "APP_ENV" "production"
update_env "APP_DEBUG" "false"
update_env "BENCHMARK_MODULE_COUNT" "$MODULE_COUNT"
update_env "BENCHMARK_CONDITION" "production"

# --- 2. Restart with initial generous FPM config to probe RSS ---
# Write a generous dynamic config so workers actually spin up during warm-up
echo "  Restarting container for production config..."
WWW_CONF_PATH=$(compose exec -T app sh -c \
  "find /etc /usr/local/etc -name 'www.conf' 2>/dev/null | head -1" || true)
if [ -z "$WWW_CONF_PATH" ]; then
  echo "ERROR: could not locate www.conf inside container." >&2
  echo "  Searched /etc and /usr/local/etc. Check your Docker image." >&2
  exit 1
fi
echo "  Detected FPM config: $WWW_CONF_PATH"

printf '[www]\nuser = nobody\ngroup = nobody\nlisten = 127.0.0.1:9000\npm = dynamic\npm.max_children = 64\npm.start_servers = 8\npm.min_spare_servers = 4\npm.max_spare_servers = 16\n' \
  | compose exec -T app sh -c "cat > '$WWW_CONF_PATH'"

compose restart app
sleep 5

# --- 3. artisan optimize (+ modules:cache for internachi) ---
echo "  Running artisan optimize..."
compose exec -T app php artisan optimize --no-interaction

if [ "$SYSTEM" = "internachi" ]; then
  echo "  Caching modules..."
  compose exec -T app php artisan modules:cache --no-interaction
fi

# --- 4. Warm up to populate FPM workers ---
echo "  Warming up (30 requests to populate workers)..."
for i in $(seq 1 30); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
done
sleep 2

# --- 5. Probe actual RSS of php-fpm worker processes ---
echo "  Probing actual FPM worker RSS..."
RSS_KB=$(compose exec -T app sh -c \
  "ps -eo rss,comm --no-headers 2>/dev/null | grep php-fpm | grep -v 'master\|grep' | awk '{sum+=\$1; n++} END {if(n>0) print int(sum/n); else print 0}'" \
  || echo "0")

if [ "$RSS_KB" -eq 0 ]; then
  echo "  WARNING: could not measure FPM worker RSS; falling back to ps aux approach..." >&2
  RSS_KB=$(compose exec -T app sh -c \
    "ps aux 2>/dev/null | grep 'php-fpm: pool' | grep -v grep | awk '{sum+=\$6; n++} END {if(n>0) print int(sum/n); else print 0}'" \
    || echo "0")
fi

if [ "$RSS_KB" -eq 0 ]; then
  echo "ERROR: FPM workers not running or RSS measurement failed." >&2
  echo "  Run: docker compose exec app ps aux | grep fpm" >&2
  exit 1
fi

RSS_MB=$(python3 -c "import math; print(round($RSS_KB / 1024, 1))")
WORKERS=$(python3 -c "import math; print(max(1, math.floor($MEMORY_BUDGET_MB / ($RSS_KB / 1024))))")
echo "  Worker RSS: ${RSS_MB} MB → pm.max_children = $WORKERS (budget: ${MEMORY_BUDGET_MB} MB)"

# --- 6. Reconfigure FPM with pm=static and computed worker count ---
echo "  Applying pm=static with $WORKERS workers..."
printf '[www]\nuser = nobody\ngroup = nobody\nlisten = 127.0.0.1:9000\npm = static\npm.max_children = %s\n' "$WORKERS" \
  | compose exec -T app sh -c "cat > '$WWW_CONF_PATH'"

compose restart app
sleep 5

# Re-run optimize after restart (caches are written to storage)
compose exec -T app php artisan optimize --no-interaction
if [ "$SYSTEM" = "internachi" ]; then
  compose exec -T app php artisan modules:cache --no-interaction
fi

# --- 7. Final warm-up ---
echo "  Final warm-up (20 requests)..."
for i in $(seq 1 20); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
done
sleep 1

# --- 8. Run wrk ---
echo "  Running wrk: -t${WRK_THREADS} -c${WORKERS} -d${WRK_DURATION}s ..."
WRK_TMP=$(mktemp)
wrk -t"$WRK_THREADS" -c"$WORKERS" -d"${WRK_DURATION}s" --latency -k "$HOST/benchmark/bare" 2>&1 | tee "$WRK_TMP"

# --- 9. Parse wrk output ---
METRICS=$(python3 - "$WRK_TMP" << 'PYEOF'
import sys, re, json

def parse_dur(s):
    s = s.strip()
    if s.endswith('ms'): return float(s[:-2])
    if s.endswith('us'): return float(s[:-2]) / 1000
    if s.endswith('s'):  return float(s[:-1]) * 1000
    return float(s)

out = open(sys.argv[1]).read()
req_sec = lat_avg_ms = lat_p99_ms = 0.0
errors = 0

for line in out.splitlines():
    line = line.strip()
    m = re.match(r'Requests/sec:\s+([\d.]+)', line)
    if m: req_sec = float(m.group(1))

    m = re.match(r'Latency\s+([\d.]+\w+)\s+', line)
    if m: lat_avg_ms = parse_dur(m.group(1))

    m = re.match(r'99%\s+([\d.]+\w+)', line)
    if m: lat_p99_ms = parse_dur(m.group(1))

    m = re.search(r'Non-2xx or 3xx responses:\s+(\d+)', line)
    if m: errors += int(m.group(1))

    m = re.search(r'Socket errors[^:]*:\s+(.+)', line)
    if m:
        for part in m.group(1).split(','):
            n = re.search(r'(\d+)', part)
            if n: errors += int(n.group(1))

print(json.dumps({
    'req_per_sec': round(req_sec, 2),
    'latency_avg_ms': round(lat_avg_ms, 3),
    'latency_p99_ms': round(lat_p99_ms, 3),
    'errors': errors,
}))
PYEOF
)
rm -f "$WRK_TMP"

# --- 10. Write JSON output ---
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/run_${MODULE_COUNT}.json"

V2_SYSTEM="$SYSTEM" \
V2_MODULE_COUNT="$MODULE_COUNT" \
V2_RSS_MB="$RSS_MB" \
V2_WORKERS="$WORKERS" \
V2_MEMORY_BUDGET="$MEMORY_BUDGET_MB" \
V2_THREADS="$WRK_THREADS" \
V2_DURATION="$WRK_DURATION" \
V2_METRICS="$METRICS" \
python3 - << 'PYEOF' > "$OUTPUT_FILE"
import os, json, datetime
m = json.loads(os.environ['V2_METRICS'])
result = {
    'system':           os.environ['V2_SYSTEM'],
    'module_count':     int(os.environ['V2_MODULE_COUNT']),
    'condition':        'production',
    'worker_rss_mb':    float(os.environ['V2_RSS_MB']),
    'pm_workers':       int(os.environ['V2_WORKERS']),
    'memory_budget_mb': int(os.environ['V2_MEMORY_BUDGET']),
    'wrk_threads':      int(os.environ['V2_THREADS']),
    'wrk_duration_s':   int(os.environ['V2_DURATION']),
    'timestamp':        datetime.datetime.utcnow().isoformat() + 'Z',
    **m,
}
print(json.dumps(result, indent=2))
PYEOF
echo "  Saved: $OUTPUT_FILE"

# --- 11. Append to summary CSV ---
CSV_FILE="$OUTPUT_DIR/summary.csv"
if [ ! -f "$CSV_FILE" ]; then
  echo "system,module_count,worker_rss_mb,pm_workers,req_per_sec,latency_avg_ms,latency_p99_ms,errors" > "$CSV_FILE"
fi

V2_SYSTEM="$SYSTEM" \
V2_MODULE_COUNT="$MODULE_COUNT" \
V2_RSS_MB="$RSS_MB" \
V2_WORKERS="$WORKERS" \
V2_METRICS="$METRICS" \
python3 - << 'PYEOF' >> "$CSV_FILE"
import os, json
d = json.loads(os.environ['V2_METRICS'])
print('{},{},{},{},{},{},{},{}'.format(
    os.environ['V2_SYSTEM'],
    os.environ['V2_MODULE_COUNT'],
    os.environ['V2_RSS_MB'],
    os.environ['V2_WORKERS'],
    d['req_per_sec'], d['latency_avg_ms'], d['latency_p99_ms'], d['errors'],
))
PYEOF

REQ_SEC=$(V2_METRICS="$METRICS" python3 -c "import os,json; print(json.loads(os.environ['V2_METRICS'])['req_per_sec'])")
echo "==> [$SYSTEM] v2 done: $MODULE_COUNT modules | $WORKERS workers | ${REQ_SEC} req/s"

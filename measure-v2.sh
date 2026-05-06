#!/usr/bin/env bash
# measure-v2.sh {system} {module_count}
#
# V2 benchmark: sustained throughput under fixed concurrency with a 1 GB FPM budget.
#
# With OPcache enabled, PHP-FPM workers share compiled bytecode via mmap-shared memory.
# Private RSS per worker is <1 MB so both systems can run hundreds of workers in 1 GB.
# The meaningful comparison is: at FIXED concurrency (WORKERS), which system serves
# more req/sec and which uses more total container memory?
#
# Design:
#   - pm=static, pm.max_children=WORKERS (fixed across both systems)
#   - SESSION_DRIVER=file, CACHE_STORE=file (eliminates MySQL hot-path contention)
#   - artisan optimize + modules:cache (internachi) applied
#   - wrk: -t4 -c{WORKERS} -d120s --timeout 10s
#   - Output: req/sec, latency avg/p99, errors, total container memory at WORKERS workers
#
# Prerequisites: wrk installed (brew install wrk)

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
WORKERS=16          # fixed pool size — both systems run the same concurrency
WRK_THREADS=4
WRK_DURATION=120

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
    [[ -n "$(tail -c1 "$file")" ]] && echo >> "$file"
    echo "$key=$val" >> "$file"
  fi
}

echo "==> [$SYSTEM] v2 measure: $MODULE_COUNT modules ($WORKERS workers)"

# --- 1. Configure production-like environment ---
# APP_ENV stays as-is (changing it to "production" triggers auth middleware redirects
# on the benchmark routes). OPcache + artisan optimize give the production optimizations.
echo "  Configuring production-optimized environment..."
cp "$APP_DIR/docker/php.ini.opcache-on" "$APP_DIR/docker/php.ini"
update_env "BENCHMARK_MODULE_COUNT" "$MODULE_COUNT"
update_env "BENCHMARK_CONDITION" "production"
update_env "SESSION_DRIVER" "file"
update_env "CACHE_STORE" "file"

# --- 2. Recreate app container to pick up updated .env env vars ---
# compose restart does NOT re-read .env; force-recreate does.
echo "  Recreating app container to apply .env changes..."
compose up -d --force-recreate app
sleep 8

# --- 3. Write www.conf AFTER recreate (recreate resets container filesystem) ---
echo "  Configuring FPM: pm=static, pm.max_children=$WORKERS..."
WWW_CONF_PATH=$(compose exec -T app sh -c \
  "find /etc /usr/local/etc -name 'www.conf' 2>/dev/null | head -1" || true)
if [ -z "$WWW_CONF_PATH" ]; then
  echo "ERROR: could not locate www.conf inside container." >&2; exit 1
fi
echo "  FPM config: $WWW_CONF_PATH"

printf '[www]\nuser = nobody\ngroup = nobody\nlisten = 9000\npm = static\npm.max_children = %s\nclear_env = no\ncatch_workers_output = yes\n' "$WORKERS" \
  | compose exec -T app sh -c "cat > '$WWW_CONF_PATH'"

# --- 4. Restart (not recreate) to apply the new www.conf ---
echo "  Restarting app to apply FPM config..."
compose restart app
sleep 5

# --- 5. artisan optimize (+ modules:cache for internachi) ---
echo "  Running artisan optimize..."
compose exec -T app php artisan optimize --no-interaction 2>&1 | grep -E "DONE|FAIL|INFO" || true

if [ "$SYSTEM" = "internachi" ]; then
  echo "  Caching modules..."
  compose exec -T app php artisan modules:cache --no-interaction
fi

# --- 6. Warm up (50 requests to populate OPcache and settle workers) ---
echo "  Warming up (50 requests)..."
for i in $(seq 1 50); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
done
sleep 5

# --- 7. Measure total container memory at WORKERS workers ---
echo "  Measuring container memory ($WORKERS workers, OPcache warm)..."
CONTAINER_ID=$(compose ps -q app 2>/dev/null | tr -d '\r' | head -1)
MEM_RAW=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_ID" 2>/dev/null || echo "")
echo "  Container memory: $MEM_RAW"

TOTAL_MB=$(python3 -c "
import re
s = '$MEM_RAW'.split('/')[0].strip()
m = re.match(r'([\d.]+)\s*(\w+)', s)
if not m: print(0); exit()
val, unit = float(m.group(1)), m.group(2).lower()
if 'gi' in unit: val *= 1024
elif 'ki' in unit: val /= 1024
print(round(val, 1))
" 2>/dev/null || echo "0")

PER_WORKER_MB=$(python3 -c "print(round($TOTAL_MB / $WORKERS, 1))" 2>/dev/null || echo "0")
THEORETICAL_MAX_WORKERS=$(python3 -c "
import math
pw = $TOTAL_MB / $WORKERS
print(math.floor($MEMORY_BUDGET_MB / pw) if pw > 0 else 0)
" 2>/dev/null || echo "0")
echo "  Total: ${TOTAL_MB} MB | Per worker: ${PER_WORKER_MB} MB | Theoretical max at ${MEMORY_BUDGET_MB} MB: $THEORETICAL_MAX_WORKERS workers"

# --- 8. Smoke-test + final warm-up ---
SMOKE=$(curl -k -s -o /dev/null -w "%{http_code}" "$HOST/benchmark/bare" || echo "000")
if [ "$SMOKE" != "200" ]; then
  echo "ERROR: /benchmark/bare returned HTTP $SMOKE (expected 200). Aborting." >&2
  echo "  Check APP_ENV, auth middleware, and nginx config." >&2
  exit 1
fi
echo "  Smoke test OK (HTTP 200). Final warm-up (20 requests)..."
for i in $(seq 1 20); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
done
sleep 1

# --- 9. Run wrk ---
echo "  Running wrk: -t${WRK_THREADS} -c${WORKERS} -d${WRK_DURATION}s ..."
WRK_TMP=$(mktemp)
wrk -t"$WRK_THREADS" -c"$WORKERS" -d"${WRK_DURATION}s" --timeout 10s --latency "$HOST/benchmark/bare" 2>&1 | tee "$WRK_TMP"

# --- 10. Parse wrk output ---
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

# --- 11. Write JSON output ---
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/run_${MODULE_COUNT}.json"

V2_SYSTEM="$SYSTEM" \
V2_MODULE_COUNT="$MODULE_COUNT" \
V2_WORKERS="$WORKERS" \
V2_TOTAL_MB="$TOTAL_MB" \
V2_PER_WORKER_MB="$PER_WORKER_MB" \
V2_THEORETICAL_MAX="$THEORETICAL_MAX_WORKERS" \
V2_MEMORY_BUDGET="$MEMORY_BUDGET_MB" \
V2_THREADS="$WRK_THREADS" \
V2_DURATION="$WRK_DURATION" \
V2_METRICS="$METRICS" \
python3 - << 'PYEOF' > "$OUTPUT_FILE"
import os, json, datetime
m = json.loads(os.environ['V2_METRICS'])
result = {
    'system':                   os.environ['V2_SYSTEM'],
    'module_count':             int(os.environ['V2_MODULE_COUNT']),
    'condition':                'production',
    'pm_workers':               int(os.environ['V2_WORKERS']),
    'container_memory_mb':      float(os.environ['V2_TOTAL_MB']),
    'per_worker_mb':            float(os.environ['V2_PER_WORKER_MB']),
    'theoretical_max_workers':  int(os.environ['V2_THEORETICAL_MAX']),
    'memory_budget_mb':         int(os.environ['V2_MEMORY_BUDGET']),
    'wrk_threads':              int(os.environ['V2_THREADS']),
    'wrk_duration_s':           int(os.environ['V2_DURATION']),
    'timestamp':                datetime.datetime.now(datetime.timezone.utc).isoformat(),
    **m,
}
print(json.dumps(result, indent=2))
PYEOF
echo "  Saved: $OUTPUT_FILE"

# --- 12. Append to summary CSV ---
CSV_FILE="$OUTPUT_DIR/summary.csv"
if [ ! -f "$CSV_FILE" ]; then
  echo "system,module_count,pm_workers,container_memory_mb,per_worker_mb,theoretical_max_workers,req_per_sec,latency_avg_ms,latency_p99_ms,errors" > "$CSV_FILE"
fi

V2_SYSTEM="$SYSTEM" \
V2_MODULE_COUNT="$MODULE_COUNT" \
V2_WORKERS="$WORKERS" \
V2_TOTAL_MB="$TOTAL_MB" \
V2_PER_WORKER_MB="$PER_WORKER_MB" \
V2_THEORETICAL_MAX="$THEORETICAL_MAX_WORKERS" \
V2_METRICS="$METRICS" \
python3 - << 'PYEOF' >> "$CSV_FILE"
import os, json
d = json.loads(os.environ['V2_METRICS'])
print('{},{},{},{},{},{},{},{},{},{}'.format(
    os.environ['V2_SYSTEM'],
    os.environ['V2_MODULE_COUNT'],
    os.environ['V2_WORKERS'],
    os.environ['V2_TOTAL_MB'],
    os.environ['V2_PER_WORKER_MB'],
    os.environ['V2_THEORETICAL_MAX'],
    d['req_per_sec'], d['latency_avg_ms'], d['latency_p99_ms'], d['errors'],
))
PYEOF

REQ_SEC=$(V2_METRICS="$METRICS" python3 -c "import os,json; print(json.loads(os.environ['V2_METRICS'])['req_per_sec'])")
echo "==> [$SYSTEM] v2 done: $MODULE_COUNT modules | ${TOTAL_MB} MB container | ${REQ_SEC} req/s"

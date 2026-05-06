#!/usr/bin/env bash
# measure-v3.sh <system> <module_count> <workers_spec> <label> [app_dir]
#
# V3 benchmark: Redis sessions + cache, both endpoints, 3-run median.
#
# workers_spec:
#   integer  — use exactly that many FPM workers (e.g. "32")
#   max:NNN  — probe with 16 workers, calculate floor(NNN / per_worker_mb), use result (e.g. "max:1024")
#
# label:   used in the output filename (e.g. "e1_max1g", "e2_w32")
# app_dir: optional override (default: v3/{system}/app)
#
# Sequence: update_env → force-recreate (picks up .env) → write www.conf → restart →
#           artisan optimize → warm up → smoke test → 3 × wrk per endpoint → median → JSON

set -euo pipefail

SYSTEM="${1:-}"
MODULE_COUNT="${2:-}"
WORKERS_SPEC="${3:-}"
LABEL="${4:-}"
APP_DIR_OVERRIDE="${5:-}"

if [ -z "$SYSTEM" ] || [ -z "$MODULE_COUNT" ] || [ -z "$WORKERS_SPEC" ] || [ -z "$LABEL" ]; then
  echo "Usage: $0 <internachi|nwidart> <module_count> <workers_spec> <label> [app_dir]" >&2
  echo "  workers_spec: integer or max:BUDGET_MB" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_FILE="$SCRIPT_DIR/v3/docker-compose.override.yml"
OUTPUT_DIR="$SCRIPT_DIR/v3/$SYSTEM"
HOST="https://localhost"
WRK_THREADS=8
WRK_CONNECTIONS=100
WRK_DURATION=60
WRK_RUNS=3
PROBE_WORKERS=16

if [ -n "$APP_DIR_OVERRIDE" ]; then
  APP_DIR="$APP_DIR_OVERRIDE"
else
  case "$SYSTEM" in
    internachi) APP_DIR="$SCRIPT_DIR/v3/internachi/app" ;;
    nwidart)    APP_DIR="$SCRIPT_DIR/v3/nwidart/app" ;;
    *) echo "ERROR: system must be 'internachi' or 'nwidart'" >&2; exit 1 ;;
  esac
fi

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

configure_fpm() {
  local workers="$1"
  local www_conf_path
  www_conf_path=$(compose exec -T app sh -c \
    "find /etc /usr/local/etc -name 'www.conf' 2>/dev/null | head -1" || true)
  if [ -z "$www_conf_path" ]; then
    echo "ERROR: could not locate www.conf inside container." >&2; exit 1
  fi
  printf '[www]\nuser = nobody\ngroup = nobody\nlisten = 9000\npm = static\npm.max_children = %s\nclear_env = no\ncatch_workers_output = yes\n' "$workers" \
    | compose exec -T app sh -c "cat > '$www_conf_path'"
  echo "  FPM config: $www_conf_path (pm.max_children=$workers)" >&2
}

sample_container_memory() {
  local workers="$1"
  local container_id mem_raw total_mb per_worker_mb
  container_id=$(compose ps -q app 2>/dev/null | tr -d '\r' | head -1)
  mem_raw=$(docker stats --no-stream --format '{{.MemUsage}}' "$container_id" 2>/dev/null || echo "")
  total_mb=$(python3 -c "
import re
s = '$mem_raw'.split('/')[0].strip()
m = re.match(r'([\d.]+)\s*(\w+)', s)
if not m: print(0); exit()
val, unit = float(m.group(1)), m.group(2).lower()
if 'gi' in unit: val *= 1024
elif 'ki' in unit: val /= 1024
print(round(val, 1))
" 2>/dev/null || echo "0")
  per_worker_mb=$(python3 -c "print(round($total_mb / $workers, 1))" 2>/dev/null || echo "0")
  echo "$total_mb $per_worker_mb"
}

artisan_optimize() {
  compose exec -T app php artisan optimize --no-interaction 2>&1 | grep -E "DONE|FAIL|INFO" || true
  if [ "$SYSTEM" = "internachi" ]; then
    compose exec -T app php artisan modules:cache --no-interaction
  fi
}

echo "==> [$SYSTEM] v3 measure: $MODULE_COUNT modules | workers=$WORKERS_SPEC | label=$LABEL"

# --- 1. Configure environment ---
echo "  Configuring environment (Redis session/cache, OPcache on)..."
# Clear benchmark log so each run starts with clean data
compose exec -T app sh -c "rm -f storage/benchmark.jsonl" 2>/dev/null || true
cp "$APP_DIR/docker/php.ini.opcache-on" "$APP_DIR/docker/php.ini"
update_env "BENCHMARK_MODULE_COUNT" "$MODULE_COUNT"
update_env "BENCHMARK_CONDITION" "production"
update_env "SESSION_DRIVER" "redis"
update_env "CACHE_STORE" "redis"
update_env "TELESCOPE_ENABLED" "false"

# --- 2. Determine worker count ---
MEMORY_BUDGET_MB=0

if [[ "$WORKERS_SPEC" == max:* ]]; then
  BUDGET_MB="${WORKERS_SPEC#max:}"
  echo "  Probing memory with $PROBE_WORKERS workers to calculate max:${BUDGET_MB}..."

  compose up -d --force-recreate app
  sleep 8
  configure_fpm "$PROBE_WORKERS"
  compose restart app
  sleep 5
  artisan_optimize

  echo "  Probe warm-up (30 requests)..."
  for i in $(seq 1 30); do curl -k -s -o /dev/null "$HOST/benchmark/bare" || true; done
  sleep 3

  read PROBE_TOTAL_MB PROBE_PER_WORKER_MB <<< "$(sample_container_memory "$PROBE_WORKERS")"
  echo "  Probe: ${PROBE_TOTAL_MB} MB total | ${PROBE_PER_WORKER_MB} MB/worker"

  CONTAINER_NPROC=$(compose exec -T app nproc 2>/dev/null | tr -d '[:space:]' || echo "2")
  WORKERS=$(python3 -c "
import math
pw = $PROBE_PER_WORKER_MB
nproc = int('$CONTAINER_NPROC') if '$CONTAINER_NPROC'.isdigit() else 2
theoretical = math.floor($BUDGET_MB / pw) if pw > 0 else 1
cpu_cap = nproc * 32
workers = min(theoretical, cpu_cap)
print(max(1, workers))
" 2>/dev/null || echo "1")
  MEMORY_BUDGET_MB="$BUDGET_MB"
  THEORETICAL_FROM_MEMORY=$(python3 -c "
import math
pw = $PROBE_PER_WORKER_MB
print(math.floor($BUDGET_MB / pw) if pw > 0 else 0)
" 2>/dev/null || echo "0")
  echo "  Theoretical max at ${BUDGET_MB} MB: ${THEORETICAL_FROM_MEMORY} workers (memory) | CPU cap (${CONTAINER_NPROC} cores × 32): $((${CONTAINER_NPROC} * 32)) | using: $WORKERS workers"
else
  WORKERS="$WORKERS_SPEC"
  compose up -d --force-recreate app
  sleep 8
fi

# --- 3. Write www.conf (after force-recreate) and restart ---
configure_fpm "$WORKERS"
echo "  Restarting app to apply FPM config ($WORKERS workers)..."
compose restart app
sleep 5

# --- 4. artisan optimize ---
echo "  Running artisan optimize..."
artisan_optimize

# --- 5. Measure container memory at final worker count ---
echo "  Measuring container memory ($WORKERS workers, OPcache warm)..."
read TOTAL_MB PER_WORKER_MB <<< "$(sample_container_memory "$WORKERS")"
echo "  Container memory: ${TOTAL_MB} MB total | ${PER_WORKER_MB} MB/worker"

THEORETICAL_MAX=0
if [ "$MEMORY_BUDGET_MB" -gt 0 ] 2>/dev/null; then
  THEORETICAL_MAX=$(python3 -c "
import math
pw = $PER_WORKER_MB
print(math.floor($MEMORY_BUDGET_MB / pw) if pw > 0 else 0)
" 2>/dev/null || echo "0")
  echo "  Theoretical max at ${MEMORY_BUDGET_MB} MB: $THEORETICAL_MAX workers"
fi

# --- 6. Warm up ---
echo "  Warming up (100 requests per endpoint)..."
for i in $(seq 1 100); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
  curl -k -s -o /dev/null "$HOST/benchmark/data" || true
done
sleep 3

# --- 7. Smoke test ---
SMOKE_BARE=$(curl -k -s -o /dev/null -w "%{http_code}" "$HOST/benchmark/bare" || echo "000")
SMOKE_DATA=$(curl -k -s -o /dev/null -w "%{http_code}" "$HOST/benchmark/data" || echo "000")
if [ "$SMOKE_BARE" != "200" ]; then
  echo "ERROR: /benchmark/bare returned HTTP $SMOKE_BARE. Aborting." >&2; exit 1
fi
if [ "$SMOKE_DATA" != "200" ]; then
  echo "ERROR: /benchmark/data returned HTTP $SMOKE_DATA. Aborting." >&2; exit 1
fi
echo "  Smoke test OK (bare: $SMOKE_BARE, data: $SMOKE_DATA). Final warm-up (20 requests)..."
for i in $(seq 1 20); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
  curl -k -s -o /dev/null "$HOST/benchmark/data" || true
done
sleep 1

# --- 8. Run wrk (3 runs × 2 endpoints) ---
run_wrk() {
  local url="$1" endpoint_label="$2"
  local tmp_files=()

  echo "  Running wrk × $WRK_RUNS on $endpoint_label..." >&2
  for run in $(seq 1 $WRK_RUNS); do
    local tmp
    tmp=$(mktemp)
    wrk -t"$WRK_THREADS" -c"$WRK_CONNECTIONS" -d"${WRK_DURATION}s" --timeout 10s --latency \
      "$url" 2>&1 | tee "$tmp" >&2
    tmp_files+=("$tmp")
    sleep 2
  done

  python3 - "${tmp_files[@]}" << 'PYEOF'
import sys, re, json, statistics

def parse_dur(s):
    s = s.strip()
    if s.endswith('ms'): return float(s[:-2])
    if s.endswith('us'): return float(s[:-2]) / 1000
    if s.endswith('s'):  return float(s[:-1]) * 1000
    return float(s)

def parse_wrk(path):
    out = open(path).read()
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
    return req_sec, lat_avg_ms, lat_p99_ms, errors

runs = [parse_wrk(p) for p in sys.argv[1:]]

def median(vals):
    s = sorted(vals)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2

print(json.dumps({
    'req_per_sec':       round(median([r[0] for r in runs]), 2),
    'latency_avg_ms':    round(median([r[1] for r in runs]), 3),
    'latency_p99_ms':    round(median([r[2] for r in runs]), 3),
    'errors_total':      sum(r[3] for r in runs),
    'runs': [{'req_per_sec': round(r[0], 2), 'latency_avg_ms': round(r[1], 3),
              'latency_p99_ms': round(r[2], 3), 'errors': r[3]} for r in runs],
}))
PYEOF

  for tmp in "${tmp_files[@]}"; do rm -f "$tmp"; done
}

echo "  Benchmarking /benchmark/bare ($WRK_RUNS × ${WRK_DURATION}s)..."
METRICS_BARE=$(run_wrk "$HOST/benchmark/bare" "bare")

echo "  Benchmarking /benchmark/data ($WRK_RUNS × ${WRK_DURATION}s)..."
METRICS_DATA=$(run_wrk "$HOST/benchmark/data" "data")

# --- 9. Write JSON output ---
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/run_${LABEL}_m${MODULE_COUNT}_w${WORKERS}.json"

V3_SYSTEM="$SYSTEM" \
V3_MODULE_COUNT="$MODULE_COUNT" \
V3_WORKERS="$WORKERS" \
V3_WORKERS_SPEC="$WORKERS_SPEC" \
V3_LABEL="$LABEL" \
V3_TOTAL_MB="$TOTAL_MB" \
V3_PER_WORKER_MB="$PER_WORKER_MB" \
V3_THEORETICAL_MAX="$THEORETICAL_MAX" \
V3_MEMORY_BUDGET="$MEMORY_BUDGET_MB" \
V3_THREADS="$WRK_THREADS" \
V3_CONNECTIONS="$WRK_CONNECTIONS" \
V3_DURATION="$WRK_DURATION" \
V3_RUNS="$WRK_RUNS" \
V3_METRICS_BARE="$METRICS_BARE" \
V3_METRICS_DATA="$METRICS_DATA" \
python3 - << 'PYEOF' > "$OUTPUT_FILE"
import os, json, datetime
bare = json.loads(os.environ['V3_METRICS_BARE'])
data = json.loads(os.environ['V3_METRICS_DATA'])
result = {
    'system':                  os.environ['V3_SYSTEM'],
    'module_count':            int(os.environ['V3_MODULE_COUNT']),
    'workers_spec':            os.environ['V3_WORKERS_SPEC'],
    'workers':                 int(os.environ['V3_WORKERS']),
    'label':                   os.environ['V3_LABEL'],
    'condition':               'production',
    'session_driver':          'redis',
    'cache_store':             'redis',
    'container_memory_mb':     float(os.environ['V3_TOTAL_MB']),
    'per_worker_mb':           float(os.environ['V3_PER_WORKER_MB']),
    'theoretical_max_workers': int(os.environ['V3_THEORETICAL_MAX']),
    'memory_budget_mb':        int(os.environ['V3_MEMORY_BUDGET']),
    'wrk_threads':             int(os.environ['V3_THREADS']),
    'wrk_connections':         int(os.environ['V3_CONNECTIONS']),
    'wrk_duration_s':          int(os.environ['V3_DURATION']),
    'wrk_runs':                int(os.environ['V3_RUNS']),
    'timestamp':               datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'bare': bare,
    'data': data,
}
print(json.dumps(result, indent=2))
PYEOF
echo "  Saved: $OUTPUT_FILE"

# --- 10. Append to summary CSV ---
CSV_FILE="$OUTPUT_DIR/summary_v3.csv"
if [ ! -f "$CSV_FILE" ]; then
  echo "system,label,module_count,workers_spec,workers,container_memory_mb,per_worker_mb,bare_req_per_sec,bare_lat_avg_ms,bare_lat_p99_ms,bare_errors,data_req_per_sec,data_lat_avg_ms,data_lat_p99_ms,data_errors" > "$CSV_FILE"
fi

V3_SYSTEM="$SYSTEM" V3_LABEL="$LABEL" V3_MODULE_COUNT="$MODULE_COUNT" \
V3_WORKERS_SPEC="$WORKERS_SPEC" V3_WORKERS="$WORKERS" \
V3_TOTAL_MB="$TOTAL_MB" V3_PER_WORKER_MB="$PER_WORKER_MB" \
V3_METRICS_BARE="$METRICS_BARE" V3_METRICS_DATA="$METRICS_DATA" \
python3 - << 'PYEOF' >> "$CSV_FILE"
import os, json
b = json.loads(os.environ['V3_METRICS_BARE'])
d = json.loads(os.environ['V3_METRICS_DATA'])
print('{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}'.format(
    os.environ['V3_SYSTEM'],
    os.environ['V3_LABEL'],
    os.environ['V3_MODULE_COUNT'],
    os.environ['V3_WORKERS_SPEC'],
    os.environ['V3_WORKERS'],
    os.environ['V3_TOTAL_MB'],
    os.environ['V3_PER_WORKER_MB'],
    b['req_per_sec'], b['latency_avg_ms'], b['latency_p99_ms'], b['errors_total'],
    d['req_per_sec'], d['latency_avg_ms'], d['latency_p99_ms'], d['errors_total'],
))
PYEOF

REQ_BARE=$(V3_METRICS_BARE="$METRICS_BARE" python3 -c "import os,json; print(json.loads(os.environ['V3_METRICS_BARE'])['req_per_sec'])")
REQ_DATA=$(V3_METRICS_DATA="$METRICS_DATA" python3 -c "import os,json; print(json.loads(os.environ['V3_METRICS_DATA'])['req_per_sec'])")
echo "==> [$SYSTEM] v3 done: $MODULE_COUNT mods | $WORKERS workers | bare: ${REQ_BARE} req/s | data: ${REQ_DATA} req/s"

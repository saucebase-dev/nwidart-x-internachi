#!/usr/bin/env bash
# measure.sh {system} {module_count} {condition}
# Runs 50 requests against both benchmark endpoints and saves results.
# system:       internachi | nwidart
# module_count: 25 | 50 | 75 | 100 | 125 | 150 | 175 | 200
# condition:    opcache-off | opcache-on | module-cache (module-cache: internachi only)

set -euo pipefail

SYSTEM="${1:-}"
MODULE_COUNT="${2:-}"
CONDITION="${3:-}"
if [ -z "$SYSTEM" ] || [ -z "$MODULE_COUNT" ] || [ -z "$CONDITION" ]; then
  echo "Usage: $0 <internachi|nwidart> <module_count> <condition>" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/$SYSTEM"
REQUESTS=50
HOST="https://localhost"

case "$SYSTEM" in
  internachi) APP_DIR="$SCRIPT_DIR/internachi/application" ;;
  nwidart)    APP_DIR="$SCRIPT_DIR/nwidart/application" ;;
  *) echo "ERROR: system must be 'internachi' or 'nwidart'" >&2; exit 1 ;;
esac

if [ "$CONDITION" = "module-cache" ] && [ "$SYSTEM" != "internachi" ]; then
  echo "ERROR: module-cache condition is only available for internachi" >&2
  exit 1
fi

echo "==> [$SYSTEM] Measuring $MODULE_COUNT modules / condition: $CONDITION"

# --- 1. Swap php.ini and set env vars ---
echo "  Configuring php.ini for $CONDITION..."
case "$CONDITION" in
  opcache-off)   cp "$APP_DIR/docker/php.ini.opcache-off" "$APP_DIR/docker/php.ini" ;;
  opcache-on)    cp "$APP_DIR/docker/php.ini.opcache-on"  "$APP_DIR/docker/php.ini" ;;
  module-cache)  cp "$APP_DIR/docker/php.ini.opcache-on"  "$APP_DIR/docker/php.ini" ;;
esac

# Update BENCHMARK_* vars in .env (add if missing, replace if present)
update_env() {
  local key="$1" val="$2" file="$APP_DIR/.env"
  if grep -q "^$key=" "$file" 2>/dev/null; then
    sed -i '' "s|^$key=.*|$key=$val|" "$file"
  else
    echo "$key=$val" >> "$file"
  fi
}
update_env "BENCHMARK_MODULE_COUNT" "$MODULE_COUNT"
update_env "BENCHMARK_CONDITION" "$CONDITION"

# Restart the app container to pick up new php.ini and .env
echo "  Restarting app container..."
docker compose -f "$APP_DIR/docker-compose.yml" restart app
sleep 3

# --- 2. Module cache: always clear first, then rebuild if needed ---
docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
  php artisan modules:clear --no-interaction 2>/dev/null || true
if [ "$CONDITION" = "module-cache" ]; then
  echo "  Caching modules..."
  docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
    php artisan modules:cache --no-interaction
fi

# --- 3. Clear previous benchmark log ---
docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
  bash -c "truncate -s 0 storage/benchmark.jsonl 2>/dev/null || true"

# --- 4. Warm up (20 requests, not counted) ---
echo "  Warming up..."
for i in $(seq 1 20); do
  curl -k -s -o /dev/null "$HOST/benchmark/bare" || true
done

# --- 5. Run benchmark requests ---
run_requests() {
  local endpoint="$1"
  echo "  Hitting $endpoint ($REQUESTS requests)..."
  for i in $(seq 1 $REQUESTS); do
    curl -k -s -o /dev/null "$HOST/$endpoint" || true
  done
}

# Clear log before each endpoint to separate results
docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
  bash -c "truncate -s 0 storage/benchmark.jsonl"
run_requests "benchmark/bare"
BARE_JSONL=$(docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
  cat storage/benchmark.jsonl)

docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
  bash -c "truncate -s 0 storage/benchmark.jsonl"
run_requests "benchmark/data"
DATA_JSONL=$(docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
  cat storage/benchmark.jsonl)

# --- 6. Aggregate results ---
aggregate() {
  local jsonl="$1"
  echo "$jsonl" | python3 -c "
import sys, json, statistics
rows = [json.loads(l) for l in sys.stdin if l.strip()]
if not rows:
    print(json.dumps({'boot_time_ms': 0, 'total_time_ms': 0, 'peak_memory_mb': 0, 'samples': 0}))
    sys.exit()
boot  = [r['boot_time_ms']  for r in rows]
total = [r['total_time_ms'] for r in rows]
mem   = [r['peak_memory_mb'] for r in rows]
print(json.dumps({
    'boot_time_ms_avg':    round(statistics.mean(boot),  3),
    'boot_time_ms_p95':    round(sorted(boot)[int(len(boot)*0.95)], 3),
    'total_time_ms_avg':   round(statistics.mean(total), 3),
    'total_time_ms_p95':   round(sorted(total)[int(len(total)*0.95)], 3),
    'peak_memory_mb_avg':  round(statistics.mean(mem),   3),
    'samples':             len(rows),
}))
"
}

BARE_AGG=$(aggregate "$BARE_JSONL")
DATA_AGG=$(aggregate "$DATA_JSONL")

# --- 7. Write JSON output ---
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/run_${MODULE_COUNT}_${CONDITION}.json"

python3 -c "
import json, datetime
result = {
    'system':       '$SYSTEM',
    'module_count': $MODULE_COUNT,
    'condition':    '$CONDITION',
    'timestamp':    datetime.datetime.utcnow().isoformat() + 'Z',
    'bare':         $BARE_AGG,
    'data':         $DATA_AGG,
}
print(json.dumps(result, indent=2))
" > "$OUTPUT_FILE"

echo "  Saved: $OUTPUT_FILE"

# --- 8. Append to summary CSV ---
CSV_FILE="$OUTPUT_DIR/summary.csv"
if [ ! -f "$CSV_FILE" ]; then
  echo "system,module_count,condition,endpoint,boot_time_ms_avg,boot_time_ms_p95,total_time_ms_avg,total_time_ms_p95,peak_memory_mb_avg,samples" > "$CSV_FILE"
fi

append_csv() {
  local endpoint="$1" agg="$2"
  python3 -c "
import json
d = $agg
print('$SYSTEM,$MODULE_COUNT,$CONDITION,$endpoint,{},{},{},{},{},{}'.format(
    d['boot_time_ms_avg'], d['boot_time_ms_p95'],
    d['total_time_ms_avg'], d['total_time_ms_p95'],
    d['peak_memory_mb_avg'], d['samples']
))
" >> "$CSV_FILE"
}

append_csv "bare" "$BARE_AGG"
append_csv "data" "$DATA_AGG"

echo "==> [$SYSTEM] Done: $MODULE_COUNT modules / $CONDITION"

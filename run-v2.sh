#!/usr/bin/env bash
# run-v2.sh [internachi|nwidart|both]
#
# V2 benchmark: sustained throughput under concurrency with a 1 GB FPM budget.
# For each module threshold, measures how many req/sec each system can sustain
# when PHP-FPM is configured with the maximum workers that fit in 1 GB of RAM.
#
# Prerequisites:
#   - Docker running
#   - Both apps built and migrated (setup.sh completed)
#   - wrk installed on host: brew install wrk
#
# Usage: ./run-v2.sh [internachi|nwidart|both]  (default: both)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_FILE="$SCRIPT_DIR/v2/docker-compose.override.yml"

TARGET="${1:-both}"
THRESHOLDS=(25 50 75 100 125 150 175 200)

INTERNACHI_DIR="$SCRIPT_DIR/internachi/application"
NWIDART_DIR="$SCRIPT_DIR/nwidart/application"

compose_v2() {
  local app_dir="$1"; shift
  docker compose \
    -f "$app_dir/docker-compose.yml" \
    -f "$OVERRIDE_FILE" \
    "$@"
}

bring_up() {
  local app_dir="$1" system="$2"
  echo ""
  echo "========================================"
  echo " Starting Docker (v2 — mem_limit: 1g): $system"
  echo "========================================"
  compose_v2 "$app_dir" up -d
  echo "  Waiting for app to be ready..."
  sleep 8
}

bring_down() {
  local app_dir="$1" system="$2"
  echo "  Stopping Docker: $system"
  compose_v2 "$app_dir" down
}

seed_users() {
  local app_dir="$1"
  echo "  Seeding 500 benchmark users..."
  compose_v2 "$app_dir" exec -T app \
    php artisan tinker --execute "
      \$existing = \App\Models\User::count();
      \$needed = 500 - \$existing;
      if (\$needed > 0) {
          \App\Models\User::factory(\$needed)->create();
          echo \"Created {\$needed} users.\n\";
      } else {
          echo \"Already have {\$existing} users, skipping seed.\n\";
      }
    " 2>/dev/null || echo "  (seeding skipped — check manually)"
}

run_system() {
  local system="$1" app_dir="$2"

  bring_up "$app_dir" "$system"
  seed_users "$app_dir"

  local batch=0
  for threshold in "${THRESHOLDS[@]}"; do
    batch=$(( threshold / 25 ))

    echo ""
    echo "--- [$system] Setting up batch $batch (up to $threshold modules) ---"
    bash "$SCRIPT_DIR/setup-batch.sh" "$system" "$batch"

    bash "$SCRIPT_DIR/measure-v2.sh" "$system" "$threshold"
  done

  bring_down "$app_dir" "$system"
}

case "$TARGET" in
  internachi)
    run_system "internachi" "$INTERNACHI_DIR"
    ;;
  nwidart)
    run_system "nwidart" "$NWIDART_DIR"
    ;;
  both)
    run_system "internachi" "$INTERNACHI_DIR"
    run_system "nwidart" "$NWIDART_DIR"
    ;;
  *)
    echo "Usage: $0 [internachi|nwidart|both]" >&2
    exit 1
    ;;
esac

echo ""
echo "========================================"
echo " V2 Benchmark complete!"
echo " Results in: $SCRIPT_DIR/v2/internachi/ and $SCRIPT_DIR/v2/nwidart/"
echo "========================================"

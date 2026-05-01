#!/usr/bin/env bash
# run-all.sh
# Orchestrates the full benchmark: sets up module batches and measures at each
# threshold for both internachi and nWidart systems.
#
# Prerequisites:
#   - Docker running
#   - Both apps built and migrated (with 500 users seeded)
#   - ab and curl installed on host
#
# Usage: ./run-all.sh [internachi|nwidart|both]  (default: both)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:-both}"
THRESHOLDS=(25 50 75 100 125 150 175 200)

INTERNACHI_DIR="$SCRIPT_DIR/internachi/application"
NWIDART_DIR="$SCRIPT_DIR/nwidart/application"

bring_up() {
  local app_dir="$1" system="$2"
  echo ""
  echo "========================================"
  echo " Starting Docker: $system"
  echo "========================================"
  docker compose -f "$app_dir/docker-compose.yml" up -d
  echo "  Waiting for app to be ready..."
  sleep 8
}

bring_down() {
  local app_dir="$1" system="$2"
  echo "  Stopping Docker: $system"
  docker compose -f "$app_dir/docker-compose.yml" down
}

seed_users() {
  local app_dir="$1"
  echo "  Seeding 500 benchmark users..."
  docker compose -f "$app_dir/docker-compose.yml" exec -T app \
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
  local conditions=("opcache-off" "opcache-on")
  if [ "$system" = "internachi" ]; then
    conditions+=("module-cache")
  fi

  bring_up "$app_dir" "$system"
  seed_users "$app_dir"

  local batch=0
  local measured=0

  for threshold in "${THRESHOLDS[@]}"; do
    batch=$(( threshold / 25 ))

    echo ""
    echo "--- [$system] Setting up batch $batch (up to $threshold modules) ---"
    bash "$SCRIPT_DIR/setup-batch.sh" "$system" "$batch"

    for condition in "${conditions[@]}"; do
      bash "$SCRIPT_DIR/measure.sh" "$system" "$threshold" "$condition"
    done
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
echo " Benchmark complete!"
echo " Results in: $SCRIPT_DIR/internachi/ and $SCRIPT_DIR/nwidart/"
echo "========================================"

#!/usr/bin/env bash
# setup-batch.sh {system} {batch_number}
# Scaffolds 25 benchmark modules for the given system and batch.
# system: internachi | nwidart
# batch_number: 1-8  (batch 1 = Bench001-025, batch 2 = Bench026-050, ...)

set -euo pipefail

SYSTEM="${1:-}"
BATCH="${2:-}"
if [ -z "$SYSTEM" ] || [ -z "$BATCH" ]; then
  echo "Usage: $0 <internachi|nwidart> <batch_number>" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow V3_APP_DIR override so v3 benchmark uses fresh cloned apps
if [ -n "${V3_APP_DIR:-}" ]; then
  APP_DIR="$V3_APP_DIR"
else
  case "$SYSTEM" in
    internachi) APP_DIR="$SCRIPT_DIR/internachi/application" ;;
    nwidart)    APP_DIR="$SCRIPT_DIR/nwidart/application" ;;
    *) echo "ERROR: system must be 'internachi' or 'nwidart'" >&2; exit 1 ;;
  esac
fi
case "$SYSTEM" in
  internachi|nwidart) ;;
  *) echo "ERROR: system must be 'internachi' or 'nwidart'" >&2; exit 1 ;;
esac

BATCH_SIZE=25
START=$(( (BATCH - 1) * BATCH_SIZE + 1 ))
END=$(( BATCH * BATCH_SIZE ))

echo "==> [$SYSTEM] Setting up batch $BATCH (modules $(printf '%03d' $START) - $(printf '%03d' $END))"

MODULE_NAMES=()
for i in $(seq $START $END); do
  MODULE_NAMES+=("$(printf 'Bench%03d' $i)")
done

scaffold_module() {
  local name="$1"
  echo "  Scaffolding $name..."
  if [ "$SYSTEM" = "internachi" ]; then
    docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
      php artisan saucebase:recipe "$name" 'Basic Recipe' --vendor=saucebase --no-interaction 2>/dev/null || true
  else
    docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
      php artisan saucebase:recipe "$name" 'Basic Recipe' --no-interaction 2>/dev/null || true
  fi
}

if [ "$SYSTEM" = "internachi" ]; then
  # Scaffold all modules in the batch
  for name in "${MODULE_NAMES[@]}"; do
    scaffold_module "$name"
  done

  # Build the require list (vendor/folder-name = vendor/kebab-case)
  REQUIRE_ARGS=()
  for name in "${MODULE_NAMES[@]}"; do
    REQUIRE_ARGS+=("saucebase/$(echo "$name" | tr '[:upper:]' '[:lower:]')")
  done

  # Clear any module cache before composer require so package:discover boots cleanly
  docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
    php artisan modules:clear --no-interaction 2>/dev/null || true

  echo "  Running composer require for batch $BATCH..."
  docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
    composer require --no-scripts --no-interaction "${REQUIRE_ARGS[@]}"

  # Run package:discover explicitly now that all modules are on disk
  echo "  Running package:discover..."
  docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
    php artisan package:discover --ansi 2>/dev/null || true

elif [ "$SYSTEM" = "nwidart" ]; then
  STATUSES_FILE="$APP_DIR/modules_statuses.json"

  # 1. Scaffold all modules; recipe auto-enables each one, so immediately disable it in
  #    modules_statuses.json on the host so the next artisan boot doesn't try to load
  #    an unresolved provider class.
  for name in "${MODULE_NAMES[@]}"; do
    scaffold_module "$name"
    python3 -c "
import json
with open('$STATUSES_FILE') as f: d = json.load(f)
d['$name'] = False
with open('$STATUSES_FILE', 'w') as f: json.dump(d, f, indent=4)
" 2>/dev/null || true
  done

  # 2. dump-autoload so all provider classes are resolvable
  echo "  Running composer dump-autoload..."
  docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
    composer dump-autoload --no-interaction

  # 3. Write module.json and enable each module (autoload is now up to date)
  for name in "${MODULE_NAMES[@]}"; do
    FOLDER="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    MODULE_JSON="$APP_DIR/modules/$FOLDER/module.json"

    cat > "$MODULE_JSON" <<JSON
{
  "name": "$name",
  "alias": "$FOLDER",
  "description": "Benchmark module $name",
  "author": "Benchmark",
  "version": "1.0.0",
  "keywords": [],
  "priority": 0,
  "providers": [
    "Modules\\\\${name}\\\\Providers\\\\${name}ServiceProvider"
  ],
  "files": []
}
JSON
    echo "  Enabling $name..."
    docker compose -f "$APP_DIR/docker-compose.yml" exec -T app \
      php artisan module:enable "$name" --no-interaction 2>/dev/null || true
  done
fi

echo "==> [$SYSTEM] Batch $BATCH setup complete."

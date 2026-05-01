#!/usr/bin/env bash
# setup.sh [internachi|nwidart|both]
#
# Clones and configures the benchmark applications for a fresh machine.
# After this script completes, run ./run-all.sh to execute the full benchmark.
#
# Prerequisites: Docker, git, openssl, curl, python3

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/saucebase-dev/saucebase.git"
INTERNACHI_BRANCH="perf/module-benchmark/internachi"
NWIDART_BRANCH="perf/module-benchmark/nwidart"
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-both}"

setup_system() {
  local system="$1" branch="$2"
  local app_dir="$SCRIPT_DIR/$system/application"

  echo ""
  echo "========================================"
  echo " Setting up: $system ($branch)"
  echo "========================================"

  # --- 1. Clone ---
  if [ -d "$app_dir/.git" ]; then
    echo "  Already cloned — skipping git clone."
  else
    echo "  Cloning $branch..."
    mkdir -p "$(dirname "$app_dir")"
    git clone --branch "$branch" --depth 1 "$REPO_URL" "$app_dir"
  fi

  # --- 2. SSL certificates (self-signed, curl -k ignores validation) ---
  if [ ! -f "$app_dir/docker/ssl/app.pem" ]; then
    echo "  Generating self-signed SSL certificate..."
    mkdir -p "$app_dir/docker/ssl"
    openssl req -x509 -newkey rsa:2048 \
      -keyout "$app_dir/docker/ssl/app.key.pem" \
      -out    "$app_dir/docker/ssl/app.pem" \
      -days 3650 -nodes -subj "/CN=localhost" 2>/dev/null
  fi

  # --- 3. Environment file ---
  if [ ! -f "$app_dir/.env" ]; then
    echo "  Copying .env.example → .env..."
    cp "$app_dir/.env.example" "$app_dir/.env"
  fi

  # --- 4. Start Docker ---
  echo "  Starting Docker..."
  docker compose -f "$app_dir/docker-compose.yml" up -d

  echo "  Waiting for MySQL to be healthy..."
  local retries=30
  until docker compose -f "$app_dir/docker-compose.yml" exec -T mysql \
      mysqladmin ping -h localhost --silent 2>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -eq 0 ]; then
      echo "ERROR: MySQL did not become healthy in time." >&2; exit 1
    fi
    sleep 2
  done

  # --- 5. Composer install ---
  echo "  Running composer install..."
  docker compose -f "$app_dir/docker-compose.yml" exec -T app \
    composer install --no-interaction --no-progress --prefer-dist

  # --- 6. App key ---
  echo "  Generating app key..."
  docker compose -f "$app_dir/docker-compose.yml" exec -T app \
    php artisan key:generate --no-interaction

  # --- 7. Migrate and seed ---
  echo "  Running migrations and seeders..."
  docker compose -f "$app_dir/docker-compose.yml" exec -T app \
    php artisan migrate:fresh --seed --no-interaction

  # --- 8. Seed 500 benchmark users ---
  echo "  Seeding 500 benchmark users..."
  docker compose -f "$app_dir/docker-compose.yml" exec -T app \
    php artisan tinker --execute "
      \$existing = \App\Models\User::count();
      \$needed = 500 - \$existing;
      if (\$needed > 0) {
          \App\Models\User::factory(\$needed)->create();
          echo \"Created {\$needed} users.\n\";
      } else {
          echo \"Already have {\$existing} users, skipping.\n\";
      }
    " 2>/dev/null || echo "  (user seeding skipped — check manually)"

  # --- 9. Smoke test ---
  echo "  Smoke testing benchmark endpoints..."
  local bare
  bare=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost/benchmark/bare || true)
  if [ "$bare" != "200" ]; then
    echo "  WARNING: /benchmark/bare returned HTTP $bare (expected 200)." >&2
    echo "  The app may need a moment to finish starting. Try again shortly."
  else
    echo "  OK — /benchmark/bare returned 200."
  fi

  # --- 10. Stop Docker ---
  echo "  Stopping Docker (clean state for run-all.sh)..."
  docker compose -f "$app_dir/docker-compose.yml" down

  echo "==> [$system] Setup complete: $app_dir"
}

case "$TARGET" in
  internachi)
    setup_system "internachi" "$INTERNACHI_BRANCH"
    ;;
  nwidart)
    setup_system "nwidart" "$NWIDART_BRANCH"
    ;;
  both)
    setup_system "internachi" "$INTERNACHI_BRANCH"
    setup_system "nwidart" "$NWIDART_BRANCH"
    ;;
  *)
    echo "Usage: $0 [internachi|nwidart|both]" >&2
    exit 1
    ;;
esac

echo ""
echo "========================================"
echo " Setup complete!"
echo " Run the benchmark with: ./run-all.sh both"
echo "========================================"

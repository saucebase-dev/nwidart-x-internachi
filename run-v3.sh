#!/usr/bin/env bash
# run-v3.sh [internachi|nwidart|both]
#
# V3 benchmark — two experiments:
#
#   E1 (module scaling): modules 0 / 25 / 50 / 100
#                        × workers max:1024 (1 GB budget) + max:2048 (2 GB budget)
#
#   E2 (worker saturation): fixed 50 modules
#                           × workers 8 / 16 / 32 / 64 / max:1024
#                           (max:2048 at 50 modules is shared from E1 — not re-run)
#
# E2 runs after E1 so modules are already scaffolded at 50 when E2 begins.
# Each system is cloned fresh into v3/{system}/app to guarantee zero pre-loaded modules.
#
# Prerequisites: Docker, git, openssl, wrk (brew install wrk)
# Usage: ./run-v3.sh [internachi|nwidart|both]   (default: both)
# Estimated runtime: ~3 hours for both systems

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_FILE="$SCRIPT_DIR/v3/docker-compose.override.yml"

REPO_URL="https://github.com/saucebase-dev/saucebase.git"
INTERNACHI_BRANCH="feat/internachi-modular"
NWIDART_BRANCH="main"

TARGET="${1:-both}"

E1_MODULES=(0 25 50 100)
E2_FIXED_MODULES=50
E2_FIXED_WORKERS=(8 16 32 64)

compose_v3() {
  local app_dir="$1"; shift
  docker compose \
    -f "$app_dir/docker-compose.yml" \
    -f "$OVERRIDE_FILE" \
    "$@"
}

inject_benchmark_code() {
  local app_dir="$1"
  local mw="$app_dir/app/Http/Middleware/BenchmarkMiddleware.php"
  local routes="$app_dir/routes/web.php"

  # Write BenchmarkMiddleware (no LOCK_EX — eliminates cross-worker file lock)
  cat > "$mw" << 'PHP'
<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

class BenchmarkMiddleware
{
    public function handle(Request $request, Closure $next): Response
    {
        $bootTime = microtime(true) - LARAVEL_START;
        $bootMemory = memory_get_peak_usage(true);

        $response = $next($request);

        $totalTime = microtime(true) - LARAVEL_START;

        $entry = json_encode([
            'timestamp' => date('c'),
            'endpoint' => $request->path(),
            'boot_time_ms' => round($bootTime * 1000, 3),
            'total_time_ms' => round($totalTime * 1000, 3),
            'peak_memory_mb' => round($bootMemory / 1024 / 1024, 3),
            'module_count' => (int) env('BENCHMARK_MODULE_COUNT', 0),
            'condition' => env('BENCHMARK_CONDITION', 'unknown'),
        ]);

        file_put_contents(
            storage_path('benchmark.jsonl'),
            $entry . PHP_EOL,
            FILE_APPEND
        );

        return $response;
    }
}
PHP

  # Inject benchmark routes if not already present
  if ! grep -q "benchmark/bare" "$routes" 2>/dev/null; then
    python3 - "$routes" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()

inject = """
use App\\Http\\Middleware\\BenchmarkMiddleware;
use App\\Models\\User;
use Illuminate\\Http\\Request;
"""

routes = """
Route::middleware(BenchmarkMiddleware::class)->group(function () {
    Route::get('/benchmark/bare', fn () => response('ok'));
    Route::get('/benchmark/data', function (Request $request) {
        $request->validate(['page' => ['integer', 'min:1']]);
        return response()->json(User::paginate(15));
    });
});
"""

# Add use statements after existing use block
lines = content.split('\n')
last_use = max((i for i, l in enumerate(lines) if l.startswith('use ')), default=2)
lines.insert(last_use + 1, inject.strip())
content = '\n'.join(lines) + '\n' + routes

open(path, 'w').write(content)
print('  benchmark routes injected into routes/web.php')
PYEOF
  fi

  echo "  Benchmark code injected (BenchmarkMiddleware + routes)."
}

setup_v3_app() {
  local system="$1" branch="$2"
  local app_dir="$SCRIPT_DIR/v3/$system/app"

  echo ""
  echo "========================================"
  echo " V3 App Setup: $system ($branch)"
  echo "========================================"

  # Clone fresh (skip if already done for this run)
  if [ -d "$app_dir/.git" ]; then
    echo "  Already cloned at $app_dir — skipping git clone."
  else
    echo "  Cloning $branch into v3/$system/app..."
    mkdir -p "$(dirname "$app_dir")"
    git clone --branch "$branch" --depth 1 "$REPO_URL" "$app_dir"
  fi

  # SSL certificates
  if [ ! -f "$app_dir/docker/ssl/app.pem" ]; then
    echo "  Generating self-signed SSL certificate..."
    mkdir -p "$app_dir/docker/ssl"
    openssl req -x509 -newkey rsa:2048 \
      -keyout "$app_dir/docker/ssl/app.key.pem" \
      -out    "$app_dir/docker/ssl/app.pem" \
      -days 3650 -nodes -subj "/CN=localhost" 2>/dev/null
  fi

  # Environment file
  if [ ! -f "$app_dir/.env" ]; then
    echo "  Copying .env.example → .env..."
    cp "$app_dir/.env.example" "$app_dir/.env"
    # Switch to MySQL (new .env.example defaults to sqlite) and set credentials
    python3 -c "
path = '$app_dir/.env'
c = open(path).read()
c = c.replace('DB_CONNECTION=sqlite', 'DB_CONNECTION=mysql')
c = c.replace('# DB_HOST=localhost', 'DB_HOST=mysql')
c = c.replace('# DB_PORT=3306', 'DB_PORT=3306')
c = c.replace('# DB_DATABASE=\${APP_SLUG}', 'DB_DATABASE=app')
c = c.replace('# DB_USERNAME=\${APP_SLUG}', 'DB_USERNAME=app')
c = c.replace('# DB_PASSWORD=secret', 'DB_PASSWORD=secret')
open(path, 'w').write(c)
"
  fi

  # Patch: remove dev-time path repos and path-installed packages before composer install.
  # Only removes packages that are actually installed via path (local dev symlinks) —
  # Packagist saucebase/* packages (e.g. saucebase/breadcrumbs) are kept in require.
  python3 -c "
import json

# Find packages installed via path in composer.lock (these reference modules/* which don't exist yet)
lock_path = '$app_dir/composer.lock'
lock = json.load(open(lock_path))
def is_path(p):
    return (p.get('dist', {}).get('type') == 'path'
            or p.get('source', {}).get('type') == 'path'
            or p.get('installation-source') == 'path')
path_pkg_names = {p['name'] for p in lock.get('packages', []) + lock.get('packages-dev', []) if is_path(p)}
lock['packages'] = [p for p in lock['packages'] if not is_path(p)]
lock['packages-dev'] = [p for p in lock['packages-dev'] if not is_path(p)]
json.dump(lock, open(lock_path, 'w'), indent=4)

# Remove path repositories AND path-only saucebase/* from composer.json
cj_path = '$app_dir/composer.json'
cj = json.load(open(cj_path))
cj['repositories'] = [r for r in cj.get('repositories', []) if r.get('type') != 'path']
cj['require'] = {k: v for k, v in cj.get('require', {}).items() if k not in path_pkg_names}
json.dump(cj, open(cj_path, 'w'), indent=4)
removed = ', '.join(path_pkg_names) if path_pkg_names else 'none'
print(f'  Removed path packages: {removed}; path repos removed from composer.json.')
"

  # Patch: inject benchmark php.ini (opcache-on) — not present on main/feat branches
  cp "$SCRIPT_DIR/v3/php.ini.opcache-on" "$app_dir/docker/php.ini.opcache-on"
  cp "$SCRIPT_DIR/v3/php.ini.opcache-on" "$app_dir/docker/php.ini"

  # Inject benchmark middleware and routes (not present on main/feat branches)
  inject_benchmark_code "$app_dir"

  # Clear bootstrap cache so no stale module references survive between runs
  rm -f "$app_dir/bootstrap/cache/"*.php
  rm -rf "$app_dir/bootstrap/cache/filament"
  echo "  Bootstrap cache cleared."

  # Start Docker with override (mem_limit: 4g)
  echo "  Starting Docker..."
  compose_v3 "$app_dir" up -d

  echo "  Waiting for MySQL to be healthy..."
  local retries=30
  until compose_v3 "$app_dir" exec -T mysql \
      mysqladmin ping -h localhost --silent 2>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -eq 0 ]; then
      echo "ERROR: MySQL did not become healthy in time." >&2; exit 1
    fi
    sleep 2
  done

  # Composer install (--no-scripts skips module:generate-types and other non-essential hooks)
  echo "  Running composer install..."
  compose_v3 "$app_dir" exec -T app \
    composer install --no-interaction --no-progress --prefer-dist --no-scripts 2>&1 | tail -3
  # Run package:discover explicitly (needed by internachi/modular)
  compose_v3 "$app_dir" exec -T app \
    php artisan package:discover --ansi --no-interaction 2>&1 | tail -2 || true

  # Restore path repository now that initial install is done (needed for bench module scaffolding)
  python3 -c "
import json
path = '$app_dir/composer.json'
cj = json.load(open(path))
repos = cj.get('repositories', [])
if not any(r.get('type') == 'path' for r in repos):
    repos.insert(0, {'type': 'path', 'url': 'modules/*', 'options': {'symlink': True}})
    cj['repositories'] = repos
    json.dump(cj, open(path, 'w'), indent=4)
    print('  composer.json: path repository restored (symlink: false for bench modules).')
"

  # App key
  echo "  Generating app key..."
  compose_v3 "$app_dir" exec -T app \
    php artisan key:generate --no-interaction

  # Stop — measure-v3.sh will bring it up with force-recreate per run
  echo "  Stopping Docker (measure-v3.sh will start per-run)..."
  compose_v3 "$app_dir" down

  echo "==> [$system] App ready at: $app_dir"
}

bring_up() {
  local app_dir="$1" system="$2"
  echo ""
  echo "========================================"
  echo " Starting Docker (v3 — mem_limit: 4g): $system"
  echo "========================================"
  compose_v3 "$app_dir" up -d
  echo "  Waiting for app and Redis to be ready..."
  sleep 12
}

bring_down() {
  local app_dir="$1" system="$2"
  echo "  Stopping Docker: $system"
  compose_v3 "$app_dir" down
}

run_system() {
  local system="$1" app_dir="$2"

  bring_up "$app_dir" "$system"

  echo "  Running migrate:fresh --seed..."
  compose_v3 "$app_dir" exec -T app \
    php artisan migrate:fresh --seed --no-interaction 2>&1 | tail -5

  # -------------------------------------------------------
  # E1: Module scaling
  # -------------------------------------------------------
  echo ""
  echo "========================================"
  echo " E1: Module scaling — $system"
  echo " Modules: ${E1_MODULES[*]}"
  echo " Workers: max:1024 + max:2048 per data point"
  echo "========================================"

  for module_count in "${E1_MODULES[@]}"; do
    if [ "$module_count" -gt 0 ]; then
      local batch=$(( module_count / 25 ))
      echo ""
      echo "--- [$system] E1: Setting up batch $batch (up to $module_count modules) ---"
      V3_APP_DIR="$app_dir" bash "$SCRIPT_DIR/setup-batch.sh" "$system" "$batch"
    fi

    echo ""
    echo "--- [$system] E1: $module_count modules × max:1024 ---"
    bash "$SCRIPT_DIR/measure-v3.sh" "$system" "$module_count" "max:1024" "e1_max1g" "$app_dir"

    echo ""
    echo "--- [$system] E1: $module_count modules × max:2048 ---"
    bash "$SCRIPT_DIR/measure-v3.sh" "$system" "$module_count" "max:2048" "e1_max2g" "$app_dir"
  done

  # -------------------------------------------------------
  # E2: Worker saturation (50 modules already scaffolded)
  # -------------------------------------------------------
  echo ""
  echo "========================================"
  echo " E2: Worker saturation — $system"
  echo " Fixed: $E2_FIXED_MODULES modules"
  echo " Workers: ${E2_FIXED_WORKERS[*]} + max:1024"
  echo " (max:2048 at $E2_FIXED_MODULES modules shared from E1)"
  echo "========================================"

  for workers in "${E2_FIXED_WORKERS[@]}"; do
    echo ""
    echo "--- [$system] E2: $E2_FIXED_MODULES modules × $workers workers ---"
    bash "$SCRIPT_DIR/measure-v3.sh" "$system" "$E2_FIXED_MODULES" "$workers" "e2_w${workers}" "$app_dir"
  done

  echo ""
  echo "--- [$system] E2: $E2_FIXED_MODULES modules × max:1024 ---"
  bash "$SCRIPT_DIR/measure-v3.sh" "$system" "$E2_FIXED_MODULES" "max:1024" "e2_max1g" "$app_dir"

  bring_down "$app_dir" "$system"
}

# Wipe previous v3 result files (not the app dirs)
echo "  Wiping previous v3 result files..."
find "$SCRIPT_DIR/v3/internachi" -maxdepth 1 \( -name "*.json" -o -name "*.csv" \) -delete 2>/dev/null || true
find "$SCRIPT_DIR/v3/nwidart"    -maxdepth 1 \( -name "*.json" -o -name "*.csv" \) -delete 2>/dev/null || true

case "$TARGET" in
  internachi)
    setup_v3_app "internachi" "$INTERNACHI_BRANCH"
    run_system "internachi" "$SCRIPT_DIR/v3/internachi/app"
    ;;
  nwidart)
    setup_v3_app "nwidart" "$NWIDART_BRANCH"
    run_system "nwidart" "$SCRIPT_DIR/v3/nwidart/app"
    ;;
  both)
    setup_v3_app "internachi" "$INTERNACHI_BRANCH"
    setup_v3_app "nwidart"    "$NWIDART_BRANCH"
    run_system "internachi" "$SCRIPT_DIR/v3/internachi/app"
    run_system "nwidart"    "$SCRIPT_DIR/v3/nwidart/app"
    ;;
  *)
    echo "Usage: $0 [internachi|nwidart|both]" >&2
    exit 1
    ;;
esac

echo ""
echo "========================================"
echo " V3 Benchmark complete!"
echo " Results:"
echo "   $SCRIPT_DIR/v3/internachi/summary_v3.csv"
echo "   $SCRIPT_DIR/v3/nwidart/summary_v3.csv"
echo "========================================"

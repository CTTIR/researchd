#!/usr/bin/env bash
# ===========================================================================
# End-to-end: the researchR R client against a real, running researchd.
#
# Starts a throwaway uvicorn on a free port with a seeded scratch database,
# points the package's integration tests at it, and tears it down again.
# This is the only test that exercises both halves of the project together.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."               # researchd/
RD="$PWD"

# researchR lives in its own repository. Point RESEARCHR_PKG at your checkout,
# or clone it beside this one and the default finds it.
PKG="${RESEARCHR_PKG:-$(dirname "$RD")/researchR}"
if [ ! -f "$PKG/DESCRIPTION" ]; then
  echo "researchR package not found at $PKG" >&2
  echo "clone it beside this repo, or set RESEARCHR_PKG:" >&2
  echo "  git clone https://github.com/CTTIR/researchR.git $(dirname "$RD")/researchR" >&2
  exit 2
fi

PORT="${PORT:-8077}"
DB="$RD/dev/state/tmp/integration.sqlite"
TOKEN="integration-token-$$"
LOG="$RD/dev/state/tmp/integration_server.log"

"$RD/.venv/bin/python" "$RD/dev/tests/seed_server.py" "$DB"

DB_PATH="$DB" \
APP_SECRET_KEY="$("$RD/.venv/bin/python" -c 'from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())')" \
API_TOKEN="$TOKEN" SECURE_COOKIE=0 BASE_URL="http://127.0.0.1:$PORT" \
"$RD/.venv/bin/python" -m uvicorn web.app:app --host 127.0.0.1 --port "$PORT" --log-level warning \
  > "$LOG" 2>&1 &
SERVER=$!
cleanup() { kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 50); do
  if "$RD/.venv/bin/python" - "$PORT" <<'PY' 2>/dev/null
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=1).read()
PY
  then break; fi
  sleep 0.2
done

echo "[integration] researchd up on port $PORT; running the researchR suite"
cd "$PKG"
R_LIBS="$RD/dev/state/tmp/Rlib" \
RESEARCHR_TEST_URL="http://127.0.0.1:$PORT" \
RESEARCHR_TEST_TOKEN="$TOKEN" \
RESEARCHR_TEST_QUESTION="seeded" \
Rscript -e 'pkgload::load_all(".", quiet = TRUE);
            testthat::test_dir("tests/testthat", package = "researchR",
                               load_package = "none", reporter = "summary",
                               stop_on_failure = TRUE)'

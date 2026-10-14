#!/bin/sh
# ===========================================================================
# WAL-safe SQLite backup.
#
# A plain `cp` of a live WAL database can capture a torn state: the main file
# and the -wal file are two files, and copying them at different instants can
# produce a snapshot that never existed. SQLite's own backup API takes a
# consistent snapshot of a database that is being written to.
#
# Usage:
#   scripts/backup.sh <db-path> <backup-dir> [keep]
#   scripts/backup.sh db/pipeline.sqlite /var/backups/researchd 14
#
# Cron it on the HOST (the container has no scheduler for this):
#   0 3 * * * /srv/researchd/scripts/backup.sh \
#             /srv/researchd/db/pipeline.sqlite /var/backups/researchd
#
# ALSO BACK UP APP_SECRET_KEY, separately and somewhere else. It is not in
# the database. Without it, the per-question API keys in a restored backup
# are ciphertext you cannot read -- you would have to re-enter every one.
# ===========================================================================
set -eu

DB="${1:?usage: backup.sh <db-path> <backup-dir> [keep]}"
DIR="${2:?usage: backup.sh <db-path> <backup-dir> [keep]}"
KEEP="${3:-14}"

[ -f "$DB" ] || { echo "backup.sh: no such database: $DB" >&2; exit 1; }
mkdir -p "$DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DIR/pipeline-$STAMP.sqlite"

# Prefer the sqlite3 CLI; fall back to Python's sqlite3 module, which exposes
# the same backup API. Neither the rocker nor the python-slim image ships the
# CLI, and plenty of hosts do not either, so the fallback is the common path.
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" ".backup '$OUT'"
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$DB" "$OUT" <<'PY'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)          # consistent snapshot, WAL and all
dst.close(); src.close()
PY
else
  echo "backup.sh: need either sqlite3 or python3 on PATH" >&2
  exit 1
fi

# Verify the snapshot before trusting it -- a backup you have not read is a
# hope, not a backup.
if command -v sqlite3 >/dev/null 2>&1; then
  RESULT=$(sqlite3 "$OUT" "PRAGMA integrity_check;")
else
  RESULT=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('PRAGMA integrity_check').fetchone()[0])" "$OUT")
fi
[ "$RESULT" = "ok" ] || { echo "backup.sh: integrity check FAILED: $RESULT" >&2; rm -f "$OUT"; exit 1; }

# Retain the newest $KEEP snapshots.
ls -1t "$DIR"/pipeline-*.sqlite 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm --

echo "backup ok: $OUT ($(wc -c < "$OUT") bytes, integrity_check=$RESULT)"

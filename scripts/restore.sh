#!/bin/sh
# ===========================================================================
# Restore a backup taken by scripts/backup.sh.
#
#   docker compose down            # nothing may be writing during a restore
#   scripts/restore.sh /var/backups/researchd/pipeline-20260826-030000.sqlite \
#                      db/pipeline.sqlite
#   docker compose up -d
#
# The current database is moved aside rather than deleted, so a restore onto
# the wrong file is recoverable.
#
# Remember APP_SECRET_KEY must be the same value it was when the backup was
# taken, or every stored API key decrypts to "" and the engine will fetch
# unauthenticated without saying so.
# ===========================================================================
set -eu
SRC="${1:?usage: restore.sh <backup-file> <db-path>}"
DST="${2:?usage: restore.sh <backup-file> <db-path>}"

[ -f "$SRC" ] || { echo "restore.sh: no such backup: $SRC" >&2; exit 1; }

if command -v sqlite3 >/dev/null 2>&1; then
  RESULT=$(sqlite3 "$SRC" "PRAGMA integrity_check;")
else
  RESULT=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('PRAGMA integrity_check').fetchone()[0])" "$SRC")
fi
[ "$RESULT" = "ok" ] || { echo "restore.sh: backup is corrupt: $RESULT" >&2; exit 1; }

if [ -f "$DST" ]; then
  ASIDE="$DST.replaced-$(date +%Y%m%d-%H%M%S)"
  mv "$DST" "$ASIDE"
  echo "existing database moved aside: $ASIDE"
fi
# A stale -wal/-shm from the old database must not be applied to the new one.
rm -f "$DST-wal" "$DST-shm"
cp "$SRC" "$DST"
echo "restored: $SRC -> $DST"
echo "start the stack again with: docker compose up -d"

#!/bin/sh
# ===========================================================================
# Disk-growth control. Both of the things that grow without bound here are
# outputs, not state: stored records and rendered digests.
#
#   scripts/prune.sh <db-path> <digests-dir> [record-months] [digest-keep]
#   scripts/prune.sh db/pipeline.sqlite digests 24 60
#
# Cron it monthly on the HOST:
#   0 4 1 * * /srv/researchd/scripts/prune.sh \
#             /srv/researchd/db/pipeline.sqlite /srv/researchd/digests
#
# What it does, and what it deliberately does NOT do:
#
#   records   pruned by first_seen older than <record-months> (default 24).
#             Pruning a record makes it eligible to be "new" again if the
#             same paper resurfaces in a later fetch window -- the dedup key
#             lives in this table and nowhere else. 24 months is well past
#             any question's lookback, so in practice that cannot happen;
#             shorten it only if you understand that trade-off.
#   signals   same treatment, same reasoning.
#   fetch_log capped at the most recent 5000 rows. It is pure telemetry.
#   digests   the newest <digest-keep> HTML and Markdown files are kept.
#   WAL       checkpointed and truncated at the end.
#
#   questions, concepts, auth, sessions, signal_config, service_heartbeat are
#   never touched: they are configuration and identity, not accumulation.
# ===========================================================================
set -eu
DB="${1:?usage: prune.sh <db-path> <digests-dir> [record-months] [digest-keep]}"
DIGESTS="${2:?usage: prune.sh <db-path> <digests-dir> [record-months] [digest-keep]}"
MONTHS="${3:-24}"
KEEP="${4:-60}"

[ -f "$DB" ] || { echo "prune.sh: no such database: $DB" >&2; exit 1; }

python3 - "$DB" "$MONTHS" <<'PY'
import sqlite3, sys
db, months = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(db, timeout=30)
con.execute("PRAGMA busy_timeout=30000;")
cutoff = f"-{months} months"
r = con.execute("DELETE FROM records WHERE first_seen < datetime('now', ?)", (cutoff,))
n_rec = r.rowcount
r = con.execute("DELETE FROM signals WHERE first_seen < datetime('now', ?)", (cutoff,))
n_sig = r.rowcount
r = con.execute("DELETE FROM fetch_log WHERE id NOT IN "
                "(SELECT id FROM fetch_log ORDER BY id DESC LIMIT 5000)")
n_log = r.rowcount
con.commit()
con.execute("PRAGMA wal_checkpoint(TRUNCATE);")
con.close()
print(f"pruned {n_rec} record(s), {n_sig} signal(s), {n_log} fetch_log row(s) "
      f"older than {months} months")
PY

if [ -d "$DIGESTS" ]; then
  for ext in html md log; do
    ls -1t "$DIGESTS"/*."$ext" 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm --
  done
  echo "digests: kept the newest $KEEP of each type in $DIGESTS"
fi

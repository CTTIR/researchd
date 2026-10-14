#!/usr/bin/env bash
# ============================================================
# cron.sh — wrapper for scheduled runs. Loads secrets from a
# local .env (gitignored), then runs the pipeline.
#
# Schedule examples (crontab -e):
#   Weekly, Monday 07:00:   0 7 * * 1  /path/to/research-pipeline/cron.sh
#   Daily, 07:00:           0 7 * * *  /path/to/research-pipeline/cron.sh
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

# load secrets if present (EMAIL_PW, ZOTERO_KEY, ENTREZ_KEY)
[ -f .env ] && set -a && . ./.env && set +a

LOG="digests/run_$(date +%Y%m%d_%H%M%S).log"
mkdir -p digests
Rscript R/run_all.R "$@" 2>&1 | tee "$LOG"

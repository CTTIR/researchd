# researchd

Self-hosted literature and signal surveillance. Watches the free biomedical
databases on a schedule, deduplicates and classifies everything it finds, and
delivers it as RSS feeds, email digests and Zotero pushes.

This is the **server** half of a pair.
[**researchR**](https://github.com/CTTIR/researchR) is the client: an R
package that drives this service over its REST API, so questions can be
defined and results pulled into tibbles from R instead of the browser.

```r
remotes::install_github("CTTIR/researchR")
```

**Development software for academic research.** Source results require review;
coverage and upstream availability vary. See the executable checks below.

---

## What it watches

**Literature** — PubMed, Europe PMC, OpenAlex, Crossref, Semantic Scholar,
ClinicalTrials.gov, bioRxiv/medRxiv. Unpaywall enriches each DOI with a legal
open-access link where one exists.

**Signals** — the earlier, less reliable stream: grant awards (NIH RePORTER),
trial registrations and results (ClinicalTrials.gov, CTIS, ISRCTN via
`ctrdata`), regulatory decisions (openFDA), SEC filings, patents, and curated
RSS from journals, institutions, wires, trade press and company investor
relations. Every signal carries an explicit confidence tier.

All sources are free. No institutional access required.

Sources overlap on purpose: dedup cleans up, ranking triages. Records are
**never dropped** — scoring orders them, it does not filter them.

## Three services, one database

| Service | Language | Role |
|---|---|---|
| `pipeline` | R, cron | fetch → dedup → classify → rank → **write** |
| `web` | Python/FastAPI | RSS feeds (open) · dashboard (password + TOTP) · REST API (token) |
| `scheduler` | Python | per-question email, each on its own cadence |

They never call each other. They coordinate only through
`db/pipeline.sqlite` (WAL mode, `busy_timeout` on every connection), which is
bind-mounted so it survives `down`/`up`.

```
config + dashboard + researchR
            │
            ▼
   ┌──────────────────┐        ┌──────────────┐
   │  pipeline  (R)   │───────►│              │◄──── web ────► feeds, dashboard, /api/v1
   │  cron, 2 lanes   │        │   SQLite     │
   └──────────────────┘        │  (WAL)       │◄──── scheduler ────► email
                               └──────────────┘
```

## Endpoints

```
PUBLIC (no auth — this is what Zotero subscribes to)
  GET /                              landing page
  GET /healthz                       liveness
  GET /feed/{id}.xml                 curated stream (honours the digest threshold)
  GET /feed/{id}/all.xml             everything stored — the recall safety valve
  GET /feed/{id}/{study_type}.xml    one bucket
  GET /feed/{id}/preprints.xml       preprints only
  GET /signals/{id}.xml              signals at or above min_confidence
  GET /signals/{id}/all.xml          every tier, including unverified

DASHBOARD (session cookie + TOTP second factor)
  GET/POST /setup /login /2fa /2fa/enroll, POST /logout
  GET  /                             dashboard
  GET/POST/DELETE /api/questions     manage questions
  GET/POST /api/signal_config/{id}   signals-track settings
  GET  /api/source_health            per-source fetch heartbeat
  GET  /api/heartbeat                per-service liveness

API (bearer token — API_TOKEN; this is what researchR speaks)
  GET  /api/v1/meta                  the server's vocabulary
  GET/POST/DELETE /api/v1/questions
  GET  /api/v1/records               filter, paginate
  GET  /api/v1/signals               filter by type and confidence floor
  GET  /api/v1/source_health  /api/v1/heartbeat  /api/v1/signal_config/{id}

INGEST (bearer token — INGEST_TOKEN; for n8n and other normalizers)
  POST /api/ingest
```

The three token/session surfaces are **mutually disjoint**: a dashboard
session does not open `/api/v1`, the API token does not open `/api/ingest`,
and neither opens the dashboard. Any token left unset makes its surface
answer 503 rather than serving unauthenticated.

## First run

1. Generate the master key — it encrypts per-question API keys at rest:

   ```bash
   python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
   ```

   Put it in `.env` as `APP_SECRET_KEY`. **Back it up somewhere other than
   the database.** It is not stored there, and without it the encrypted keys
   in a restored backup are unreadable — you would re-enter every one.

2. `cp .env.example .env` and edit it. Generate `API_TOKEN` and, if you use
   the ingest seam, `INGEST_TOKEN`: `openssl rand -hex 32`.

3. Edit `config/settings.yaml` — SMTP host, Zotero ids, and **`contact_email`**,
   which is sent to OpenAlex, Crossref and Unpaywall as polite-pool
   identification. The shipped value is a placeholder.

4. `docker compose up -d --build`, then open `https://your-domain/`.

5. `/setup` creates the admin. Logging in forces you through **2FA
   enrollment** — scan the QR, save the eight recovery codes. There is no way
   to reach the dashboard without it.

6. Define a question, set `RUN_ON_START=1`, `docker compose up -d`, watch
   `docker compose logs -f pipeline`, then set it back to `0`.

## Two schedules, and why

**Fetching** runs on cron inside the `pipeline` container, in two lanes:

- `CRON_SCHEDULE` (default daily 06:00) — the full run, both tracks.
- `CRON_FAST_SCHEDULE` (default hourly at :15) — signals only. SEC filings,
  IR feeds and wires move in hours; PubMed moves in days. Tighten to `*/15`
  if you want lower latency.

**Email** is per question, set as its own cron expression with its own
recipient list. `email_cron` fires in the container's `TZ`, so `0 7 * * 1`
means Monday at seven *where you are*. The `scheduler` service checks every
`CHECK_INTERVAL` seconds; a weekly question and a daily question coexist,
each mailing its own list. Records are marked emailed only after a
**successful** send, so an SMTP outage delays delivery rather than losing it.

Questions with `instant_alerts` on additionally get high-priority signals
emailed on the next tick, without waiting for the digest cadence.

## Recall versus precision

Everything found is stored. Per question, `digest_mode: threshold` with a
`min_score` limits what reaches the **curated feed and the email** — the
high-signal stream you actually read. `/feed/{id}/all.xml` always shows
everything. Below-threshold records are never marked emailed, so lowering the
threshold later lets them flow out retroactively.

## Operations

### Backups

```bash
scripts/backup.sh db/pipeline.sqlite /var/backups/researchd [keep]
```

Takes a **WAL-safe** snapshot (SQLite's backup API, not `cp` — the main file
and the `-wal` are two files, and copying them at different instants can
produce a state that never existed), verifies it with `PRAGMA
integrity_check`, and keeps the newest `keep` (default 14). Uses the
`sqlite3` CLI when present and Python's `sqlite3` module otherwise, since
neither container image ships the CLI.

Cron it on the host:

```
0 3 * * * /srv/researchd/scripts/backup.sh /srv/researchd/db/pipeline.sqlite /var/backups/researchd
```

**Back up `APP_SECRET_KEY` separately**, and not next to the database — the
whole point of at-rest encryption is that a leaked backup is not a leaked
key.

### Restore

```bash
docker compose down          # nothing may be writing during a restore
scripts/restore.sh /var/backups/researchd/pipeline-20260826-030000.sqlite db/pipeline.sqlite
docker compose up -d
```

Verifies the snapshot first, moves the existing database aside instead of
deleting it, and clears any stale `-wal`. `APP_SECRET_KEY` must be the value
it was when the backup was taken.

### Retention

`records`, `signals`, `fetch_log` and `digests/` grow without bound.

```
0 4 1 * * /srv/researchd/scripts/prune.sh /srv/researchd/db/pipeline.sqlite /srv/researchd/digests
```

Prunes records and signals older than 24 months (configurable), caps
`fetch_log` at 5000 rows, keeps the newest 60 digest files, and checkpoints
the WAL. Questions, concepts, auth, sessions and heartbeats are never
touched. Note that pruning a record frees its dedup key, so the same paper
could resurface as "new" — the default window is far outside any question's
lookback, but shorten it knowingly.

The engine also checkpoints the WAL at the end of every run, so it stays
bounded between prunes.

### Is it still working?

The worst failure of a surveillance system is silence that looks like a quiet
week.

- `GET /api/source_health` — per source: last successful fetch, last fetch
  that actually returned rows, error count, and a `stale` flag. Watch
  `last_nonempty` as closely as `last_ok`: a source can answer happily while
  its query has stopped matching anything.
- `GET /api/heartbeat` — per service: did the engine and the scheduler run at
  all. A crashed engine writes no `fetch_log` rows either, so without this
  "dead engine" and "dead source" look identical.
- `docker compose logs -f pipeline | web | scheduler`.

## TLS reverse proxy

`web` speaks plain HTTP on 8000 and must sit behind a TLS terminator. Feeds
and the dashboard are internet-facing, and `SECURE_COOKIE=1` (the default)
means the browser will not return the session cookie over plain HTTP — you
would be unable to log in. Set `SECURE_COOKIE=0` **only** for local testing.

Caddy, which handles certificates automatically:

```
feeds.example.org {
    reverse_proxy web:8000
}
```

Nginx:

```nginx
server {
    listen 443 ssl http2;
    server_name feeds.example.org;
    ssl_certificate     /etc/letsencrypt/live/feeds.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/feeds.example.org/privkey.pem;

    location / {
        proxy_pass         http://web:8000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

Put the proxy on the same Docker network as `web`, set `BASE_URL` to the
public URL so feed self-links are right, and do not publish port 8000 to the
internet directly.

## Threat model, honestly

At-rest encryption protects a leaked database or backup. It does **not**
protect against host compromise: `APP_SECRET_KEY` lives in `.env` on the same
machine. The dashboard is password + TOTP; feeds are deliberately open, so
treat a feed URL as public. Put `web` behind TLS and keep `SECURE_COOKIE=1`.

## Running the engine by hand

```bash
docker compose exec pipeline Rscript R/run_all.R              # all questions
docker compose exec pipeline Rscript R/run_all.R glp1_mash    # just one
docker compose exec pipeline env RUN_MODE=signals Rscript R/run_all.R
```

`RUN_MODE` is `all` (default), `lit` or `signals`. The engine exits non-zero
if any question failed, while still processing the rest.

Bare R, no Docker: `Rscript R/run_all.R`, or `./cron.sh` as a host cron
wrapper.

## Tests

`dev/tests/` contains offline checks using temporary databases and synthetic fixtures.
Create a local test environment before running them:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-test.txt
```

The R checks use the dependencies listed in the pipeline Dockerfile.

Run them all with `dev/tests/run_all.sh` (add `--live` for the two that need
network), or individually:

```bash
.venv/bin/python dev/tests/schema_coverage.py .      # SQL vs schema
.venv/bin/python dev/tests/db_phase2.py              # WAL, contention, cascade
.venv/bin/python dev/tests/taxonomy_sync.py          # the three-way label sync
.venv/bin/python dev/tests/web_phase4.py             # feeds, auth, 2FA, /api/v1
.venv/bin/python dev/tests/scheduler_phase5.py       # cadence and dispatch
.venv/bin/python dev/tests/integration_phase6.py     # all services, one DB
.venv/bin/python dev/tests/security_phase7.py        # adversarial pass
.venv/bin/python dev/tests/ops_phase8.py             # restart, backup, retention
dev/tests/Rrun.sh dev/tests/parse_all.R              # every engine source parses
dev/tests/Rrun.sh dev/tests/classify_table.R         # classifier edge cases
dev/tests/Rrun.sh dev/tests/dedup_rank.R             # dedup and ranking
dev/tests/Rrun.sh dev/tests/fetch_plumbing.R         # sources, keys, isolation
dev/tests/Rrun.sh dev/tests/live_fetchers.R          # the real external APIs
dev/tests/integration_client.sh                      # the researchR client, live
```

`integration_client.sh` needs a **researchR checkout**. Clone it beside this
repository and it is found automatically, or point `RESEARCHR_PKG` at it:

```bash
git clone https://github.com/CTTIR/researchR.git ../researchR
dev/tests/integration_client.sh
```

The local verification environment is a Python venv at `.venv/` and a private
R library at `dev/state/tmp/Rlib`, both gitignored. Neither is part of the
deployed stack — the containers install their own dependencies at build time.

## Known limits

- **Free-only means "first wave", not literally first.** The genuinely
  earliest signals — company topline press, professional pipeline databases,
  real-time conference coverage — are paid or unstructured.
- **WHO ICTRP is not covered.** `ctrdata` reaches CTGOV2, CTIS and ISRCTN
  only; ChiCTR, jRCT and CTRI are a real gap for global scope, and ICTRP
  offers only weekly bulk XML.
- **Semantic Scholar is rate-limited without a key** and will often return
  nothing; the fetcher backs off and degrades cleanly.
- **bioRxiv has no query grammar**, so it pulls a window and filters
  client-side — correct but slow (roughly a minute per two days of window).
- **PubMed abstracts are not fetched** (esummary omits them); ranking scores
  its title. Europe PMC and OpenAlex supply abstracts and dedup prefers them.
- **Scrapers are a framework plus seeded targets**, not coverage. They break
  when sites change, and everything scraped is `unverified`.
- **One SQLite file, three writers** is right for one host and the thing that
  will outgrow first. Postgres is the move the moment you want a second
  machine.
- **Self-hosted SMTP lands in spam** without SPF/DKIM/DMARC and IP
  reputation. A transactional relay via the same SMTP settings sidesteps it.
- **The first run is heavy** — the whole lookback window is "new".

## License

MIT License. Copyright (c) 2026 Raban Heller. See [LICENSE](LICENSE).

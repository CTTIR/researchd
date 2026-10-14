#!/usr/bin/env Rscript
# ============================================================
# run_all.R — entry point. Reads questions from the shared
# SQLite DB (editable via the web UI), runs the full pipeline,
# classifies by study type, persists records, and delivers.
#
# Usage:
#   Rscript R/run_all.R                 # all enabled questions
#   Rscript R/run_all.R glp1_mash       # one question by id
# ============================================================

args_file <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", args_file[grep("^--file=", args_file)])
# NOTE: `else` must not start a new line at top level -- R's parser rejects a
# dangling else outside braces, which made this whole file fail to parse.
root <- if (length(script_path)) {
  normalizePath(file.path(dirname(script_path), ".."))
} else {
  normalizePath(".")
}
setwd(root)

source("R/00_utils.R")
ensure_packages()
source("R/01_query_builder.R")
source("R/02_fetch.R")
source("R/03_dedup.R")
source("R/04_rank.R")
source("R/05_deliver.R")
source("R/06_classify.R")
source("R/07_db_questions.R")
source("R/08_signals.R")
source("R/09_signals_persist.R")
source("R/10_pharma_intel.R")

settings <- yaml::read_yaml("config/settings.yaml")

con <- DBI::dbConnect(RSQLite::SQLite(), settings$paths$db)
DBI::dbExecute(con, "PRAGMA journal_mode=WAL;")
DBI::dbExecute(con, "PRAGMA busy_timeout=10000;")  # wait out web-read locks
on.exit(DBI::dbDisconnect(con), add = TRUE)

db_init_schema(con, "db/schema.sql")
seed_questions_from_yaml(con, "config/questions.yaml")  # no-op if DB already populated

questions <- load_questions_db(con)
sel <- commandArgs(trailingOnly = TRUE)
if (length(sel)) questions <- Filter(function(q) q$id %in% sel, questions)
if (length(questions) == 0) stop("No matching enabled questions to run.")

run_date <- format(Sys.Date(), "%Y-%m-%d")
per_question <- list()

# RUN_MODE gates the tracks so cron can run a fast signals-only lane at a
# tighter cadence than the full literature run. "Be first" is a latency
# goal: SEC filings / IR feeds / wires move in hours; PubMed moves in days.
#   all (default) : both tracks     — daily full run
#   signals       : signals only    — hourly fast lane
#   lit           : literature only
run_mode <- Sys.getenv("RUN_MODE", "all")
do_lit <- run_mode %in% c("all", "lit")
do_sig <- run_mode %in% c("all", "signals")

# One question failing must not take the run down with it. `.safe()` covers
# individual FETCHERS, but everything after them -- ranking, persistence,
# enrichment, the signals block -- was unguarded, so a single malformed
# question could abort the whole cycle and silently starve every question
# after it in the loop. ACCEPTANCE C3 requires the opposite.
n_failed <- 0L
failed_ids <- character(0)

for (q in questions) {
  message("\n=== ", q$label, " (", q$id, ") ===")
  per_q <- tryCatch({
  new <- data.frame()
  if (do_lit) {
  # --- literature track ---
  queries <- build_all_queries(q)
  raw     <- fetch_question(q, queries, settings)
  message("  [lit] fetched ", nrow(raw), " raw records")
  log_fetch(con, q$id, "lit", attr(raw, "source_counts"))
  raw     <- classify_study_type(raw)
  ranked  <- rank_records(raw, q, settings)
  new     <- persist_records(con, ranked, q$id, settings$ranking$source_priority)
  new     <- rank_records(new, q, settings)
  message("  [lit] ", nrow(new), " new after dedup/state")
  # Unpaywall AFTER dedup/persist: only genuinely-new records are queried,
  # so already-seen DOIs are never re-looked-up on every run.
  new     <- enrich_unpaywall(new, settings)
  update_oa_urls(con, new, q$id)
  # reclassify (and rescore) records that arrived via /api/ingest (external ingestion)
  n_recl <- reclassify_unclassified(con, q$id, q, settings)
  if (n_recl > 0) message("  [lit] reclassified ", n_recl, " ingested record(s)")
  }

  # --- signals track (parallel) ---
  sigcfg  <- load_signal_config(con, q$id)
  sig_new <- data.frame()
  if (do_sig && (length(sigcfg$sources) || length(sigcfg$scrape_targets))) {
    # merge decrypted signal keys into settings for the fetchers
    s_sig <- settings
    s_sig$signal_keys <- sigcfg$api_keys
    sig_raw <- fetch_signals(q, sigcfg, s_sig)
    message("  [sig] fetched ", nrow(sig_raw), " raw signals")
    log_fetch(con, q$id, "signals", attr(sig_raw, "source_counts"))
    sig_rank <- rank_signals(sig_raw, q, settings)
    sig_new  <- persist_signals(con, sig_rank, q$id)
    sig_new  <- rank_signals(sig_new, q, settings)
    message("  [sig] ", nrow(sig_new), " new signals after dedup/state")
  }

  list(label = q$label, recs = new, signals = sig_new, delivery = q$delivery)
  }, error = function(e) {
    n_failed <<- n_failed + 1L
    failed_ids <<- c(failed_ids, q$id)
    message("  [ERROR] question '", q$id, "' failed: ", conditionMessage(e))
    message("  [ERROR] continuing with the remaining questions")
    NULL
  })
  if (!is.null(per_q)) per_question[[q$id]] <- per_q
}

# Fast signals-only lane: skip digest/file/zotero delivery entirely — those
# belong to the full run. Signals reach the user via feeds + the scheduler's
# instant-alert/digest email; rewriting digest files hourly would clobber
# the daily digest with near-empty ones.
if (run_mode != "signals") {
html <- render_digest_html(per_question, run_date)
md   <- render_digest_md(per_question, run_date)

# Email is now handled per-question by the scheduler service (web/scheduler.py),
# which respects each question's own cadence + recipient list. The R engine
# only writes file/zotero outputs here to avoid double-sending.
all_channels <- unique(unlist(lapply(per_question, `[[`, "delivery")))
if ("file" %in% all_channels)  deliver_file(html, md, settings, run_date)
if ("zotero" %in% all_channels) {
  for (id in names(per_question)) {
    qd <- per_question[[id]]
    if ("zotero" %in% qd$delivery) deliver_zotero(qd$recs, id, settings)
  }
}
}

n_new <- sum(vapply(per_question, function(x) nrow(x$recs), 0L))
summary_line <- paste0(n_new, " new records across ", length(per_question),
                       " question(s)",
                       if (n_failed) paste0("; ", n_failed, " failed (",
                                            paste(failed_ids, collapse = ", "), ")") else "")
message("\nDone. ", summary_line)

# Service-level heartbeat: "the engine ran", as distinct from fetch_log's
# "this source returned something". A run that failed every question still
# records last_run without advancing last_ok.
heartbeat(con, "pipeline", ok = (n_failed == 0L),
          detail = paste0("mode=", run_mode, "; ", summary_line),
          error = if (n_failed) paste("failed:", paste(failed_ids, collapse = ", ")) else "")

# Keep the write-ahead log from growing without bound between restarts. The
# three services share one SQLite file, so nothing else checkpoints it.
invisible(tryCatch(DBI::dbGetQuery(con, "PRAGMA wal_checkpoint(TRUNCATE);"),
                   error = function(e) NULL))

if (n_failed > 0L) quit(status = 1L)

# ============================================================
# 09_signals_persist.R — dedup, rank, and persist signals.
# Signals have no DOI; dedup key = source + normalized ext_id.
# Ranking weights recency + confidence + term-overlap relevance,
# with signal-type priority (a trial result > a grant > a patent
# for "is something happening in therapy").
# ============================================================

.norm_extid <- function(x) {
  x <- tolower(trimws(x %||% ""))
  gsub("[^a-z0-9]", "", x)
}

# Confidence as a numeric weight (authoritative ranks above unverified,
# but unverified is NOT dropped — it's a lead, surfaced lower).
.confidence_weight <- function(conf) {
  switch(conf %||% "reported",
         authoritative = 1.0, reported = 0.6, unverified = 0.3, 0.3)
}

# Signal-type priority for "early therapy intelligence".
.SIGNAL_TYPE_PRIORITY <- c(
  trial_result        = 5,   # results before publication — gold
  press_release       = 4,   # company topline — earliest, if true
  ir_alert            = 4,   # company investor-relations alert — earliest legal signal
  sec_filing          = 4,   # 8-K material disclosure
  regulatory          = 4,   # approval / designation
  aggregator          = 4,   # embargoed-research wire (often same-day as pub)
  literature_alert    = 3,   # journal online-first (ahead of PubMed indexing)
  trial_registration  = 3,   # a trial is starting
  conference          = 3,
  institution         = 3,   # institute/funder press about their own work
  trade_press         = 2,   # pharma industry news (fast on readouts)
  grant               = 2,   # work is beginning
  news                = 1,   # general news — downstream, corroboration
  patent              = 1
)

rank_signals <- function(sig, q, settings) {
  if (nrow(sig) == 0) { sig$score <- numeric(0); return(sig) }
  terms <- tolower(unique(unlist(lapply(q$concepts, function(c) c(c$terms, c$mesh)))))
  txt <- tolower(paste(sig$title, sig$summary))
  rel <- vapply(txt, function(t)
    sum(vapply(terms, function(tm) grepl(tm, t, fixed = TRUE), logical(1))) /
      max(length(terms), 1), numeric(1))

  d <- suppressWarnings(as.Date(sig$signal_date))
  span <- max(as.numeric(Sys.Date() - min(d, na.rm = TRUE)), 1)
  recency <- 1 - (as.numeric(Sys.Date() - d) / span)
  recency[is.na(recency)] <- 0.5

  conf <- vapply(sig$confidence, .confidence_weight, numeric(1))
  tprio <- vapply(sig$signal_type, function(t)
    (.SIGNAL_TYPE_PRIORITY[[t]] %||% 1) / 5, numeric(1))

  sig$score <- 2.0 * rel + 1.0 * recency + 1.5 * conf + 1.0 * tprio
  sig[order(-sig$score), , drop = FALSE]
}

# Persist new signals; return only genuinely new ones.
persist_signals <- function(con, sig, question_id) {
  if (nrow(sig) == 0) return(sig)
  sig$dedup_key <- paste0(sig$source, ":", .norm_extid(sig$ext_id))
  sig <- sig[!duplicated(sig$dedup_key), , drop = FALSE]
  existing <- DBI::dbGetQuery(con,
    "SELECT dedup_key FROM signals WHERE question_id = ?",
    params = list(question_id))$dedup_key
  new <- sig[!(sig$dedup_key %in% existing), , drop = FALSE]
  if (nrow(new) == 0) return(new)
  ins <- data.frame(
    dedup_key = new$dedup_key, question_id = question_id,
    signal_type = new$signal_type, source = new$source, ext_id = new$ext_id,
    title = new$title, summary = new$summary, org = new$org,
    signal_date = as.character(new$signal_date), url = new$url,
    confidence = new$confidence, extra = new$extra,
    score = new$score %||% 0, stringsAsFactors = FALSE
  )
  DBI::dbWriteTable(con, "signals", ins, append = TRUE)
  new
}

# Load per-question signal config from the DB (toggles, targets, keys).
load_signal_config <- function(con, question_id) {
  row <- DBI::dbGetQuery(con,
    "SELECT * FROM signal_config WHERE question_id = ?",
    params = list(question_id))
  if (nrow(row) == 0) {
    return(list(sources = list(), min_confidence = "unverified",
                scrape_targets = list(), api_keys = list()))
  }
  keys_enc <- tryCatch(jsonlite::fromJSON(row$api_keys_enc %||% "{}"),
                       error = function(e) list())
  list(
    sources = tryCatch(jsonlite::fromJSON(row$sources %||% "{}"),
                       error = function(e) list()),
    min_confidence = row$min_confidence %||% "unverified",
    feed_categories = tryCatch(jsonlite::fromJSON(row$feed_categories %||% "{}"),
                               error = function(e) list()),
    scrape_targets = tryCatch({
      st <- jsonlite::fromJSON(row$scrape_targets %||% "[]", simplifyDataFrame = FALSE)
      if (is.null(st)) list() else st
    }, error = function(e) list()),
    api_keys = lapply(keys_enc, .decrypt_key)   # from 07_db_questions.R
  )
}

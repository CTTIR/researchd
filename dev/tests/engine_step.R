# ============================================================
# Phase 6 — one real engine cycle, with the network mocked out.
#
# This is the ACTUAL engine code path: the same load_questions_db (so the
# same decrypt seam), classify_study_type, rank_records, persist_records and
# log_fetch that run_all.R calls. Only the seven source fetchers are replaced,
# so no external API is touched and the batch is deterministic.
#
#   Rscript dev/tests/engine_step.R <db> <question_id> <batch>
#     batch = "first"  -> a seeded batch of 5 records
#             "repeat" -> the identical batch again (idempotency check)
#             "empty"  -> every source returns nothing
# ============================================================
args <- commandArgs(trailingOnly = TRUE)
db_path <- args[1]; qid <- args[2]; batch <- if (length(args) > 2) args[3] else "first"

source("R/00_utils.R"); source("R/01_query_builder.R"); source("R/02_fetch.R")
source("R/03_dedup.R"); source("R/04_rank.R"); source("R/06_classify.R")
source("R/07_db_questions.R")

settings <- list(
  sources = list(pubmed = TRUE, europepmc = TRUE, openalex = TRUE,
                 semanticscholar = TRUE, crossref = TRUE,
                 clinicaltrials = TRUE, biorxiv = TRUE),
  ncbi = list(api_key = "", email = ""),
  contact_email = "",
  ranking = list(weight_recency = 1, weight_source = 0.5, weight_relevance = 2,
                 source_priority = list(clinicaltrials = 3, pubmed = 2,
                                        europepmc = 2, semanticscholar = 2,
                                        crossref = 2, biorxiv = 1, openalex = 1)))

row <- function(source, doi, title, type = "", journal = "J",
                abstract = "", date = "2026-08-01") data.frame(
  source = source, ext_id = paste0(source, "-1"), doi = doi, title = title,
  abstract = abstract, authors = "Author A; Author B", journal = journal,
  pub_date = as.Date(date), url = paste0("https://doi.org/", doi),
  type = type, stringsAsFactors = FALSE)

# The seeded batch deliberately contains a cross-source DOI duplicate, items
# in four study-type buckets, and one preprint.
BATCH <- rbind(
  row("pubmed", "10.1/rct", "A randomized controlled trial of semaglutide",
      "Randomized Controlled Trial; Journal Article", "NEJM",
      "semaglutide in steatohepatitis"),
  row("europepmc", "10.1/RCT", "A randomized controlled trial of semaglutide",
      "journal article", "NEJM"),                       # same DOI, other case
  row("pubmed", "10.1/sr", "A systematic review and meta-analysis",
      "Meta-Analysis; Journal Article", "BMJ"),
  row("clinicaltrials", "", "A Study of Resmetirom in NASH",
      "Trial: INTERVENTIONAL", ""),
  row("biorxiv", "10.1/pre", "Preprint: a randomized trial of tirzepatide",
      "Preprint", "bioRxiv (preprint)"))

mock <- function(src) {
  force(src)   # without this every closure captures the loop's LAST value
  function(...) {
    if (batch == "empty") return(.empty_records())
    out <- BATCH[BATCH$source == src, , drop = FALSE]
    if (nrow(out) == 0) .empty_records() else out
  }
}
for (nm in c("pubmed", "europepmc", "openalex", "semanticscholar",
             "crossref", "clinicaltrials", "biorxiv"))
  assign(paste0("fetch_", nm), mock(nm), envir = globalenv())

con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
DBI::dbExecute(con, "PRAGMA journal_mode=WAL;")
DBI::dbExecute(con, "PRAGMA busy_timeout=10000;")
on.exit(DBI::dbDisconnect(con), add = TRUE)
db_init_schema(con, "db/schema.sql")

questions <- load_questions_db(con)
q <- Filter(function(x) x$id == qid, questions)[[1]]

# The decrypted per-question key, straight out of the real seam.
cat("DECRYPTED_KEY=", q$api_keys$pubmed %||% "", "\n", sep = "")
cat("SOURCES_ON=", paste(names(Filter(isTRUE, q$sources)), collapse = ","), "\n", sep = "")

queries <- list(pubmed = "q", europepmc = "q", openalex = list("q"),
                semanticscholar = list("q"), crossref = "q",
                clinicaltrials = "q", biorxiv_match = function(x) TRUE)
raw <- fetch_question(q, queries, settings)
cat("RAW=", nrow(raw), "\n", sep = "")
log_fetch(con, q$id, "lit", attr(raw, "source_counts"))
raw <- classify_study_type(raw)
ranked <- rank_records(raw, q, settings)
new <- persist_records(con, ranked, q$id, settings$ranking$source_priority)
cat("NEW=", nrow(new), "\n", sep = "")
cat("STORED=", DBI::dbGetQuery(con,
    "SELECT COUNT(*) n FROM records WHERE question_id = ?",
    params = list(q$id))$n, "\n", sep = "")
cat("OK\n")

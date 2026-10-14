# ============================================================
# Phase 3 — dedup (R/03_dedup.R) + ranking (R/04_rank.R) on seeded data.
# ============================================================
source("R/00_utils.R")
source("R/03_dedup.R")
source("R/04_rank.R")
source("R/06_classify.R")
source("R/07_db_questions.R")

fail <- 0L
ok <- function(name, cond, detail = "") {
  if (isTRUE(cond)) cat(sprintf("  [PASS] %s\n", name))
  else { cat(sprintf("  [FAIL] %s%s\n", name, if (nzchar(detail)) paste0(" — ", detail) else "")); fail <<- fail + 1L }
}

PRIO <- list(clinicaltrials = 3, pubmed = 2, europepmc = 2, biorxiv = 1, openalex = 1)

mk <- function(source, doi, title, date, abstract = "") data.frame(
  source = source, ext_id = "x", doi = doi, title = title, abstract = abstract,
  authors = "A", journal = "J", pub_date = as.Date(date), url = "u",
  type = "", stringsAsFactors = FALSE)

cat("1. within-batch dedup\n")

# same paper, two sources, same DOI in different surface forms
b <- rbind(
  mk("openalex",  "https://doi.org/10.1000/ABC", "GLP-1 in MASH", "2026-01-10"),
  mk("pubmed",    "10.1000/abc",                 "GLP-1 in MASH", "2026-01-10"))
c1 <- .collapse_batch(b, PRIO)
ok("cross-source DOI duplicate collapses to one row", nrow(c1) == 1, paste(nrow(c1), "rows"))
ok("DOI is normalized (url prefix + case) into one key",
   identical(c1$dedup_key[1], "doi:10.1000/abc"), c1$dedup_key[1])
ok("the higher-priority source survives", identical(c1$source[1], "pubmed"), c1$source[1])

# no DOI -> title+year fallback, punctuation/case insensitive
b <- rbind(
  mk("biorxiv",  "", "Semaglutide, fibrosis: a study", "2026-02-01"),
  mk("openalex", "", "semaglutide fibrosis a study",   "2026-11-30"))
c2 <- .collapse_batch(b, PRIO)
ok("title+year fallback collapses punctuation/case variants", nrow(c2) == 1, paste(nrow(c2), "rows"))
ok("fallback key is ti:<normalized>|<year>",
   grepl("^ti:semaglutide fibrosis a study\\|2026$", c2$dedup_key[1]), c2$dedup_key[1])

# same title, DIFFERENT year -> two distinct records
b <- rbind(mk("openalex", "", "Annual MASH report", "2025-03-01"),
           mk("openalex", "", "Annual MASH report", "2026-03-01"))
ok("same title in different years stays two records", nrow(.collapse_batch(b, PRIO)) == 2)

# a DOI-bearing and a DOI-less copy do NOT collapse (known, deliberate limit)
b <- rbind(mk("pubmed",   "10.1000/xyz", "Resmetirom outcomes", "2026-04-01"),
           mk("openalex", "",            "Resmetirom outcomes", "2026-04-01"))
c3 <- .collapse_batch(b, PRIO)
ok("DOI-bearing vs DOI-less copies stay separate (documented limit)", nrow(c3) == 2)

cat("\n2. seen-state filter against the records table\n")
tmp <- "dev/state/tmp/p3_dedup.sqlite"
unlink(paste0(tmp, c("", "-wal", "-shm")))
con <- DBI::dbConnect(RSQLite::SQLite(), tmp)
DBI::dbExecute(con, "PRAGMA busy_timeout=10000;")
db_init_schema(con, "db/schema.sql")
DBI::dbExecute(con, "INSERT INTO questions(id,label) VALUES('q1','Q1')")

raw1 <- rbind(
  mk("pubmed",   "10.1000/one", "Paper one", "2026-05-01"),
  mk("openalex", "10.1000/two", "Paper two", "2026-05-02"))
prep <- function(x) { x <- classify_study_type(x); x$score <- 0; x }
batch <- prep(raw1)
n1 <- persist_records(con, batch, "q1", PRIO)
ok("first run: both records are new", nrow(n1) == 2, paste(nrow(n1)))
ok("both were written to `records`",
   DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM records")$n == 2)

n2 <- persist_records(con, batch, "q1", PRIO)
ok("re-running the identical batch yields zero new (idempotent)", nrow(n2) == 0, paste(nrow(n2)))
ok("no duplicate rows were written",
   DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM records")$n == 2)

batch2 <- prep(rbind(raw1, mk("pubmed", "10.1000/three", "Paper three", "2026-05-03")))
n3 <- persist_records(con, batch2, "q1", PRIO)
ok("only the genuinely new record comes back", nrow(n3) == 1 && n3$doi == "10.1000/three")
ok("a previously stored record never re-surfaces",
   !("10.1000/one" %in% n3$doi))
DBI::dbDisconnect(con)

cat("\n3. ranking (max recall: order, never drop)\n")
q <- list(id = "q1", label = "Q1", concepts = list(
  list(name = "drug", terms = c("semaglutide", "glp-1"), mesh = character(0)),
  list(name = "disease", terms = c("mash", "steatohepatitis"), mesh = character(0))))
settings <- list(ranking = list(weight_recency = 1, weight_source = 0.5,
                                weight_relevance = 2, source_priority = PRIO))

recs <- rbind(
  mk("openalex", "10.1/a", "Unrelated hepatic imaging note", "2020-01-01"),
  mk("pubmed",   "10.1/b", "Semaglutide in MASH: a trial",   "2026-08-01",
     "semaglutide improves steatohepatitis"),
  mk("biorxiv",  "10.1/c", "GLP-1 receptor biology",         "2026-07-01"))
r <- rank_records(recs, q, settings)
ok("row count is preserved (nothing dropped)", nrow(r) == nrow(recs),
   paste(nrow(recs), "->", nrow(r)))
ok("every input DOI is still present", setequal(r$doi, recs$doi))
ok("scores are strictly ordered descending", !is.unsorted(rev(r$score)))
ok("the on-topic recent PubMed record ranks first", identical(r$doi[1], "10.1/b"),
   paste(r$doi, collapse = " > "))

# NA dates must not crash and must not win
recs_na <- recs; recs_na$pub_date[2] <- as.Date(NA)
r2 <- rank_records(recs_na, q, settings)
ok("an NA pub_date does not crash the ranker", nrow(r2) == 3)
ok("no score is NA", !any(is.na(r2$score)), paste(r2$score, collapse = ", "))

all_na <- recs; all_na$pub_date <- as.Date(rep(NA, 3))
warned <- character(0)
r3 <- withCallingHandlers(
  tryCatch(rank_records(all_na, q, settings), error = function(e) e),
  warning = function(w) { warned <<- c(warned, conditionMessage(w)); invokeRestart("muffleWarning") })
ok("all-NA pub_dates do not error", !inherits(r3, "error"),
   if (inherits(r3, "error")) conditionMessage(r3) else "")
ok("all-NA pub_dates emit no warning into the run log",
   length(warned) == 0, paste(warned, collapse = "; "))
if (!inherits(r3, "error")) {
  ok("all-NA pub_dates still yields finite scores",
     all(is.finite(r3$score)), paste(r3$score, collapse = ", "))
}

# empty input
ok("empty input is returned unchanged", nrow(rank_records(recs[0, ], q, settings)) == 0)

# a question with no concepts must not divide by zero
q0 <- list(id = "q0", label = "Q0", concepts = list())
r4 <- tryCatch(rank_records(recs, q0, settings), error = function(e) e)
ok("a question with no concepts does not error", !inherits(r4, "error"),
   if (inherits(r4, "error")) conditionMessage(r4) else "")
if (!inherits(r4, "error")) ok("scores stay finite with no concepts", all(is.finite(r4$score)))

cat("\n", if (fail == 0L) "ALL DEDUP/RANK CHECKS PASSED" else paste(fail, "FAILURE(S)"), "\n", sep = "")
quit(status = if (fail > 0L) 1L else 0L)

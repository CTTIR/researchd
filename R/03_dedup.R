# ============================================================
# 03_dedup.R
# Cross-source dedup. Dedup key: DOI (normalized) if present, else
# fuzzy title+year. Persistent seen-state lives in the `records` table
# and is applied by persist_records() in 07_db_questions.R.
# ============================================================

.norm_doi <- function(x) {
  x <- tolower(trimws(x %||% ""))
  x <- gsub("^https?://(dx\\.)?doi\\.org/", "", x)
  x
}

.norm_title <- function(x) {
  x <- tolower(x %||% "")
  x <- gsub("[^a-z0-9 ]", " ", x)
  x <- gsub("\\s+", " ", x)
  trimws(x)
}

# Collapse duplicates *within* this batch, preferring richer sources.
.collapse_batch <- function(recs, source_priority) {
  recs$.doi_n <- .norm_doi(recs$doi)
  recs$.title_n <- .norm_title(recs$title)
  recs$.year <- format(recs$pub_date, "%Y")
  # primary key: doi if present else title+year
  recs$dedup_key <- ifelse(nzchar(recs$.doi_n),
                           paste0("doi:", recs$.doi_n),
                           paste0("ti:", recs$.title_n, "|", recs$.year))
  recs$.prio <- vapply(recs$source, function(s)
    source_priority[[s]] %||% 0, numeric(1))
  recs <- recs[order(-recs$.prio), ]
  recs <- recs[!duplicated(recs$dedup_key), ]
  recs[, setdiff(names(recs), c(".doi_n", ".title_n", ".year", ".prio"))]
}

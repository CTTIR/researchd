# Phase 2: the R engine applies db/schema.sql the same way the web service
# does. db_init_schema() splits the file on ";\n" rather than using a real
# SQL parser, so verify it produces an identical schema, twice.
source("R/00_utils.R")
source("R/07_db_questions.R")

tmp <- file.path("dev/state/tmp", "p2_r.sqlite")
unlink(paste0(tmp, c("", "-wal", "-shm")))
con <- DBI::dbConnect(RSQLite::SQLite(), tmp)
DBI::dbExecute(con, "PRAGMA journal_mode=WAL;")
DBI::dbExecute(con, "PRAGMA busy_timeout=10000;")

db_init_schema(con, "db/schema.sql")
db_init_schema(con, "db/schema.sql")   # idempotent?

tabs <- sort(DBI::dbGetQuery(con,
  "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")$name)
idx <- sort(DBI::dbGetQuery(con,
  "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'")$name)
cols <- lapply(tabs, function(t) sort(DBI::dbGetQuery(con,
  sprintf("PRAGMA table_info(%s)", t))$name))
names(cols) <- tabs
mode <- DBI::dbGetQuery(con, "PRAGMA journal_mode")[[1]]

cat("tables:", paste(tabs, collapse=", "), "\n")
cat("indexes:", length(idx), "\n")
cat("journal_mode:", mode, "\n")
writeLines(jsonlite::toJSON(cols, auto_unbox = FALSE),
           "dev/state/tmp/p2_r_cols.json")
DBI::dbDisconnect(con)
cat("R schema application OK\n")

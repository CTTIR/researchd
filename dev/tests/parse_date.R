# ============================================================
# Phase 3 — .parse_date(): every fetcher runs every record through it,
# so an error here is a silent total outage (each fetcher is wrapped in
# .safe(), which converts the error into an empty frame).
# ============================================================
source("R/00_utils.R")
fail <- 0L
ok <- function(name, cond, detail = "") {
  if (isTRUE(cond)) cat(sprintf("  [PASS] %s\n", name))
  else { cat(sprintf("  [FAIL] %s%s\n", name, if (nzchar(detail)) paste0(" — ", detail) else "")); fail <<- fail + 1L }
}
d <- function(x) format(.parse_date(x))

ok("ISO date", identical(d("2026-01-02"), "2026-01-02"))
ok("slashed date", identical(d("2026/03/04"), "2026-03-04"))
ok("ISO timestamp truncates to the date", identical(d("2026-01-02T10:00:00Z"), "2026-01-02"))
ok("'YYYY Mon DD'", identical(d("2026 Jan 15"), "2026-01-15"))
ok("'YYYY Mon' -> first of month", identical(d("2026 Jan"), "2026-01-01"))
ok("'YYYY-MM' -> first of month", identical(d("2026-05"), "2026-05-01"))
ok("bare year -> Jan 1, NOT today's month/day", identical(d("2026"), "2026-01-01"))
ok("unparseable string -> NA", is.na(.parse_date("nonsense")))
ok("empty string -> NA", is.na(.parse_date("")))
ok("NA in -> NA out", is.na(.parse_date(NA)))
ok("NULL -> a single NA date", length(.parse_date(NULL)) == 1 && is.na(.parse_date(NULL)))

# Regression: paste0(character(0), "-01-01") is "-01-01", so an unguarded
# bare-year branch threw on ANY input containing no bare year.
r <- tryCatch(.parse_date("2026-01-02"), error = function(e) e)
ok("a vector with no bare year does not throw", !inherits(r, "error"),
   if (inherits(r, "error")) conditionMessage(r) else "")
r <- tryCatch(.parse_date(character(0)), error = function(e) e)
ok("a zero-length vector does not throw", !inherits(r, "error"),
   if (inherits(r, "error")) conditionMessage(r) else "")
ok("a zero-length vector returns a zero-length Date",
   inherits(r, "Date") && length(r) == 0)

mixed <- .parse_date(c("2026", "2025-12-31", NA, "nonsense", "2026 Feb"))
ok("mixed vector parses element-wise",
   identical(format(mixed), c("2026-01-01", "2025-12-31", NA, NA, "2026-02-01")),
   paste(format(mixed), collapse = ","))
ok("result is a Date vector of the right length",
   inherits(mixed, "Date") && length(mixed) == 5)

cat("\n", if (fail == 0L) "ALL .parse_date CHECKS PASSED" else paste(fail, "FAILURE(S)"), "\n", sep = "")
quit(status = if (fail > 0L) 1L else 0L)

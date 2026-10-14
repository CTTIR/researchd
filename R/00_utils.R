# ============================================================
# 00_utils.R  — shared helpers, loaded first.
# ============================================================

# null / empty coalesce
`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a)) ||
      (is.character(a) && length(a) == 1 && !nzchar(a))) b else a
}

# Robust date parser: handles YYYY-MM-DD, YYYY/MM/DD, "YYYY Mon DD",
# "YYYY Mon", ISO timestamps, and bare years. Never errors, never guesses
# a month or day that was not in the input.
#
# Two traps this deliberately avoids:
#   * paste0(character(0), "-01-01") is "-01-01", NOT character(0) -- the
#     partial-date branches must be guarded by any(), or an input with no
#     bare years feeds as.Date("-01-01") and throws. Every fetcher calls this
#     on every record, and .safe() would turn that into a silent zero-row
#     fetch for the whole source.
#   * as.Date("2026", format = "%Y") returns TODAY's month and day, not
#     Jan 1, so "%Y" must not be in the format list; the bare-year branch
#     below handles it explicitly.
.parse_date <- function(x) {
  if (is.null(x)) return(.as_na_date(1L))
  x <- as.character(x)
  if (length(x) == 0) return(.as_na_date(0L))
  out <- .as_na_date(length(x))
  for (f in c("%Y-%m-%d", "%Y/%m/%d", "%Y %b %d", "%Y %B %d")) {
    miss <- is.na(out)
    if (!any(miss)) break
    out[miss] <- suppressWarnings(as.Date(x[miss], format = f))
  }
  # "YYYY Mon" (no day) -> first of that month
  miss <- is.na(out) & grepl("^[0-9]{4} [A-Za-z]{3,}$", x)
  if (any(miss))
    out[miss] <- suppressWarnings(as.Date(paste0(x[miss], " 01"), format = "%Y %b %d"))
  # "YYYY-MM" (no day) -> first of that month
  miss <- is.na(out) & grepl("^[0-9]{4}[-/][0-9]{1,2}$", x)
  if (any(miss))
    out[miss] <- suppressWarnings(as.Date(paste0(sub("/", "-", x[miss]), "-01"),
                                          format = "%Y-%m-%d"))
  # bare 4-digit year -> Jan 1
  miss <- is.na(out) & grepl("^[0-9]{4}$", x)
  if (any(miss)) out[miss] <- as.Date(paste0(x[miss], "-01-01"))
  out
}

# NA Date vector of a given length, without relying on as.Date(NA) coercion.
.as_na_date <- function(n) structure(rep(NA_real_, n), class = "Date")

# The bare-R install path (README: "Local / bare R, no Docker"). The Docker
# image bakes these in at build time instead, so the two lists must agree --
# dev/tests/audit_completeness.py asserts this list matches the namespaces the
# code actually reaches via `::`. It previously listed `stringdist`, which
# nothing uses any more, and omitted the four signals-track packages, so a
# bare-R install silently under-installed and the signals track failed at
# run time.
REQUIRED_PKGS <- c(
  "yaml", "rentrez", "europepmc", "openalexR", "httr2", "jsonlite",
  "DBI", "RSQLite", "blastula", "htmltools",
  "ctrdata", "nodbi", "rvest", "xml2"
)

ensure_packages <- function(pkgs = REQUIRED_PKGS) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    message("Installing missing packages: ", paste(missing, collapse = ", "))
    install.packages(missing, repos = "https://cloud.r-project.org")
  }
}

# Every R source in the engine must parse. R/run_all.R -- the file cron
# actually invokes -- once contained a dangling `else` at top level, which R
# rejects outside braces, so the entry point failed at PARSE time and the
# engine never ran at all. Nothing else caught it, because every test to that
# point exercised the modules rather than the entry point.
files <- list.files("R", pattern = "[.]R$", full.names = TRUE)
bad <- character(0)
for (f in files) {
  err <- tryCatch({ parse(f); NULL }, error = function(e) conditionMessage(e))
  if (is.null(err)) cat(sprintf("  [PASS] %s\n", f))
  else { cat(sprintf("  [FAIL] %s -> %s\n", f, sub("\n.*", "", err))); bad <- c(bad, f) }
}
# and the entry point must survive being sourced far enough to reach its
# argument handling, not merely parse
cat("\n", length(files), " file(s) checked, ", length(bad), " failure(s)\n", sep = "")
quit(status = if (length(bad)) 1L else 0L)

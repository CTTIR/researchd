# ============================================================
# 05_deliver.R
# Three channels: (1) HTML+MD file, (2) email, (3) Zotero push.
# Each respects the question's `delivery` list and global enables.
# ============================================================

# --- build the digest body (HTML), grouped by study type ------
render_digest_html <- function(per_question, run_date) {
  parts <- c(sprintf("<h1>Research digest &mdash; %s</h1>", run_date))
  for (qd in per_question) {
    parts <- c(parts, sprintf("<h2>%s <small>(%d new)</small></h2>",
                              htmltools::htmlEscape(qd$label), nrow(qd$recs)))
    if (nrow(qd$recs) == 0) {
      parts <- c(parts, "<p><em>No new records this run.</em></p>"); next
    }
    # group into the four study-type sections, in fixed order
    for (stype in STUDY_TYPE_ORDER) {
      sub <- qd$recs[qd$recs$study_type == stype, , drop = FALSE]
      if (nrow(sub) == 0) next
      parts <- c(parts, sprintf("<h3 style='border-bottom:1px solid #ddd'>%s <small>(%d)</small></h3>",
                                STUDY_TYPE_LABEL[[stype]], nrow(sub)))
      rows <- vapply(seq_len(nrow(sub)), function(i) {
        r <- sub[i, ]
        badge <- sprintf("<span style='background:#eee;border-radius:3px;padding:1px 5px;font-size:11px'>%s</span>", r$source)
        pp <- if (isTRUE(r$is_preprint == 1))
          " <span style='background:#fff3cd;border-radius:3px;padding:1px 5px;font-size:11px'>preprint</span>" else ""
        sprintf(
          "<li style='margin-bottom:10px'>%s%s <a href='%s'><strong>%s</strong></a><br>
           <span style='color:#555;font-size:13px'>%s &middot; %s &middot; score %.2f</span></li>",
          badge, pp, r$url, htmltools::htmlEscape(r$title),
          htmltools::htmlEscape(substr(r$authors, 1, 120)), r$pub_date, r$score)
      }, character(1))
      parts <- c(parts, "<ol>", rows, "</ol>")
    }
  }
  paste(parts, collapse = "\n")
}

render_digest_md <- function(per_question, run_date) {
  parts <- c(sprintf("# Research digest — %s\n", run_date))
  for (qd in per_question) {
    parts <- c(parts, sprintf("## %s (%d new)\n", qd$label, nrow(qd$recs)))
    if (nrow(qd$recs) == 0) { parts <- c(parts, "_No new records this run._\n"); next }
    for (stype in STUDY_TYPE_ORDER) {
      sub <- qd$recs[qd$recs$study_type == stype, , drop = FALSE]
      if (nrow(sub) == 0) next
      parts <- c(parts, sprintf("### %s (%d)\n", STUDY_TYPE_LABEL[[stype]], nrow(sub)))
      for (i in seq_len(nrow(sub))) {
        r <- sub[i, ]
        pp <- if (isTRUE(r$is_preprint == 1)) " _(preprint)_" else ""
        parts <- c(parts, sprintf("%d. **[%s]**%s [%s](%s)  \n   %s · %s · score %.2f\n",
                                  i, r$source, pp, r$title, r$url,
                                  substr(r$authors, 1, 120), r$pub_date, r$score))
      }
    }
  }
  paste(parts, collapse = "\n")
}

# --- channel 1: write files -----------------------------------
deliver_file <- function(html, md, settings, run_date) {
  dir.create(settings$paths$digests, showWarnings = FALSE, recursive = TRUE)
  base <- file.path(settings$paths$digests, paste0("digest_", run_date))
  writeLines(html, paste0(base, ".html"))
  writeLines(md, paste0(base, ".md"))
  message("  digest written: ", base, ".{html,md}")
  paste0(base, ".html")
}

# --- channel 2: email via blastula ----------------------------
deliver_email <- function(html, settings, run_date) {
  if (!isTRUE(settings$email$enabled)) return(invisible())
  pw <- Sys.getenv(settings$email$smtp_pw_env)
  if (!nzchar(pw)) { message("  [skip email] no SMTP password in env"); return(invisible()) }
  msg <- blastula::compose_email(body = blastula::md(html))
  creds <- blastula::creds_envvar(
    user = settings$email$smtp_user,
    pass_envvar = settings$email$smtp_pw_env,
    host = settings$email$smtp_host,
    port = settings$email$smtp_port,
    use_ssl = isTRUE(settings$email$use_ssl)
  )
  blastula::smtp_send(
    msg, from = settings$email$from, to = settings$email$to,
    subject = paste("Research digest —", run_date), credentials = creds
  )
  message("  email sent to ", settings$email$to)
}

# --- channel 3: Zotero push (Web API v3) ----------------------
# Creates items per record. Uses DOI when present so Zotero can enrich.
deliver_zotero <- function(recs, question_id, settings) {
  if (!isTRUE(settings$zotero$enabled) || nrow(recs) == 0) return(invisible())
  key <- Sys.getenv(settings$zotero$api_key_env)
  lib <- settings$zotero$library_id
  if (!nzchar(key) || !nzchar(lib)) { message("  [skip zotero] missing key/library_id"); return(invisible()) }
  base <- sprintf("https://api.zotero.org/%ss/%s",
                  settings$zotero$library_type, lib)

  # optional: ensure a collection named after the question
  coll_key <- NULL
  if (isTRUE(settings$zotero$collection_per_question)) {
    coll_key <- .zotero_ensure_collection(base, key, question_id)
  }

  items <- lapply(seq_len(nrow(recs)), function(i) {
    r <- recs[i, ]
    it <- list(
      itemType = if (grepl("Preprint", r$type)) "preprint" else "journalArticle",
      title = r$title,
      DOI = .norm_doi(r$doi),
      url = r$url,
      abstractNote = r$abstract %||% "",
      date = as.character(r$pub_date),
      publicationTitle = r$journal,
      extra = sprintf("source: %s; auto-added by pipeline", r$source)
    )
    if (!is.null(coll_key)) it$collections <- list(coll_key)
    it
  })

  # Zotero accepts up to 50 items per write request
  for (chunk in split(items, ceiling(seq_along(items) / 50))) {
    httr2::request(paste0(base, "/items")) |>
      httr2::req_headers(`Zotero-API-Key` = key, `Content-Type` = "application/json") |>
      httr2::req_body_json(chunk) |>
      httr2::req_perform()
  }
  message("  pushed ", nrow(recs), " items to Zotero")
}

.zotero_ensure_collection <- function(base, key, name) {
  existing <- httr2::request(paste0(base, "/collections")) |>
    httr2::req_headers(`Zotero-API-Key` = key) |>
    httr2::req_perform() |> httr2::resp_body_json()
  for (c in existing) if (isTRUE(c$data$name == name)) return(c$key)
  resp <- httr2::request(paste0(base, "/collections")) |>
    httr2::req_headers(`Zotero-API-Key` = key, `Content-Type` = "application/json") |>
    httr2::req_body_json(list(list(name = name))) |>
    httr2::req_perform() |> httr2::resp_body_json()
  resp$successful[[1]]$key %||% resp$success[[1]] %||% NULL
}

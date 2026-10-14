# ============================================================
# 02_fetch.R
# Fetch from each source, normalize to a common record schema:
#   source, ext_id, doi, title, abstract, authors, journal,
#   pub_date, url, type
# Every fetcher returns a data.frame with these columns (0 rows ok).
# ============================================================

.empty_records <- function() {
  data.frame(
    source = character(), ext_id = character(), doi = character(),
    title = character(), abstract = character(), authors = character(),
    journal = character(), pub_date = as.Date(character()), url = character(),
    type = character(), stringsAsFactors = FALSE
  )
}

# A failed fetch and an empty fetch are NOT the same thing. Both produce a
# zero-row frame, and if the health log cannot tell them apart then a source
# that has been broken for a month looks exactly like a source that has had a
# quiet month -- the single worst failure mode of a surveillance system. The
# failure is recorded on the frame so fetch_question() can pass it through to
# fetch_log().
.safe <- function(expr, label) {
  tryCatch(expr, error = function(e) {
    message(sprintf("  [WARN] %s failed: %s", label, conditionMessage(e)))
    out <- .empty_records()
    attr(out, "fetch_error") <- conditionMessage(e)
    out
  })
}

# --- PubMed via rentrez ---------------------------------------
fetch_pubmed <- function(query, days_back, settings) {
  if (nzchar(settings$ncbi$api_key)) rentrez::set_entrez_key(settings$ncbi$api_key)
  s <- rentrez::entrez_search(
    db = "pubmed", term = query, reldate = days_back,
    datetype = "edat", retmax = 500, use_history = TRUE
  )
  if (s$count == 0) return(.empty_records())
  recs <- rentrez::entrez_summary(db = "pubmed", web_history = s$web_history,
                                  always_return_list = TRUE)
  do.call(rbind, lapply(recs, function(r) {
    doi <- ""
    if (!is.null(r$articleids)) {
      d <- r$articleids$value[r$articleids$idtype == "doi"]
      if (length(d)) doi <- d[1]
    }
    # r$pubtype holds the authoritative MeSH publication types. Join with
    # "; " so the classifier can split them back into structured tags.
    data.frame(
      source = "pubmed", ext_id = r$uid, doi = doi,
      title = r$title %||% "", abstract = "",   # esummary lacks abstract
      authors = paste(vapply(r$authors$name, identity, character(1)), collapse = "; "),
      journal = r$source %||% "",
      pub_date = .parse_date(r$sortpubdate %||% r$epubdate %||% r$pubdate),
      url = paste0("https://pubmed.ncbi.nlm.nih.gov/", r$uid, "/"),
      type = paste(unlist(r$pubtype), collapse = "; "),
      stringsAsFactors = FALSE
    )
  }))
}

# --- Europe PMC via europepmc ---------------------------------
# Scalar field out of one raw Europe PMC hit, always length 1.
.epmc_field <- function(h, name, default = "") {
  v <- h[[name]]
  if (is.null(v) || length(v) == 0) return(default)
  as.character(v)[1]
}

fetch_europepmc <- function(query, days_back, settings) {
  from <- format(Sys.Date() - days_back, "%Y-%m-%d")
  q <- sprintf('(%s) AND (FIRST_PDATE:[%s TO %s])', query, from, format(Sys.Date(), "%Y-%m-%d"))
  # output = "raw" is what carries abstractText. The default "parsed" result
  # set omits that column entirely, so every Europe PMC abstract came back
  # empty -- silently, because `hits$abstractText %||% ""` recycles a
  # length-1 "" across the frame. That starved the relevance term in
  # 04_rank.R (which scores title + abstract) and left digests abstract-less
  # for the source ARCHITECTURE.md names as the abstract-bearing one.
  hits <- europepmc::epmc_search(query = q, limit = 500, verbose = FALSE,
                                 output = "raw")
  if (is.null(hits) || length(hits) == 0) return(.empty_records())
  do.call(rbind, lapply(hits, function(h) {
    doi <- .epmc_field(h, "doi")
    id  <- .epmc_field(h, "id", .epmc_field(h, "pmid"))
    src <- .epmc_field(h, "source")
    pts <- h$pubTypeList$pubType
    data.frame(
      source = "europepmc", ext_id = id, doi = doi,
      title = .epmc_field(h, "title"),
      abstract = .epmc_field(h, "abstractText"),
      authors = .epmc_field(h, "authorString"),
      journal = .epmc_field(h$journalInfo$journal, "title", src),
      pub_date = .parse_date(.epmc_field(h, "firstPublicationDate",
                                         .epmc_field(h, "pubYear", NA_character_))),
      url = if (nzchar(doi)) paste0("https://doi.org/", doi)
            else paste0("https://europepmc.org/article/", src, "/", id),
      type = if (is.null(pts)) "" else paste(unlist(pts), collapse = "; "),
      stringsAsFactors = FALSE
    )
  }))
}

# --- OpenAlex via openalexR -----------------------------------
# Per-concept search, then intersect on works present in ALL concepts.
fetch_openalex <- function(concept_terms, days_back, settings) {
  from <- format(Sys.Date() - days_back, "%Y-%m-%d")
  # openalexR rejects an empty mailto ("'' is not a valid email address") and
  # an unset one drops you out of the polite pool -> 429s. Only send it when
  # settings actually carry a contact address.
  mail <- settings$contact_email %||% ""
  oa <- function(...) {
    a <- list(..., verbose = FALSE)
    if (nzchar(mail)) a$mailto <- mail
    do.call(openalexR::oa_fetch, a)
  }
  per_concept <- lapply(concept_terms, function(terms) {
    search_str <- paste(terms, collapse = " OR ")
    w <- .safe(oa(entity = "works",
                  title_and_abstract.search = search_str,
                  from_publication_date = from,
                  options = list(per_page = 200)), "openalex concept")
    if (is.data.frame(w) && nrow(w)) w$id else character(0)
  })
  common <- Reduce(intersect, per_concept)
  if (length(common) == 0) return(.empty_records())
  w <- oa(entity = "works", id = common)
  if (!is.data.frame(w) || nrow(w) == 0) return(.empty_records())
  data.frame(
    source = "openalex", ext_id = .col(w, "id"),
    doi = gsub("https://doi.org/", "", .col(w, "doi")),
    title = .col(w, "title"), abstract = .col(w, "ab"),
    authors = .authors_col(w), journal = .col(w, "so"),
    pub_date = .parse_date(.col(w, "publication_date", NA_character_)),
    url = .col(w, "id"), type = .col(w, "type"), stringsAsFactors = FALSE
  )
}

# openalexR returns a tibble whose column set varies with what the API had
# for those works: `ab`, `author` and `so` are routinely absent. Reading a
# missing column yields NULL, and a NULL/zero-length column makes data.frame()
# throw "arguments imply differing number of rows" -- which .safe() then turns
# into a silent zero-row OpenAlex fetch. Always return a full-length column.
.col <- function(df, name, default = "") {
  v <- df[[name]]
  if (is.null(v) || length(v) == 0) return(rep(default, nrow(df)))
  v[is.na(v)] <- default
  as.character(v)
}

.authors_col <- function(df) {
  a <- df[["author"]]
  if (is.null(a) || length(a) == 0) return(rep("", nrow(df)))
  vapply(a, function(x)
    if (is.data.frame(x) && "au_display_name" %in% names(x))
      paste(x$au_display_name, collapse = "; ") else "",
    character(1))
}

# --- ClinicalTrials.gov v2 (httr2) ----------------------------
fetch_clinicaltrials <- function(query, days_back, settings) {
  from <- format(Sys.Date() - days_back, "%Y-%m-%d")
  resp <- httr2::request("https://clinicaltrials.gov/api/v2/studies") |>
    httr2::req_url_query(
      `query.term` = query,
      `filter.advanced` = sprintf("AREA[LastUpdatePostDate]RANGE[%s,MAX]", from),
      pageSize = 200, format = "json"
    ) |>
    httr2::req_perform()
  js <- httr2::resp_body_json(resp)
  studies <- js$studies
  if (is.null(studies) || length(studies) == 0) return(.empty_records())
  do.call(rbind, lapply(studies, function(s) {
    p <- s$protocolSection
    nct <- p$identificationModule$nctId %||% ""
    data.frame(
      source = "clinicaltrials", ext_id = nct, doi = "",
      title = p$identificationModule$briefTitle %||% "",
      abstract = p$descriptionModule$briefSummary %||% "",
      authors = p$sponsorCollaboratorsModule$leadSponsor$name %||% "",
      journal = "ClinicalTrials.gov",
      pub_date = .parse_date(p$statusModule$lastUpdatePostDateStruct$date %||%
                               p$statusModule$studyFirstPostDateStruct$date),
      url = paste0("https://clinicaltrials.gov/study/", nct),
      type = paste0("Trial: ", p$designModule$studyType %||% "NA"),
      stringsAsFactors = FALSE
    )
  }))
}

# --- bioRxiv / medRxiv ----------------------------------------
# API returns recent window; we filter client-side via matcher fn.
fetch_biorxiv <- function(matcher_fn, days_back, settings) {
  servers <- c("biorxiv", "medrxiv")
  from <- format(Sys.Date() - days_back, "%Y-%m-%d"); to <- format(Sys.Date(), "%Y-%m-%d")
  out <- .empty_records()
  for (srv in servers) {
    cursor <- 0; more <- TRUE
    while (more) {
      url <- sprintf("https://api.biorxiv.org/details/%s/%s/%s/%d", srv, from, to, cursor)
      js <- .safe(jsonlite::fromJSON(url), paste(srv, "page"))
      coll <- js$collection
      if (is.null(coll) || length(coll) == 0 || !is.data.frame(coll)) break
      keep <- vapply(seq_len(nrow(coll)), function(i)
        matcher_fn(paste(coll$title[i], coll$abstract[i])), logical(1))
      if (any(keep)) {
        c2 <- coll[keep, , drop = FALSE]
        out <- rbind(out, data.frame(
          source = srv, ext_id = c2$doi, doi = c2$doi,
          title = c2$title, abstract = c2$abstract,
          authors = c2$authors, journal = paste0(srv, " (preprint)"),
          pub_date = .parse_date(c2$date), url = paste0("https://doi.org/", c2$doi),
          type = "Preprint", stringsAsFactors = FALSE
        ))
      }
      total <- as.numeric(js$messages$total %||% 0)
      cursor <- cursor + nrow(coll)
      more <- cursor < total
    }
  }
  out
}


# --- Semantic Scholar (free API; optional key for higher limits) -
# Per-concept relevance search + client-side intersect, mirroring the
# OpenAlex approach. A free API key (settings$semanticscholar$api_key,
# obtained by registration) only raises the rate limit; works without.
fetch_semanticscholar <- function(concept_terms, days_back, settings) {
  base <- "https://api.semanticscholar.org/graph/v1/paper/search"
  key  <- settings$semanticscholar$api_key %||% ""
  yr_from <- as.integer(format(Sys.Date() - days_back, "%Y"))
  fields <- "title,abstract,year,publicationDate,externalIds,authors,venue,publicationTypes,url"

  search_one <- function(terms) {
    qstr <- paste(terms, collapse = " ")
    req <- httr2::request(base) |>
      httr2::req_url_query(query = qstr, fields = fields,
                           year = paste0(yr_from, "-"), limit = 100) |>
      httr2::req_retry(max_tries = 3)
    if (nzchar(key)) req <- httr2::req_headers(req, `x-api-key` = key)
    resp <- httr2::req_perform(req)
    js <- httr2::resp_body_json(resp)
    data_list <- js$data %||% list()
    ids <- vapply(data_list, function(p) p$paperId %||% "", character(1))
    stats::setNames(data_list, ids)
  }

  # fetch each concept once, cache results, then intersect on paperId
  cache <- lapply(concept_terms, function(terms) .safe2(search_one(terms)))
  per_concept <- lapply(cache, function(res) if (is.null(res)) character(0) else names(res))
  common <- Reduce(intersect, per_concept)
  common <- common[nzchar(common)]
  if (length(common) == 0) return(.empty_records())

  all_papers <- list()
  for (res in cache) if (!is.null(res)) all_papers <- c(all_papers, res)
  all_papers <- all_papers[!duplicated(names(all_papers))]
  papers <- all_papers[common]

  do.call(rbind, lapply(papers, function(p) {
    if (is.null(p)) return(NULL)
    ext <- p$externalIds %||% list()
    doi <- ext$DOI %||% ""
    pts <- paste(unlist(p$publicationTypes), collapse = "; ")
    data.frame(
      source = "semanticscholar", ext_id = p$paperId %||% "", doi = doi,
      title = p$title %||% "", abstract = p$abstract %||% "",
      authors = paste(vapply(p$authors %||% list(),
                             function(a) a$name %||% "", character(1)), collapse = "; "),
      journal = p$venue %||% "",
      pub_date = .parse_date(p$publicationDate %||% as.character(p$year %||% "")),
      url = p$url %||% (if (nzchar(doi)) paste0("https://doi.org/", doi) else ""),
      type = pts, stringsAsFactors = FALSE
    )
  }))
}

# --- Crossref (free; email -> "polite pool", faster + more reliable) -
# Catches very recent journal articles, sometimes before PubMed indexes
# them. Plain bibliographic query, filtered on indexing date.
fetch_crossref <- function(query, days_back, settings) {
  if (!nzchar(query)) return(.empty_records())
  from <- format(Sys.Date() - days_back, "%Y-%m-%d")
  email <- settings$contact_email %||% ""
  req <- httr2::request("https://api.crossref.org/works") |>
    httr2::req_url_query(
      query.bibliographic = query,
      filter = paste0("from-index-date:", from, ",type:journal-article"),
      rows = 100, sort = "indexed", order = "desc") |>
    httr2::req_retry(max_tries = 3)
  if (nzchar(email))
    req <- httr2::req_headers(req,
      `User-Agent` = sprintf("research-pipeline (mailto:%s)", email))
  resp <- httr2::req_perform(req)
  js <- httr2::resp_body_json(resp)
  items <- js$message$items %||% list()
  if (length(items) == 0) return(.empty_records())
  do.call(rbind, lapply(items, function(it) {
    title <- paste(unlist(it$title), collapse = " ")
    if (!nzchar(title)) return(NULL)
    auth <- ""
    if (!is.null(it$author))
      auth <- paste(vapply(it$author, function(a)
        trimws(paste(a$given %||% "", a$family %||% "")), character(1)), collapse = "; ")
    dp <- it$published$`date-parts`[[1]] %||% it$indexed$`date-parts`[[1]] %||% NULL
    pub_date <- if (!is.null(dp)) .parse_date(paste(dp, collapse = "-")) else as.Date(NA)
    data.frame(
      source = "crossref", ext_id = it$DOI %||% "", doi = it$DOI %||% "",
      title = title, abstract = it$abstract %||% "",
      authors = auth,
      journal = paste(unlist(it$`container-title`), collapse = " "),
      pub_date = pub_date,
      url = if (nzchar(it$DOI %||% "")) paste0("https://doi.org/", it$DOI) else (it$URL %||% ""),
      type = it$type %||% "journal-article", stringsAsFactors = FALSE
    )
  }))
}

# --- Unpaywall enrichment (free; email param required) ---------
# NOT a fetcher — ENRICHES already-collected records that have a DOI
# with a legal open-access full-text URL. The "find AND read" piece:
# the pipeline finds a paper exists; Unpaywall says where to read it
# free, if an OA copy exists. Adds an `oa_url` column (empty if none).
enrich_unpaywall <- function(recs, settings) {
  if (nrow(recs) == 0) { recs$oa_url <- character(0); return(recs) }
  email <- settings$unpaywall$email %||% settings$contact_email %||% ""
  if (is.null(recs$oa_url)) recs$oa_url <- ""
  if (!nzchar(email)) return(recs)
  idx <- which(nzchar(recs$doi))
  for (i in idx) {
    doi <- recs$doi[i]
    url <- sprintf("https://api.unpaywall.org/v2/%s?email=%s",
                   utils::URLencode(doi, reserved = TRUE),
                   utils::URLencode(email, reserved = TRUE))
    res <- .safe2({
      resp <- httr2::request(url) |>
        httr2::req_retry(max_tries = 2) |>
        httr2::req_perform()
      httr2::resp_body_json(resp)
    })
    if (!is.null(res) && isTRUE(res$is_oa)) {
      loc <- res$best_oa_location %||% list()
      recs$oa_url[i] <- loc$url_for_pdf %||% loc$url %||% ""
    }
  }
  recs
}

# small helper: run expr, return NULL on any error (quietly)
.safe2 <- function(expr) tryCatch(expr, error = function(e) NULL)

# --- orchestrate one question across its selected sources -----
# Per-question `sources` (named logical) override global settings;
# per-question `api_keys` (named, decrypted) override global keys.
fetch_question <- function(q, queries, settings) {
  days <- q$from_days_back %||% 7

  # resolve which sources to hit: question-level toggle if present,
  # else fall back to the global settings$sources default.
  src_on <- function(name) {
    qs <- q$sources[[name]]
    if (!is.null(qs)) isTRUE(qs) else isTRUE(settings$sources[[name]])
  }
  # per-question key for a source, else global
  key_for <- function(name, global) {
    k <- q$api_keys[[name]]
    if (!is.null(k) && nzchar(k)) k else global
  }

  # clone settings with question-specific NCBI key if provided
  s_local <- settings
  s_local$ncbi$api_key <- key_for("pubmed", settings$ncbi$api_key %||% "")
  oa_key <- key_for("openalex", "")  # openalexR uses mailto, not key; reserved

  recs <- list()
  if (src_on("pubmed"))
    recs$pubmed <- .safe(fetch_pubmed(queries$pubmed, days, s_local), "pubmed")
  if (src_on("europepmc"))
    recs$epmc <- .safe(fetch_europepmc(queries$europepmc, days, s_local), "europepmc")
  if (src_on("openalex"))
    recs$oa <- .safe(fetch_openalex(queries$openalex, days, s_local), "openalex")
  if (src_on("semanticscholar"))
    recs$s2 <- .safe(fetch_semanticscholar(queries$semanticscholar, days, s_local), "semanticscholar")
  if (src_on("crossref"))
    recs$cr <- .safe(fetch_crossref(queries$crossref, days, s_local), "crossref")
  if (src_on("clinicaltrials"))
    recs$ct <- .safe(fetch_clinicaltrials(queries$clinicaltrials, days, s_local), "clinicaltrials")
  if (src_on("biorxiv"))
    recs$bio <- .safe(fetch_biorxiv(queries$biorxiv_match, days, s_local), "biorxiv")

  out <- do.call(rbind, c(recs, list(make.row.names = FALSE)))
  if (is.null(out)) out <- .empty_records()
  # Per-source health. Each entry carries the row count AND whether the fetch
  # actually succeeded, so fetch_log can record ok=0 for a broken source
  # instead of logging it as a successful fetch that happened to find nothing.
  attr(out, "source_counts") <- lapply(recs, function(x) list(
    n     = nrow(x),
    ok    = is.null(attr(x, "fetch_error")),
    error = attr(x, "fetch_error") %||% ""))
  out
}

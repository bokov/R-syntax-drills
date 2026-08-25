.drillr_main_manifest_url <- paste0(
  "https://raw.githubusercontent.com/bokov/R-syntax-drills/main/",
  "student-assets/question_manifest.csv"
)

.drillr_main_pool_url <- paste0(
  "https://raw.githubusercontent.com/bokov/R-syntax-drills/main/",
  "student-assets/runtime_question_pool.Rmd"
)

read_runtime_manifest <- function(path) {
  if (!file.exists(path)) stop("Question manifest does not exist: ", path)
  read.csv(path, stringsAsFactors = FALSE, na.strings = "")
}

runtime_manifests_equal <- function(old, new) {
  isTRUE(all.equal(old, new, check.attributes = FALSE))
}

download_runtime_asset <- function(url, path, timeout_sec = 15) {
  response <- httr2::request(url) |>
    httr2::req_timeout(timeout_sec) |>
    httr2::req_perform()
  bytes <- httr2::resp_body_raw(response)
  con <- file(path, open = "wb")
  on.exit(close(con), add = TRUE)
  writeBin(bytes, con)
  invisible(path)
}

runtime_pool_item_labels <- function(path) {
  if (!file.exists(path)) stop("Runtime question pool does not exist: ", path)
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  pattern <- "^```\\{r[[:space:]]+([^,}[:space:]]+).*exercise[[:space:]]*=[[:space:]]*TRUE"
  matches <- regexec(pattern, lines, perl = TRUE)
  pieces <- regmatches(lines, matches)
  pieces <- pieces[lengths(pieces) > 1L]
  if (!length(pieces)) return(character())
  vapply(pieces, function(x) x[[2]], character(1))
}

runtime_bank_mismatch <- function(manifest, pool_path) {
  required <- c("item_label", "event", "points")
  missing <- setdiff(required, names(manifest))
  if (length(missing)) {
    stop(
      "Question manifest is missing required column(s): ",
      paste(missing, collapse = ", "), "."
    )
  }

  manifest_labels <- as.character(manifest$item_label[
    manifest$event == "exercise_result" & manifest$points > 0
  ])
  pool_labels <- runtime_pool_item_labels(pool_path)

  if (anyDuplicated(manifest_labels)) {
    stop("Question manifest contains duplicate scored item_label values.")
  }
  if (anyDuplicated(pool_labels)) {
    stop("Runtime question pool contains duplicate exercise labels.")
  }

  list(
    manifest_only = setdiff(manifest_labels, pool_labels),
    pool_only = setdiff(pool_labels, manifest_labels),
    usable = intersect(manifest_labels, pool_labels)
  )
}

runtime_bank_warning <- function(mismatch) {
  if (!length(mismatch$manifest_only) && !length(mismatch$pool_only)) return("")

  manifest_only <- if (length(mismatch$manifest_only)) {
    paste(mismatch$manifest_only, collapse = ", ")
  } else {
    "none"
  }
  pool_only <- if (length(mismatch$pool_only)) {
    paste(mismatch$pool_only, collapse = ", ")
  } else {
    "none"
  }

  paste0(
    "Drillr content warning - please copy and paste this entire message into a Teams message ",
    "to your course instructor. The question manifest and drill file disagree. ",
    "Manifest-only item_label(s): ", manifest_only, ". ",
    "Rmd-only item_label(s): ", pool_only, ". ",
    "Drillr will keep going using only item_label(s) present in both files."
  )
}

runtime_bank_cache_dir <- function(create = TRUE) {
  preferred <- tools::R_user_dir("drillr", "cache")
  path <- file.path(preferred, "runtime-bank")
  if (isTRUE(create) && !dir.exists(path)) {
    ok <- dir.create(path, recursive = TRUE, showWarnings = FALSE)
    if (!isTRUE(ok) && !dir.exists(path)) {
      path <- file.path(tempdir(), "drillr-runtime-bank")
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
    }
  }
  path
}

atomic_replace_runtime_asset <- function(source, target) {
  dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile("runtime-asset-", tmpdir = dirname(target))
  on.exit(unlink(tmp), add = TRUE)
  if (!file.copy(source, tmp, overwrite = TRUE)) {
    stop("Could not stage updated drill content.")
  }
  if (file.exists(target)) unlink(target)
  if (!file.rename(tmp, target)) {
    stop("Could not replace cached drill content.")
  }
  invisible(target)
}

runtime_bank_from_pair <- function(manifest_path, pool_path, updated = FALSE, notice = "") {
  manifest <- read_runtime_manifest(manifest_path)
  mismatch <- runtime_bank_mismatch(manifest, pool_path)
  warning <- runtime_bank_warning(mismatch)
  usable_manifest <- manifest[manifest$item_label %in% mismatch$usable, , drop = FALSE]

  list(
    manifest_path = normalizePath(manifest_path, mustWork = TRUE),
    pool_path = normalizePath(pool_path, mustWork = TRUE),
    manifest = usable_manifest,
    mismatch = mismatch,
    warning = warning,
    notice = notice,
    updated = isTRUE(updated)
  )
}

refresh_runtime_bank <- function(
  bundled_manifest_path = "question_manifest.csv",
  bundled_pool_path = "runtime_question_pool.Rmd",
  cache_dir = runtime_bank_cache_dir(),
  manifest_url = .drillr_main_manifest_url,
  pool_url = .drillr_main_pool_url,
  downloader = download_runtime_asset,
  force = FALSE
) {
  cached_manifest <- file.path(cache_dir, "question_manifest.csv")
  cached_pool <- file.path(cache_dir, "runtime_question_pool.Rmd")

  use_cache <- file.exists(cached_manifest) && file.exists(cached_pool)
  current_manifest <- if (use_cache) cached_manifest else bundled_manifest_path
  current_pool <- if (use_cache) cached_pool else bundled_pool_path

  current_exists <- file.exists(current_manifest) && file.exists(current_pool)
  if (!current_exists && !isTRUE(force)) force <- TRUE

  incoming <- tempfile("drillr-runtime-")
  dir.create(incoming)
  on.exit(unlink(incoming, recursive = TRUE), add = TRUE)
  remote_manifest_path <- file.path(incoming, "question_manifest.csv")

  manifest_fetch <- tryCatch({
    downloader(manifest_url, remote_manifest_path, timeout_sec = 15)
    TRUE
  }, error = function(e) e)

  if (inherits(manifest_fetch, "error")) {
    if (!current_exists) {
      stop(
        "Could not download the question manifest and no local drill content is available: ",
        conditionMessage(manifest_fetch)
      )
    }
    return(runtime_bank_from_pair(
      current_manifest,
      current_pool,
      updated = FALSE,
      notice = paste(
        "Drillr could not check GitHub for updated questions and is using its current local copy:",
        conditionMessage(manifest_fetch)
      )
    ))
  }

  remote_manifest <- read_runtime_manifest(remote_manifest_path)
  changed <- isTRUE(force) || !current_exists
  if (!changed) {
    local_manifest <- tryCatch(
      read_runtime_manifest(current_manifest),
      error = function(e) NULL
    )
    changed <- is.null(local_manifest) ||
      !runtime_manifests_equal(local_manifest, remote_manifest)
  }

  if (!changed) {
    return(runtime_bank_from_pair(current_manifest, current_pool, updated = FALSE))
  }

  remote_pool_path <- file.path(incoming, "runtime_question_pool.Rmd")
  downloader(pool_url, remote_pool_path, timeout_sec = 30)

  # Parse and reconcile the pair before replacing the working copy. Mismatched
  # IDs are not fatal; the returned manifest is restricted to their intersection.
  runtime_bank_from_pair(remote_manifest_path, remote_pool_path, updated = TRUE)

  atomic_replace_runtime_asset(remote_manifest_path, cached_manifest)
  atomic_replace_runtime_asset(remote_pool_path, cached_pool)

  runtime_bank_from_pair(cached_manifest, cached_pool, updated = TRUE)
}

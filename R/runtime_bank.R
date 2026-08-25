.drillr_main_manifest_url <- paste0(
  "https://raw.githubusercontent.com/bokov/R-syntax-drills/main/",
  "student-assets/question_manifest.csv"
)

.drillr_main_pool_url <- paste0(
  "https://raw.githubusercontent.com/bokov/R-syntax-drills/main/",
  "student-assets/runtime_question_pool.Rmd"
)

# Runtime bank reading and validation ----------------------------------------

#' Read a runtime question manifest
#'
#' Loads the runtime manifest CSV using the string and missing-value conventions
#' expected by the hosted Shiny client.
#'
#' @param path Path to a runtime question-manifest CSV.
#' @return A data frame containing the manifest.
#' @details Called by `runtime_bank_from_pair()` and `refresh_runtime_bank()`.
#'   It has no within-repo function dependencies.
read_runtime_manifest <- function(path) {
  if (!file.exists(path)) stop("Question manifest does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "")
}

#' Compare two parsed runtime manifests
#'
#' Determines whether the remote and current manifests have equal content while
#' ignoring data-frame attributes, which decides whether the question pool also
#' needs refreshing.
#'
#' @param old Current manifest data frame.
#' @param new Candidate remote manifest data frame.
#' @return A single logical value indicating content equality.
#' @details Called only by `refresh_runtime_bank()`. It has no within-repo
#'   function dependencies.
runtime_manifests_equal <- function(old, new) {
  isTRUE(all.equal(old, new, check.attributes = FALSE))
}

#' Download one runtime-bank asset
#'
#' Retrieves a manifest or question pool over HTTP and writes the raw response
#' bytes to the requested local path.
#'
#' @param url Asset URL.
#' @param path Destination file path.
#' @param timeout_sec HTTP request timeout in seconds.
#' @return Invisibly, `path` after writing the asset.
#' @details Used as the default `downloader` by `refresh_runtime_bank()`; tests
#'   replace it with local-copy helpers. It has no within-repo dependencies.
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

#' Extract exercise labels from a runtime question pool
#'
#' Reads the runtime Rmd and extracts labels from chunks marked
#' `exercise=TRUE`, providing the executable ID set used to reconcile the pool
#' with its manifest.
#'
#' @param path Path to the runtime question-pool Rmd.
#' @return A character vector of exercise chunk labels, possibly empty.
#' @details Called only by `runtime_bank_mismatch()`. It has no within-repo
#'   function dependencies.
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

#' Compare manifest IDs with runtime-pool exercise IDs
#'
#' Validates required manifest columns and duplicate IDs, then identifies labels
#' present only in the manifest, only in the Rmd, or in both so the client can
#' continue safely with the intersection.
#'
#' @param manifest Parsed runtime manifest.
#' @param pool_path Path to the matching runtime question pool.
#' @return A list with `manifest_only`, `pool_only`, and `usable` label vectors.
#' @details Called only by `runtime_bank_from_pair()`. Depends on
#'   `runtime_pool_item_labels()`.
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

#' Build the student-facing warning for a bank mismatch
#'
#' Converts manifest/pool ID differences to the warning shown in the hosted
#' tutorial while allowing the usable intersection to continue running.
#'
#' @param mismatch List returned by `runtime_bank_mismatch()`.
#' @return An empty string when IDs agree, otherwise a descriptive warning.
#' @details Called only by `runtime_bank_from_pair()`. It has no within-repo
#'   function dependencies.
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

# Runtime cache ---------------------------------------------------------------

#' Locate a writable runtime-bank cache directory
#'
#' Prefers Drillr's per-user R cache directory and falls back to the current R
#' session's temporary directory if the preferred location cannot be created.
#'
#' @param create If `TRUE`, create the selected cache directory when needed.
#' @return A length-one character path to the runtime-bank cache directory.
#' @details Used by `refresh_runtime_bank()` through its default `cache_dir`.
#'   It has no within-repo function dependencies.
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

#' Replace one cached runtime asset through a staged file
#'
#' Copies an incoming asset to a temporary file beside the target and renames it
#' into place, reducing the chance that the working cache contains a partial
#' download.
#'
#' @param source Path to the validated incoming asset.
#' @param target Cache path to replace.
#' @return Invisibly, `target` after replacement.
#' @details Called twice by `refresh_runtime_bank()` after validating a new
#'   manifest/pool pair. It has no within-repo function dependencies.
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

# Bank objects and refresh ----------------------------------------------------

#' Construct a validated hosted runtime bank from two files
#'
#' Reads and reconciles a manifest/pool pair, restricts the manifest to usable
#' IDs, and packages the paths and mismatch/status metadata consumed by
#' `index.Rmd` and `app.R`.
#'
#' @param manifest_path Path to the runtime manifest CSV.
#' @param pool_path Path to the runtime question-pool Rmd.
#' @param updated Whether this pair was newly downloaded during the current
#'   refresh.
#' @param notice Optional informational message shown to the student.
#' @return A list containing normalized paths, usable `manifest`, `mismatch`,
#'   `warning`, `notice`, and `updated`.
#' @details Called by `refresh_runtime_bank()`, directly by the setup fallback in
#'   `index.Rmd`, and by `tests/testthat/test-runtime-bank.R`. Depends on
#'   `read_runtime_manifest()`, `runtime_bank_mismatch()`, and
#'   `runtime_bank_warning()`.
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

#' Refresh the hosted client's runtime question bank
#'
#' Chooses cached or bundled files as the current fallback, downloads the remote
#' manifest, downloads the matching pool only when needed, validates the pair
#' before replacing cache files, and falls back to current local content with a
#' notice when remote checks fail.
#'
#' @param bundled_manifest_path Path to the manifest bundled/deployed beside the
#'   hosted tutorial.
#' @param bundled_pool_path Path to the bundled/deployed question pool.
#' @param cache_dir Directory for the mutable downloaded pair.
#' @param manifest_url Published manifest URL.
#' @param pool_url Published question-pool URL.
#' @param downloader Function accepting `url`, `path`, and `timeout_sec`.
#' @param force If `TRUE`, force a pool download regardless of manifest equality.
#' @return A validated runtime-bank list representing the selected current pair.
#' @details Called by `app.R` to prepare the hosted tutorial and exercised by
#'   `tests/testthat/test-runtime-bank.R`. Depends on `runtime_bank_cache_dir()`
#'   through its default, `download_runtime_asset()` through its default,
#'   `read_runtime_manifest()`, `runtime_manifests_equal()`,
#'   `runtime_bank_from_pair()`, and `atomic_replace_runtime_asset()`.
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
  pool_fetch <- tryCatch({
    downloader(pool_url, remote_pool_path, timeout_sec = 30)
    TRUE
  }, error = function(e) e)

  if (inherits(pool_fetch, "error")) {
    if (!current_exists) {
      stop(
        "Drillr found a question manifest but could not download its drill file and no local drill content is available: ",
        conditionMessage(pool_fetch)
      )
    }
    return(runtime_bank_from_pair(
      current_manifest,
      current_pool,
      updated = FALSE,
      notice = paste(
        "Drillr found an updated question manifest but could not download the matching drill file; it is using its current local copy:",
        conditionMessage(pool_fetch)
      )
    ))
  }

  # Parse and reconcile the pair before replacing the working copy. Mismatched
  # IDs are not fatal; the returned manifest is restricted to their intersection.
  runtime_bank_from_pair(remote_manifest_path, remote_pool_path, updated = TRUE)

  atomic_replace_runtime_asset(remote_manifest_path, cached_manifest)
  atomic_replace_runtime_asset(remote_pool_path, cached_pool)

  runtime_bank_from_pair(cached_manifest, cached_pool, updated = TRUE)
}

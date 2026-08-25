# Canonical question-bank and assignment-manifest helpers.
#
# Only question-bank/ defines canonical questions. Question identity is the
# item_label; changing wording under an existing item_label does not create a
# different question.

# Utility helpers -------------------------------------------------------------

#' Substitute a fallback for a null or empty value
#'
#' Provides the small null-coalescing operation used while parsing optional
#' question metadata.
#'
#' @param x Value to return unless it is `NULL` or length zero.
#' @param y Fallback value.
#' @return `y` when `x` is `NULL` or empty; otherwise `x`.
#' @details Called by `parse_question_chunk()`. No other within-repository caller
#'   was found.
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Metadata parsing ------------------------------------------------------------

# Older bank files predate explicit topic metadata. Keep their stable item-label
# families as a compatibility registry so every canonical question has a topic
# without creating a very large mechanical edit to those source banks.
# Explicit topic= metadata on a question always takes precedence.

#' Infer a topic for a legacy permanent item label
#'
#' Maps known pre-metadata item-label families to their curriculum topics so old
#' canonical banks can be scanned without mechanically adding `topic=` to every
#' existing chunk.
#'
#' @param item_label Permanent canonical question label.
#' @return The matched topic as a length-one character value, or `NULL` when no
#'   compatibility rule matches.
#' @details Called only by `parse_question_chunk()`. It has no within-repo
#'   function dependencies.
legacy_question_topic <- function(item_label) {
  rules <- c(
    "^vector_c[0-9]+$" = "vector_creation",
    "^vector_e[0-9]+$" = "vector_indexing",
    "^df_[rcb][0-9]+$" = "dataframe_indexing",
    "^df_s[0-9]+$" = "subset_function",
    "^expr_d[0-9]+$" = "expression_decomposition"
  )

  matched <- names(rules)[vapply(
    names(rules),
    function(pattern) grepl(pattern, item_label, perl = TRUE),
    logical(1)
  )]

  if (!length(matched)) return(NULL)
  if (length(matched) > 1) {
    stop("Multiple legacy topic rules match item_label: ", item_label, ".")
  }
  unname(rules[[matched]])
}

#' Extract one option value from an R Markdown chunk header
#'
#' Finds a named chunk option, trims it, and removes matching surrounding quotes
#' so later metadata parsers receive a simple character value.
#'
#' @param header Chunk-header text after the opening `{r` portion.
#' @param option Option name to extract.
#' @return The option value as character, or `NULL` when the option is absent.
#' @details Called only by `parse_question_chunk()`. It has no within-repo
#'   function dependencies.
chunk_option_value <- function(header, option) {
  pattern <- paste0(
    "(?:^|,)\\s*",
    option,
    "\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^,}]+)"
  )
  match <- regmatches(header, regexpr(pattern, header, perl = TRUE))
  if (!length(match) || identical(match, "")) return(NULL)

  value <- sub(
    paste0("^(?:^|,)\\s*", option, "\\s*=\\s*"),
    "",
    match,
    perl = TRUE
  )
  value <- trimws(value)

  if (
    nchar(value) >= 2 &&
    substr(value, 1, 1) %in% c("\"", "'") &&
    substr(value, nchar(value), nchar(value)) == substr(value, 1, 1)
  ) {
    value <- substr(value, 2, nchar(value) - 1)
  }

  value
}

#' Parse logical question metadata
#'
#' Accepts common textual boolean spellings used in chunk metadata and provides
#' a caller-supplied default when the option is absent or blank.
#'
#' @param value Metadata value to interpret, or `NULL`.
#' @param default Logical value used for missing/blank metadata.
#' @return A single logical value.
#' @details Called only by `parse_question_chunk()` for `starter_question`.
#'   It has no within-repo function dependencies.
parse_bool_metadata <- function(value, default = FALSE) {
  if (is.null(value) || !nzchar(trimws(value))) return(default)
  value <- tolower(trimws(value))
  if (value %in% c("true", "1", "yes")) return(TRUE)
  if (value %in% c("false", "0", "no")) return(FALSE)
  stop("Invalid logical metadata value: ", value, ".")
}

# Question-chunk parsing ------------------------------------------------------

#' Parse one R Markdown line as canonical question metadata
#'
#' Recognizes labeled R chunks that represent an exercise or carry explicit or
#' legacy question metadata, validates points/starter metadata, and converts the
#' chunk header to one canonical manifest record.
#'
#' @param line Candidate R Markdown line.
#' @param source_file Source file used for diagnostics and manifest provenance.
#' @param source_line One-based source line number.
#' @return A one-row question metadata data frame, or `NULL` when the line is not
#'   a canonical question chunk.
#' @details Called only by `record_question_block()`. Depends on
#'   `chunk_option_value()`, `%||%`, `legacy_question_topic()`, and
#'   `parse_bool_metadata()`.
parse_question_chunk <- function(line, source_file, source_line) {
  if (!grepl("^```\\{r(?:\\s|,)", line)) return(NULL)

  header <- sub("^```\\{r\\s*", "", line)
  header <- sub("}\\s*$", "", header)
  first <- trimws(sub(",.*$", "", header))
  label <- if (nzchar(first) && !grepl("=", first, fixed = TRUE)) first else NA_character_

  exercise <- identical(tolower(chunk_option_value(header, "exercise") %||% ""), "true")
  topic <- chunk_option_value(header, "topic")
  points_text <- chunk_option_value(header, "points")
  starter_text <- chunk_option_value(header, "starter_question")

  if (is.na(label)) {
    if (exercise || !is.null(topic) || !is.null(points_text) || !is.null(starter_text)) {
      stop("Question chunk without a label in ", source_file, ":", source_line, ".")
    }
    return(NULL)
  }

  legacy_topic <- legacy_question_topic(label)

  if (
    !exercise &&
    is.null(topic) &&
    is.null(legacy_topic) &&
    is.null(points_text) &&
    is.null(starter_text)
  ) return(NULL)

  if (is.null(topic) || !nzchar(trimws(topic))) {
    topic <- legacy_topic %||% "unassigned"
  }

  points <- if (is.null(points_text) || !nzchar(trimws(points_text))) {
    if (exercise) 1 else 0
  } else {
    suppressWarnings(as.numeric(points_text))
  }
  if (length(points) != 1 || is.na(points) || !is.finite(points) || points < 0) {
    stop("Invalid points metadata for ", label, " in ", source_file, ":", source_line, ".")
  }

  data.frame(
    item_label = label,
    event = if (exercise) "exercise_result" else "question_submission",
    topic = topic,
    points = points,
    starter_question = parse_bool_metadata(starter_text, FALSE),
    source_file = source_file,
    source_line = source_line,
    stringsAsFactors = FALSE
  )
}

#' Record the single canonical question inside a source block
#'
#' Scans a bounded set of lines for question chunks, requires exactly one when a
#' question is present, validates an optional explicit marker ID, and records the
#' full source block boundaries for later player extraction.
#'
#' @param lines Character vector containing one candidate question block.
#' @param source_file Source file path.
#' @param start_line One-based first source line represented by `lines`.
#' @param end_line One-based last source line represented by `lines`.
#' @param marker_id Optional ID declared by an explicit question marker.
#' @return A one-row manifest record with `source_line` and `source_end_line`, or
#'   `NULL` when the block contains no question chunk.
#' @details Called by `extract_explicit_question_blocks()` and
#'   `extract_legacy_question_blocks()`. Depends on `parse_question_chunk()`.
record_question_block <- function(lines, source_file, start_line, end_line, marker_id = NULL) {
  found <- lapply(seq_along(lines), function(i) {
    parse_question_chunk(lines[[i]], source_file, start_line + i - 1L)
  })
  found <- Filter(Negate(is.null), found)

  if (!length(found)) return(NULL)
  if (length(found) != 1L) {
    stop(
      "Question block in ", source_file, ":", start_line, "-", end_line,
      " contains ", length(found), " question chunks; expected exactly one."
    )
  }

  record <- found[[1]]
  if (!is.null(marker_id) && !identical(marker_id, record$item_label)) {
    stop(
      "Question marker '", marker_id, "' does not match chunk label '",
      record$item_label, "' in ", source_file, ":", start_line, "."
    )
  }

  record$source_line <- start_line
  record$source_end_line <- end_line
  record
}

# Question-block extraction ---------------------------------------------------

#' Extract explicitly marked canonical question blocks
#'
#' Finds `<!-- question: ID --> ... <!-- /question -->` regions, rejects
#' unclosed/nested markers, and records exactly one canonical question from each
#' marked block.
#'
#' @param lines Complete source file as a character vector.
#' @param source_file Source file path used in diagnostics/provenance.
#' @return A data frame of question records, or `NULL` when the file contains no
#'   explicit question markers.
#' @details Called only by `extract_question_records()`. Depends on
#'   `record_question_block()`.
extract_explicit_question_blocks <- function(lines, source_file) {
  begin_pattern <- "^<!--\\s*question:\\s*([A-Za-z0-9._-]+)\\s*-->\\s*$"
  end_pattern <- "^<!--\\s*/question\\s*-->\\s*$"
  begins <- grep(begin_pattern, lines, perl = TRUE)
  if (!length(begins)) return(NULL)

  records <- list()
  for (begin in begins) {
    marker_id <- sub(begin_pattern, "\\1", lines[[begin]], perl = TRUE)
    ends <- which(seq_along(lines) > begin & grepl(end_pattern, lines, perl = TRUE))
    if (!length(ends)) {
      stop("Unclosed question marker '", marker_id, "' in ", source_file, ":", begin, ".")
    }
    end <- ends[[1]]
    if (any(begins > begin & begins < end)) {
      stop("Nested question markers are not allowed in ", source_file, ".")
    }

    body_start <- begin + 1L
    body_end <- end - 1L
    body <- if (body_end >= body_start) lines[body_start:body_end] else character()
    record <- record_question_block(body, source_file, body_start, body_end, marker_id)
    if (is.null(record)) {
      stop("Question marker '", marker_id, "' contains no question chunk in ", source_file, ".")
    }
    records[[length(records) + 1L]] <- record
  }

  do.call(rbind, records)
}

# Compatibility for existing bank/assignment files created before explicit
# markers. A level-2 section containing exactly one question chunk is treated
# as one question block. New or modified bank questions should use markers.

#' Extract legacy heading-delimited question blocks
#'
#' Treats each level-2 Markdown section as a candidate question block for older
#' bank files that predate explicit question markers.
#'
#' @param lines Complete source file as a character vector.
#' @param source_file Source file path used in diagnostics/provenance.
#' @return A data frame of question records, or `NULL` when no section contains a
#'   canonical question.
#' @details Called only by `extract_question_records()` when explicit markers are
#'   absent. Depends on `record_question_block()`.
extract_legacy_question_blocks <- function(lines, source_file) {
  headings <- grep("^##\\s+", lines, perl = TRUE)
  records <- list()

  for (i in seq_along(headings)) {
    start <- headings[[i]]
    end <- if (i < length(headings)) headings[[i + 1L]] - 1L else length(lines)
    record <- record_question_block(lines[start:end], source_file, start, end)
    if (!is.null(record)) records[[length(records) + 1L]] <- record
  }

  if (!length(records)) return(NULL)
  do.call(rbind, records)
}

#' Extract canonical question records from one R Markdown file
#'
#' Reads a bank or assignment file, prefers explicit marked blocks when present,
#' and otherwise falls back to the legacy level-2-section parser.
#'
#' @param path Path to the Rmd file to scan.
#' @return A data frame of question records, or `NULL` when none are found.
#' @details Called by `scan_question_bank()` and `validate_assignment_file()`.
#'   Depends on `extract_explicit_question_blocks()` and
#'   `extract_legacy_question_blocks()`.
extract_question_records <- function(path) {
  lines <- readLines(path, warn = FALSE)
  explicit <- extract_explicit_question_blocks(lines, path)
  if (!is.null(explicit)) return(explicit)
  extract_legacy_question_blocks(lines, path)
}

# Manifest construction -------------------------------------------------------

#' Create an empty canonical question manifest
#'
#' Supplies the stable zero-row schema used when scanning no files or files with
#' no recognized questions.
#'
#' @return A zero-row data frame with canonical metadata and source-location
#'   columns.
#' @details Called only by `scan_question_bank()`. It has no within-repo function
#'   dependencies.
empty_manifest <- function() {
  data.frame(
    item_label = character(),
    event = character(),
    topic = character(),
    points = numeric(),
    starter_question = logical(),
    source_file = character(),
    source_line = integer(),
    source_end_line = integer(),
    stringsAsFactors = FALSE
  )
}

#' Scan canonical bank files into one validated manifest
#'
#' Extracts records from every source file, combines them, rejects duplicate
#' permanent IDs, and warns about questions whose topic remains unassigned.
#'
#' @param files Character vector of question-bank Rmd paths.
#' @return A canonical question manifest data frame.
#' @details Called by `build_question_bank_manifest()` and
#'   `review_question_bank()`, and directly by question-manifest/player-builder
#'   tests. Depends on `extract_question_records()` and `empty_manifest()`.
scan_question_bank <- function(files) {
  if (!length(files)) return(empty_manifest())
  items <- lapply(files, extract_question_records)
  items <- Filter(Negate(is.null), items)
  if (!length(items)) return(empty_manifest())

  manifest <- do.call(rbind, items)
  rownames(manifest) <- NULL

  duplicate_labels <- unique(manifest$item_label[duplicated(manifest$item_label)])
  if (length(duplicate_labels)) {
    stop(
      "Duplicate canonical question label(s): ",
      paste(duplicate_labels, collapse = ", "),
      "."
    )
  }

  unassigned <- manifest$item_label[manifest$topic == "unassigned"]
  if (length(unassigned)) {
    warning(
      "Question(s) without topic metadata were assigned topic 'unassigned': ",
      paste(unassigned, collapse = ", "),
      call. = FALSE
    )
  }

  manifest
}

#' List canonical question-bank R Markdown sources
#'
#' Recursively finds and sorts Rmd files beneath the canonical bank directory.
#'
#' @param root Repository root.
#' @param bank_dir Canonical bank directory relative to `root`.
#' @return A sorted character vector of full source paths, or `character()` when
#'   the bank directory does not exist.
#' @details Called by `build_question_bank_manifest()` and
#'   `review_question_bank()`. It has no within-repo function dependencies.
question_bank_source_files <- function(root = ".", bank_dir = "question-bank") {
  bank_path <- file.path(root, bank_dir)
  if (!dir.exists(bank_path)) return(character())
  sort(list.files(
    bank_path,
    pattern = "\\.[Rr]md$",
    recursive = TRUE,
    full.names = TRUE
  ))
}

#' Build and write the complete canonical question-bank manifest
#'
#' Discovers canonical source files, scans and validates their question records,
#' writes the authoring manifest CSV, and returns the in-memory manifest for
#' downstream build/synchronization steps.
#'
#' @param root Repository root.
#' @param bank_dir Canonical bank directory relative to `root`.
#' @param output Destination canonical-bank manifest CSV.
#' @return Invisibly, the canonical question-bank manifest data frame.
#' @details Called by `build_player_assets()`, `build_question_manifest()`,
#'   `scripts/06_sync_question_bank.R`, and associated tests. Depends on
#'   `question_bank_source_files()` and `scan_question_bank()`.
build_question_bank_manifest <- function(
  root = ".",
  bank_dir = "question-bank",
  output = "question_bank_manifest.csv"
) {
  files <- question_bank_source_files(root, bank_dir)
  if (!length(files)) {
    stop("Canonical question-bank directory contains no .Rmd files: ", bank_dir, ".")
  }
  manifest <- scan_question_bank(files)
  if (!nrow(manifest)) stop("Canonical question bank contains no questions.")
  write.csv(manifest, output, row.names = FALSE, na = "")
  message("Canonical question-bank manifest written to ", output, ".")
  invisible(manifest)
}

# Assignment-manifest validation ---------------------------------------------

#' Validate an assignment Rmd against the canonical question bank
#'
#' Extracts question blocks from an assignment file, rejects duplicate labels,
#' and verifies that every assigned label exists in the supplied canonical bank.
#'
#' @param assignment_file Assignment/tutorial Rmd to validate.
#' @param bank_manifest Canonical question-bank manifest.
#' @return The extracted assignment question records.
#' @details Called only by `build_question_manifest()`. Depends on
#'   `extract_question_records()`.
validate_assignment_file <- function(assignment_file = "index.Rmd", bank_manifest) {
  assignment <- extract_question_records(assignment_file)
  if (is.null(assignment) || !nrow(assignment)) {
    stop("Assignment contains no question blocks: ", assignment_file, ".")
  }

  duplicate_labels <- unique(assignment$item_label[duplicated(assignment$item_label)])
  if (length(duplicate_labels)) {
    stop("Duplicate assignment question label(s): ", paste(duplicate_labels, collapse = ", "), ".")
  }

  missing <- setdiff(assignment$item_label, bank_manifest$item_label)
  if (length(missing)) {
    stop(
      "Assignment question(s) are not in the canonical bank: ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  assignment
}

#' Build a validated manifest for questions embedded in an assignment Rmd
#'
#' For authoring checkouts, rebuilds the canonical bank, verifies assignment
#' question IDs against it, and writes canonical metadata plus assignment source
#' lines. In deployed copies that intentionally omit the canonical bank, reuses
#' an already validated manifest instead of exposing source solutions/checkers.
#'
#' @param root Repository root.
#' @param assignment_file Assignment/tutorial Rmd relative to `root`.
#' @param bank_dir Canonical question-bank directory relative to `root`.
#' @param bank_output Destination canonical-bank manifest CSV.
#' @param output Destination validated assignment manifest CSV.
#' @return Invisibly, the validated assignment manifest data frame.
#' @details No current hosted-player build path calls this helper; the current
#'   runtime uses `build_player_assets()` and the generated runtime pool. It is
#'   retained for assignment-manifest compatibility and is exercised by
#'   question-manifest tests. Depends on `read_question_manifest()` for deployed
#'   fallback, `build_question_bank_manifest()`, and `validate_assignment_file()`.
build_question_manifest <- function(
  root = ".",
  assignment_file = "index.Rmd",
  bank_dir = "question-bank",
  bank_output = "question_bank_manifest.csv",
  output = "question_manifest.csv"
) {
  # Deployed apps intentionally omit the canonical bank because it contains
  # solutions/checkers. Use the prevalidated assignment manifest there.
  if (!dir.exists(file.path(root, bank_dir))) {
    if (file.exists(output)) return(invisible(read_question_manifest(output)))
    stop("Canonical question bank and validated question manifest are both missing.")
  }

  bank <- build_question_bank_manifest(root, bank_dir, bank_output)
  assignment <- validate_assignment_file(file.path(root, assignment_file), bank)
  canonical <- bank[
    match(assignment$item_label, bank$item_label),
    c("item_label", "event", "topic", "points", "starter_question"),
    drop = FALSE
  ]
  canonical$assignment_source_file <- assignment_file
  canonical$assignment_source_line <- assignment$source_line

  write.csv(canonical, output, row.names = FALSE, na = "")
  message("Validated assignment manifest written to ", output, ".")
  invisible(canonical)
}

# Runtime manifest access -----------------------------------------------------

#' Read the runtime question manifest
#'
#' Loads the reduced manifest consumed by the hosted tutorial's assignment and
#' logging helpers, returning an empty expected schema when no file exists.
#'
#' @param path Path to the runtime question-manifest CSV.
#' @return A data frame containing runtime question metadata.
#' @details Used by default arguments in `initialize_student_assignments()`,
#'   `post_log_event()`, and `register_logging_handlers()`, by
#'   `scripts/04_build_gradebook.R`, and by `build_question_manifest()` fallback.
#'   It has no within-repo function dependencies.
read_question_manifest <- function(path = "question_manifest.csv") {
  if (!file.exists(path)) {
    return(data.frame(
      item_label = character(),
      event = character(),
      topic = character(),
      points = numeric(),
      starter_question = logical(),
      stringsAsFactors = FALSE
    ))
  }
  read.csv(path, stringsAsFactors = FALSE, na.strings = "")
}

#' Resolve the curriculum topic for a logged item label
#'
#' Finds an exact manifest label or the unique parent of a generated child label
#' separated by `-`, `_`, or `.`, supplying a default for missing/ambiguous IDs.
#'
#' @param item_label Question or generated child label to resolve.
#' @param manifest Runtime/canonical question manifest.
#' @param default Value returned when no unique topic can be resolved.
#' @return The matching topic value, or `default`.
#' @details Called by `post_log_event()` in `R/logging.R`. It has no within-repo
#'   function dependencies.
question_topic <- function(item_label, manifest, default = "unassigned") {
  if (is.null(item_label) || is.na(item_label) || !nzchar(item_label)) return(default)
  if (!nrow(manifest)) return(default)

  exact <- which(manifest$item_label == item_label)
  if (length(exact) == 1) return(manifest$topic[[exact]])

  parent <- which(vapply(
    manifest$item_label,
    function(label) {
      any(vapply(
        c("-", "_", "."),
        function(separator) startsWith(item_label, paste0(label, separator)),
        logical(1)
      ))
    },
    logical(1)
  ))
  if (length(parent) == 1) return(manifest$topic[[parent]])

  default
}

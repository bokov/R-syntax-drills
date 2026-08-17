# Canonical question-bank and assignment-manifest helpers.
#
# Only question-bank/ defines canonical questions. index.Rmd is a derived
# assignment whose copied question sections are validated against that bank.

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Older bank files predate explicit topic metadata. Keep their stable item-label
# families as a compatibility registry so every canonical question has a topic
# without creating a very large mechanical edit to those source banks.
# Explicit topic= metadata on a question always takes precedence.
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

parse_bool_metadata <- function(value, default = FALSE) {
  if (is.null(value) || !nzchar(trimws(value))) return(default)
  value <- tolower(trimws(value))
  if (value %in% c("true", "1", "yes")) return(TRUE)
  if (value %in% c("false", "0", "no")) return(FALSE)
  stop("Invalid logical metadata value: ", value, ".")
}

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

normalize_question_text <- function(lines) {
  if (!length(lines)) return("")
  lines <- sub("[[:space:]]+$", "", lines)
  while (length(lines) && !nzchar(lines[[1]])) lines <- lines[-1]
  while (length(lines) && !nzchar(lines[[length(lines)]])) lines <- lines[-length(lines)]
  paste(lines, collapse = "\n")
}

question_hash <- function(lines) {
  path <- tempfile("question-hash-")
  on.exit(unlink(path), add = TRUE)
  writeChar(normalize_question_text(lines), path, eos = NULL, useBytes = TRUE)
  unname(tools::md5sum(path))
}

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
  record$question_hash <- question_hash(lines)
  record
}

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

extract_question_records <- function(path) {
  lines <- readLines(path, warn = FALSE)
  explicit <- extract_explicit_question_blocks(lines, path)
  if (!is.null(explicit)) return(explicit)
  extract_legacy_question_blocks(lines, path)
}

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
    question_hash = character(),
    stringsAsFactors = FALSE
  )
}

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

  expected <- bank_manifest[match(assignment$item_label, bank_manifest$item_label), , drop = FALSE]
  mismatch <- assignment$item_label[assignment$question_hash != expected$question_hash]
  if (length(mismatch)) {
    stop(
      "Assignment question(s) differ from their canonical bank copies: ",
      paste(mismatch, collapse = ", "),
      ". Re-copy the canonical question block(s)."
    )
  }

  assignment
}

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
    c("item_label", "event", "topic", "points", "starter_question", "question_hash"),
    drop = FALSE
  ]
  canonical$assignment_source_file <- assignment_file
  canonical$assignment_source_line <- assignment$source_line

  write.csv(canonical, output, row.names = FALSE, na = "")
  message("Validated assignment manifest written to ", output, ".")
  invisible(canonical)
}

read_question_manifest <- function(path = "question_manifest.csv") {
  if (!file.exists(path)) {
    return(data.frame(
      item_label = character(),
      event = character(),
      topic = character(),
      points = numeric(),
      starter_question = logical(),
      question_hash = character(),
      stringsAsFactors = FALSE
    ))
  }
  read.csv(path, stringsAsFactors = FALSE, na.strings = "")
}

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

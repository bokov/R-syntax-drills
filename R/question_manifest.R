# Question-bank metadata helpers. Metadata live with the R Markdown chunk that
# defines each question; the generated CSV is a build artifact.

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

parse_question_chunk <- function(line, source_file, source_line) {
  if (!grepl("^```\\{r(?:\\s|,)", line)) return(NULL)

  header <- sub("^```\\{r\\s*", "", line)
  header <- sub("}\\s*$", "", header)
  first <- trimws(sub(",.*$", "", header))
  label <- if (nzchar(first) && !grepl("=", first, fixed = TRUE)) first else NA_character_
  exercise <- identical(tolower(chunk_option_value(header, "exercise") %||% ""), "true")
  topic <- chunk_option_value(header, "topic")
  points_text <- chunk_option_value(header, "points")

  if (!exercise && is.null(topic) && is.null(points_text)) return(NULL)
  if (is.na(label)) {
    stop("Question chunk without a label in ", source_file, ":", source_line, ".")
  }

  if (is.null(topic) || !nzchar(trimws(topic))) topic <- "unassigned"

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
    source_file = source_file,
    source_line = source_line,
    stringsAsFactors = FALSE
  )
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

scan_question_bank <- function(files) {
  items <- lapply(files, function(path) {
    lines <- readLines(path, warn = FALSE)
    found <- lapply(seq_along(lines), function(i) {
      parse_question_chunk(lines[[i]], path, i)
    })
    found <- Filter(Negate(is.null), found)
    if (!length(found)) return(NULL)
    do.call(rbind, found)
  })

  items <- Filter(Negate(is.null), items)
  if (!length(items)) {
    return(data.frame(
      item_label = character(),
      event = character(),
      topic = character(),
      points = numeric(),
      source_file = character(),
      source_line = integer(),
      stringsAsFactors = FALSE
    ))
  }

  manifest <- do.call(rbind, items)
  rownames(manifest) <- NULL

  duplicate_labels <- unique(manifest$item_label[duplicated(manifest$item_label)])
  duplicate_labels <- duplicate_labels[!is.na(duplicate_labels)]
  if (length(duplicate_labels)) {
    stop("Duplicate question label(s): ", paste(duplicate_labels, collapse = ", "), ".")
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

question_source_files <- function(root = ".") {
  files <- list.files(
    root,
    pattern = "\\.[Rr]md$",
    recursive = TRUE,
    full.names = TRUE
  )
  files <- gsub("\\\\", "/", files)
  files <- files[!grepl(
    "(^|/)(tests|examples|output|rsconnect|\\.Rproj\\.user)(/|$)",
    files
  )]
  sub("^\\./", "", files)
}

build_question_manifest <- function(
  root = ".",
  output = "question_manifest.csv"
) {
  manifest <- scan_question_bank(question_source_files(root))
  write.csv(manifest, output, row.names = FALSE, na = "")
  message("Question manifest written to ", output, ".")
  invisible(manifest)
}

read_question_manifest <- function(path = "question_manifest.csv") {
  if (!file.exists(path)) {
    return(data.frame(
      item_label = character(),
      event = character(),
      topic = character(),
      points = numeric(),
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
    function(label) startsWith(item_label, paste0(label, "-")),
    logical(1)
  ))
  if (length(parent) == 1) return(manifest$topic[[parent]])

  default
}

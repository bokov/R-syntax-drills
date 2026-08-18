PLAYER_MANIFEST_COLUMNS <- c(
  "item_label",
  "event",
  "topic",
  "points",
  "starter_question",
  "question_hash"
)

player_manifest <- function(bank_manifest) {
  required <- c(
    PLAYER_MANIFEST_COLUMNS,
    "source_file",
    "source_line",
    "source_end_line"
  )
  missing <- setdiff(required, names(bank_manifest))
  if (length(missing)) {
    stop(
      "Canonical bank manifest is missing required column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  out <- bank_manifest[
    bank_manifest$event == "exercise_result" &
      bank_manifest$points > 0,
    ,
    drop = FALSE
  ]

  if (!nrow(out)) {
    stop("The canonical bank contains no scored learnr exercises for the player.")
  }

  out
}

r_chunk_label <- function(line) {
  if (!grepl("^```\\{r(?:\\s|,)", line, perl = TRUE)) return(NA_character_)
  header <- sub("^```\\{r\\s*", "", line)
  header <- sub("}\\s*$", "", header)
  first <- trimws(sub(",.*$", "", header))
  if (!nzchar(first) || grepl("=", first, fixed = TRUE)) return(NA_character_)
  first
}

strip_question_solutions <- function(lines, item_label) {
  target <- paste0(item_label, "-solution")
  out <- character()
  ii <- 1L

  while (ii <= length(lines)) {
    if (identical(r_chunk_label(lines[[ii]]), target)) {
      ii <- ii + 1L
      while (ii <= length(lines) && !grepl("^```\\s*$", lines[[ii]])) {
        ii <- ii + 1L
      }
      if (ii <= length(lines)) ii <- ii + 1L
      next
    }

    out <- c(out, lines[[ii]])
    ii <- ii + 1L
  }

  out
}

question_player_lines <- function(record) {
  source_lines <- readLines(record$source_file[[1]], warn = FALSE)
  lines <- source_lines[
    seq.int(record$source_line[[1]], record$source_end_line[[1]])
  ]

  lines <- strip_question_solutions(lines, record$item_label[[1]])

  heading <- grep("^##\\s+", lines, perl = TRUE)
  if (length(heading)) {
    lines[[heading[[1]]]] <- sub("^##\\s+", "#### ", lines[[heading[[1]]]])
  }

  # Do not add a second Markdown/HTML wrapper around the question. Learnr emits
  # each exercise with class="tutorial-exercise" and data-label=<item_label>;
  # the browser player uses that canonical rendered marker directly.
  lines
}

build_runtime_question_pool <- function(
  manifest,
  output = "runtime_question_pool.Rmd"
) {
  blocks <- lapply(seq_len(nrow(manifest)), function(ii) {
    question_player_lines(manifest[ii, , drop = FALSE])
  })

  writeLines(
    unlist(blocks, use.names = FALSE),
    output
  )

  invisible(output)
}

build_runtime_index <- function(
  template = "index.Rmd",
  output = "runtime_index.Rmd",
  config = APP_CONFIG
) {
  lines <- readLines(template, warn = FALSE)
  token <- "__WEEK_ID__"

  if (!any(grepl(token, lines, fixed = TRUE))) {
    stop("The player template does not contain the __WEEK_ID__ token.")
  }

  week_id <- as.character(config$week_id)[[1]]
  if (!nzchar(trimws(week_id))) stop("APP_CONFIG$week_id must not be blank.")

  lines <- gsub(token, week_id, lines, fixed = TRUE)
  writeLines(lines, output)
  invisible(output)
}

build_player_assets <- function(
  root = ".",
  config = APP_CONFIG,
  pool_output = file.path(root, "runtime_question_pool.Rmd"),
  manifest_output = file.path(root, "question_manifest.csv")
) {
  bank <- build_question_bank_manifest(root = root)
  validate_assignment_config(config, bank)

  manifest <- player_manifest(bank)
  runtime_manifest <- manifest[, PLAYER_MANIFEST_COLUMNS, drop = FALSE]

  write.csv(runtime_manifest, manifest_output, row.names = FALSE, na = "")
  build_runtime_question_pool(manifest, pool_output)

  message(
    "Built runtime player pool with ", nrow(runtime_manifest),
    " scored canonical exercise(s)."
  )

  invisible(runtime_manifest)
}

PLAYER_MANIFEST_COLUMNS <- c(
  "item_label",
  "event",
  "topic",
  "points",
  "starter_question"
)

# Manifest release handling ---------------------------------------------------

#' Validate a runtime manifest release number
#'
#' Normalizes a release value to the positive integer used to identify one
#' published manifest generation.
#'
#' @param release Candidate release value.
#' @return A length-one integer release number.
#' @details Called by `current_manifest_release()` and `build_player_assets()`,
#'   and directly by `tests/testthat/test-player_builder.R`. It has no
#'   within-repo function dependencies.
validate_manifest_release <- function(release) {
  release <- suppressWarnings(as.numeric(release))
  if (
    length(release) != 1L ||
    is.na(release) ||
    !is.finite(release) ||
    release < 1 ||
    release != floor(release)
  ) {
    stop("Manifest release must be one positive whole number.")
  }
  as.integer(release)
}

#' Read the release number from an existing player manifest
#'
#' Preserves the existing release when rebuilding player assets unless the
#' caller explicitly requests a different release, while supplying a validated
#' default for a missing legacy manifest.
#'
#' @param path Path to the existing runtime manifest CSV.
#' @param default Release used when the file or its `release` column is absent.
#' @return A validated integer release number.
#' @details Called by `build_player_assets()` and directly by
#'   `test-player_builder.R`. Depends on `validate_manifest_release()`.
current_manifest_release <- function(path, default = 1L) {
  default <- validate_manifest_release(default)
  if (!file.exists(path)) return(default)

  existing <- read.csv(path, stringsAsFactors = FALSE, na.strings = "")
  if (!"release" %in% names(existing)) return(default)

  values <- unique(existing$release[!is.na(existing$release)])
  if (length(values) != 1L) {
    stop("Existing player manifest must contain exactly one release value.")
  }
  validate_manifest_release(values[[1]])
}

# Runtime manifest selection --------------------------------------------------

#' Select canonical questions that belong in the runtime player
#'
#' Validates the canonical bank's required metadata and keeps positive-point
#' learnr exercises, retaining source locations needed to copy their question
#' blocks into the generated runtime pool.
#'
#' @param bank_manifest Canonical bank manifest returned by
#'   `build_question_bank_manifest()`.
#' @return The scored `exercise_result` rows with canonical and source-location
#'   metadata intact.
#' @details Called by `build_player_assets()` and directly by
#'   `test-player_builder.R`. It uses `PLAYER_MANIFEST_COLUMNS` but has no
#'   within-repo function dependencies.
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

# Question-block extraction ---------------------------------------------------

#' Extract the label from an R Markdown R-chunk header
#'
#' Parses the first field of an R chunk header while rejecting option-only
#' headers, providing the label matcher used when removing solution chunks.
#'
#' @param line One line of R Markdown text.
#' @return The chunk label as character, or `NA_character_` when the line is not
#'   a labeled R chunk header.
#' @details Called only by `strip_question_solutions()`. It has no within-repo
#'   function dependencies.
r_chunk_label <- function(line) {
  if (!grepl("^```\\{r(?:\\s|,)", line, perl = TRUE)) return(NA_character_)
  header <- sub("^```\\{r\\s*", "", line)
  header <- sub("}\\s*$", "", header)
  first <- trimws(sub(",.*$", "", header))
  if (!nzchar(first) || grepl("=", first, fixed = TRUE)) return(NA_character_)
  first
}

#' Remove the solution chunk from one canonical question block
#'
#' Copies all lines except the chunk named `<item_label>-solution`, keeping the
#' exercise and checker code needed by the student runtime while withholding the
#' authored solution.
#'
#' @param lines Character vector containing one canonical question block.
#' @param item_label Permanent item label for that question.
#' @return The question-block lines with its solution chunk removed.
#' @details Called only by `question_player_lines()`. Depends on
#'   `r_chunk_label()`.
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

#' Extract one canonical question for the runtime player
#'
#' Reads the source range recorded in the canonical manifest, strips its solution
#' chunk, and demotes the question heading so the generated child document nests
#' correctly inside the stable learnr shell.
#'
#' @param record One-row canonical manifest record containing source file/range
#'   and `item_label` metadata.
#' @return Character lines for the student-facing question block.
#' @details Called only by `build_runtime_question_pool()`. Depends on
#'   `strip_question_solutions()`.
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

# Asset generation ------------------------------------------------------------

#' Build the solution-free runtime question pool
#'
#' Converts every selected canonical manifest record to student-facing Rmd lines
#' and writes the concatenated blocks to the runtime question-pool file.
#'
#' @param manifest Canonical scored-question records with source locations.
#' @param output Destination runtime-pool Rmd path.
#' @return Invisibly, `output` after writing the pool.
#' @details Called by `build_player_assets()` and directly by
#'   `test-player_builder.R`. Depends on `question_player_lines()`.
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

#' Build the manifest and question pool consumed by the runtime player
#'
#' Scans the canonical bank, validates assignment configuration, selects scored
#' questions, preserves or validates the manifest release, writes the reduced
#' runtime manifest, and writes the matching solution-free question pool.
#'
#' @param root Repository root containing the canonical question bank.
#' @param config Assignment configuration to validate against the bank, or
#'   `NULL` to skip configuration validation.
#' @param pool_output Destination runtime question-pool Rmd path.
#' @param manifest_output Destination runtime manifest CSV path.
#' @param release Optional explicit positive integer release. When `NULL`, reuse
#'   the existing manifest's release or default to 1.
#' @return Invisibly, the runtime manifest data frame that was written.
#' @details Called from the publishing/build scripts, notably
#'   `scripts/09_build_student_assets.R`, and is the high-level entry point tested
#'   indirectly by player-builder tests. Depends on `build_question_bank_manifest()`,
#'   `validate_assignment_config()`, `player_manifest()`,
#'   `current_manifest_release()`, `validate_manifest_release()`, and
#'   `build_runtime_question_pool()`.
build_player_assets <- function(
  root = ".",
  config = APP_CONFIG,
  pool_output = file.path(root, "runtime_question_pool.Rmd"),
  manifest_output = file.path(root, "question_manifest.csv"),
  release = NULL
) {
  bank <- build_question_bank_manifest(root = root)
  if (!is.null(config)) validate_assignment_config(config, bank)

  manifest <- player_manifest(bank)
  runtime_manifest <- manifest[, PLAYER_MANIFEST_COLUMNS, drop = FALSE]
  if (is.null(release)) {
    release <- current_manifest_release(manifest_output)
  }
  runtime_manifest$release <- validate_manifest_release(release)

  write.csv(runtime_manifest, manifest_output, row.names = FALSE, na = "")
  build_runtime_question_pool(manifest, pool_output)

  message(
    "Built runtime player pool with ", nrow(runtime_manifest),
    " scored canonical exercise(s); manifest release ",
    unique(runtime_manifest$release), "."
  )

  invisible(runtime_manifest)
}

RUNTIME_SUPPORT_CHUNK_LABEL <- "drillr-runtime-support"
RUNTIME_GLOBAL_EXERCISE_CHUNK_LABEL <- "setup-global-exercise"
RUNTIME_SUPPORT_MODE <- "setup-global-exercise-v1"

runtime_support_helper_lines <- function(root = ".") {
  checker_path <- file.path(root, "R", "syntax_checkers.R")
  if (!file.exists(checker_path)) {
    stop("Could not find canonical runtime checker source: ", checker_path)
  }

  c(
    paste0("# drillr-runtime-support-mode: ", RUNTIME_SUPPORT_MODE),
    readLines(checker_path, warn = FALSE, encoding = "UTF-8")
  )
}

runtime_support_code_lines <- function(root = ".") {
  c(
    runtime_support_helper_lines(root),
    "",
    "learnr::tutorial_options(exercise.checker = drillr_exercise_checker)"
  )
}

md5_text_lines <- function(lines, prefix) {
  path <- tempfile(prefix)
  on.exit(unlink(path), add = TRUE)
  writeLines(enc2utf8(lines), path, useBytes = TRUE)
  paste0("md5-", unname(tools::md5sum(path)))
}

runtime_support_hash <- function(root = ".") {
  # Keep hashing the compatibility chunk's inner lines so already-installed
  # Drillr clients can independently validate newly published banks. The mode
  # marker above makes exercise-setup semantics part of this fingerprint.
  md5_text_lines(runtime_support_code_lines(root), "drillr-runtime-support-")
}

runtime_support_chunk_lines <- function(root = ".") {
  c(
    # Existing Drillr clients locate this chunk to compute runtime_support_hash.
    # It also configures the global checker during tutorial prerendering.
    paste0("```{r ", RUNTIME_SUPPORT_CHUNK_LABEL, ", include=FALSE}"),
    runtime_support_code_lines(root),
    "```",
    "",
    # learnr copies setup-global-exercise code into every exercise preparation
    # environment, where question-specific *-check chunks are evaluated.
    paste0("```{r ", RUNTIME_GLOBAL_EXERCISE_CHUNK_LABEL, ", include=FALSE}"),
    runtime_support_helper_lines(root),
    "```",
    ""
  )
}

runtime_question_bank_version_with_support <- function(
  manifest,
  support_hash = ""
) {
  base_version <- runtime_question_bank_version(manifest)
  support_hash <- trimws(as.character(support_hash)[[1]])
  if (!nzchar(support_hash)) return(base_version)

  md5_text_lines(
    c(
      paste0("question_bank=", base_version),
      paste0("runtime_support=", support_hash)
    ),
    "drillr-bank-version-with-support-"
  )
}

prepare_question_bank_sync_with_support <- function(
  manifest,
  support_hash = runtime_support_hash()
) {
  out <- prepare_question_bank_sync(manifest)
  out$bank_version <- runtime_question_bank_version_with_support(
    manifest,
    support_hash
  )
  out
}

# Question-bank interactive review -------------------------------------------

#' Launch one canonical question-bank file as a review tutorial
#'
#' Resolves and validates a selected question-bank Rmd, also validates the full
#' canonical bank for cross-file conflicts, writes a temporary learnr wrapper,
#' and launches that wrapper for interactive author review.
#'
#' @param bank Question-bank filename, path, or basename; `.Rmd` is appended when
#'   omitted and unresolved basenames are looked up under `question-bank/`.
#' @param validation Whether validation warnings/errors should stop review
#'   (`"error"`) or be converted to warnings where possible (`"warn"`).
#' @param root Repository root containing `R/` and `question-bank/`.
#' @return Invisibly, the path to the temporary review Rmd after
#'   `rmarkdown::run()` returns.
#' @details No within-repository caller was found; this is an author-facing
#'   interactive entry point intended to be sourced/called directly. It sources
#'   `R/question_manifest.R` and depends on `scan_question_bank()` and
#'   `question_bank_source_files()` from that file, plus its local `validate()`
#'   helper.
review_question_bank <- function(
    bank,
    validation = c("error", "warn"),
    root = "."
) {
  validation <- match.arg(validation)
  
  source(file.path(root, "R/question_manifest.R"))
  
  bank_file <- bank
  if (!grepl("\\.[Rr]md$", bank_file)) {
    bank_file <- paste0(bank_file, ".Rmd")
  }
  
  if (!file.exists(bank_file)) {
    bank_file <- file.path(root, "question-bank", basename(bank_file))
  }
  
  if (!file.exists(bank_file)) {
    stop("Question-bank file does not exist: ", bank, ".")
  }
  
  bank_file <- normalizePath(bank_file, mustWork = TRUE)
  root <- normalizePath(root, mustWork = TRUE)
  
  #' Run a validation expression under the selected review policy
  #'
  #' Converts validation warnings to errors in strict mode and converts errors
  #' to warnings plus `NULL` in warning mode so the review wrapper can continue.
  #'
  #' @param expr Validation expression to evaluate.
  #' @return The expression result, or `NULL` after a handled error in warning
  #'   mode.
  #' @details Local helper used three times by `review_question_bank()` for the
  #'   selected bank and complete-bank consistency checks. It depends on the
  #'   enclosing `validation` argument only.
  validate <- function(expr) {
    tryCatch(
      withCallingHandlers(
        expr,
        warning = function(w) {
          if (identical(validation, "error")) {
            stop(conditionMessage(w), call. = FALSE)
          }
        }
      ),
      error = function(e) {
        if (identical(validation, "error")) {
          stop(e)
        }
        
        warning(
          "Question-bank validation failed: ",
          conditionMessage(e),
          call. = FALSE
        )
        
        NULL
      }
    )
  }
  
  # Validate the selected file itself.
  selected <- validate(
    scan_question_bank(bank_file)
  )
  
  if (!is.null(selected) && !nrow(selected)) {
    msg <- paste0(
      "No canonical questions were found in ",
      basename(bank_file),
      "."
    )
    
    if (identical(validation, "error")) {
      stop(msg)
    } else {
      warning(msg, call. = FALSE)
    }
  }
  
  # Also check consistency of the complete canonical bank, particularly
  # duplicate permanent item labels across different bank files.
  validate(
    scan_question_bank(
      question_bank_source_files(root)
    )
  )
  
  header <- c(
    "---",
    paste0(
      'title: "Question-bank review - ',
      tools::file_path_sans_ext(basename(bank_file)),
      '"'
    ),
    "output:",
    "  learnr::tutorial:",
    "    progressive: false",
    "    allow_skip: true",
    "runtime: shiny_prerendered",
    "tutorial:",
    paste0(
      '  id: "question-bank-review-',
      tools::file_path_sans_ext(basename(bank_file)),
      '"'
    ),
    "  version: 1.0",
    "---",
    "",
    "```{r setup, include=FALSE}",
    "library(learnr)",
    "library(gradethis)",
    "library(shiny)",
    paste0(
      'source("',
      file.path(root, "R/syntax_checkers.R"),
      '")'
    ),
    "",
    "gradethis::gradethis_setup(",
    "  pass.praise = FALSE,",
    "  fail.encourage = FALSE,",
    "  fail.hint = FALSE",
    ")",
    "",
    "learnr::tutorial_options(",
    "  exercise.timelimit = 10,",
    "  exercise.reveal_solution = FALSE",
    ")",
    "```",
    ""
  )
  
  review_file <- tempfile(
    pattern = paste0(
      "review-",
      tools::file_path_sans_ext(basename(bank_file)),
      "-"
    ),
    fileext = ".Rmd"
  )
  
  writeLines(
    c(
      header,
      readLines(bank_file, warn = FALSE)
    ),
    review_file
  )
  
  message("Review tutorial written to: ", review_file)
  
  rmarkdown::run(review_file)
  
  invisible(review_file)
}
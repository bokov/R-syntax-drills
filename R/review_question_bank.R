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
      'title: "Question-bank review — ',
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
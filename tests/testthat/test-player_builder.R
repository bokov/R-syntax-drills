test_that("player manifest contains only scored learnr exercises", {
  bank <- data.frame(
    item_label = c("q1", "q2", "q3"),
    event = c("exercise_result", "question_submission", "exercise_result"),
    topic = c("vectors", "vectors", "vectors"),
    points = c(1, 1, 0),
    starter_question = c(TRUE, FALSE, FALSE),
    question_hash = c("h1", "h2", "h3"),
    source_file = c("a", "b", "c"),
    source_line = c(1L, 1L, 1L),
    source_end_line = c(1L, 1L, 1L),
    stringsAsFactors = FALSE
  )

  out <- player_manifest(bank)
  expect_equal(out$item_label, "q1")
})

test_that("runtime question pool embeds exercise-scoped checker support, strips solutions, and keeps question checkers", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  bank_file <- tempfile(fileext = ".Rmd")
  output <- tempfile(fileext = ".Rmd")

  writeLines(c(
    "<!-- question: q1 -->",
    "## Example question",
    "",
    "Return 2.",
    "",
    "```{r q1, exercise=TRUE, topic=\"vectors\"}",
    "",
    "```",
    "",
    "```{r q1-solution}",
    "1 + 1",
    "```",
    "",
    "```{r q1-check}",
    "grade_this({ pass('ok') })",
    "```",
    "<!-- /question -->"
  ), bank_file)

  manifest <- scan_question_bank(bank_file)
  build_runtime_question_pool(manifest, output, root = root)
  lines <- readLines(output, warn = FALSE)
  text <- paste(lines, collapse = "\n")

  # Keep the original compatibility chunk so already-installed Drillr clients
  # can compute the runtime-support hash for downloaded banks.
  expect_match(text, "```{r drillr-runtime-support, include=FALSE}", fixed = TRUE)
  expect_match(
    text,
    "# drillr-runtime-support-mode: setup-global-exercise-v1",
    fixed = TRUE
  )
  expect_match(
    text,
    "learnr::tutorial_options(exercise.checker = drillr_exercise_checker)",
    fixed = TRUE
  )

  # Question-specific gradethis checks run in exercise environments. learnr's
  # setup-global-exercise chunk is the contract that makes these helpers
  # available there, rather than merely during tutorial prerendering.
  expect_match(text, "```{r setup-global-exercise, include=FALSE}", fixed = TRUE)
  global_start <- grep("```{r setup-global-exercise, include=FALSE}", lines, fixed = TRUE)
  global_close <- which(
    seq_along(lines) > global_start[[1]] & grepl("^```[[:space:]]*$", lines)
  )[[1]]
  global_text <- paste(lines[(global_start[[1]] + 1L):(global_close - 1L)], collapse = "\n")
  for (helper in c(
    "parse_student_code <- function(code)",
    "call_head <- function(x)",
    "walk_calls <- function(x)",
    "uses_call <- function(code, name)",
    "call_has_named_arg <- function(code, function_name, argument_name)"
  )) {
    expect_match(global_text, helper, fixed = TRUE)
  }

  expect_lt(
    global_start[[1]],
    grep("q1, exercise=TRUE", lines, fixed = TRUE)[[1]]
  )
  expect_match(text, "#### Example question", fixed = TRUE)
  expect_false(grepl("assignment-question-q1", text, fixed = TRUE))
  expect_false(grepl("q1-solution", text, fixed = TRUE))
  expect_false(grepl("1 + 1", text, fixed = TRUE))
  expect_true(grepl("q1-check", text, fixed = TRUE))
})

test_that("assignment-player script is inlined after the generated question pool", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  lines <- readLines(file.path(root, "index.Rmd"), warn = FALSE)

  pool_line <- grep('child="runtime_question_pool.Rmd"', lines, fixed = TRUE)
  script_line <- grep('shiny::includeScript("www/assignment-player.js")', lines, fixed = TRUE)
  external_script <- grep('<script src="assignment-player.js"></script>', lines, fixed = TRUE)

  expect_length(pool_line, 1)
  expect_length(script_line, 1)
  expect_length(external_script, 0)
  expect_gt(script_line, pool_line)
})

test_that("runtime shells do not source a second checker copy", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  text <- paste(readLines(file.path(root, "index.Rmd"), warn = FALSE), collapse = "\n")

  expect_false(grepl('source("R/syntax_checkers.R")', text, fixed = TRUE))
})

test_that("learnr answer state is not persisted between sessions", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  text <- paste(readLines(file.path(root, "index.Rmd"), warn = FALSE), collapse = "\n")

  expect_match(text, 'options(tutorial.storage = "none")', fixed = TRUE)
})

test_that("assignment player uses learnr rendered labels instead of parallel question IDs", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  text <- paste(
    readLines(file.path(root, "www", "assignment-player.js"), warn = FALSE),
    collapse = "\n"
  )

  expect_match(text, ".tutorial-exercise[data-label]", fixed = TRUE)
  expect_match(text, ".section.level4", fixed = TRUE)
  expect_false(grepl("assignment-question-", text, fixed = TRUE))
  expect_match(
    text,
    "addCustomMessageHandler('assignment:clear', function(message)",
    fixed = TRUE
  )
})

test_that("current vector-only configuration has an eligible starter set", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  bank <- scan_question_bank(question_bank_source_files(root))

  config <- list(
    queue_size = 10L,
    topic_priority = c("vector_creation", "vector_indexing")
  )

  expect_silent(validate_assignment_config(config, bank))

  eligible_starters <- bank[
    bank$event == "exercise_result" &
      bank$points > 0 &
      bank$starter_question %in% TRUE &
      bank$topic %in% config$topic_priority,
    ,
    drop = FALSE
  ]
  expect_gt(nrow(eligible_starters), 0)
})

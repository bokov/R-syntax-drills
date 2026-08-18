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

test_that("runtime question pool strips solutions but keeps checkers", {
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
  build_runtime_question_pool(manifest, output)
  text <- paste(readLines(output, warn = FALSE), collapse = "\n")

  expect_match(text, "assignment-question-q1", fixed = TRUE)
  expect_match(text, "#### Example question", fixed = TRUE)
  expect_false(grepl("q1-solution", text, fixed = TRUE))
  expect_false(grepl("1 + 1", text, fixed = TRUE))
  expect_true(grepl("q1-check", text, fixed = TRUE))
})

test_that("runtime index receives the configured week as tutorial version", {
  template <- tempfile(fileext = ".Rmd")
  output <- tempfile(fileext = ".Rmd")
  writeLines(c(
    "tutorial:",
    "  version: \"__WEEK_ID__\""
  ), template)

  build_runtime_index(
    template = template,
    output = output,
    config = list(week_id = "week-17")
  )

  text <- paste(readLines(output, warn = FALSE), collapse = "\n")
  expect_match(text, 'version: "week-17"', fixed = TRUE)
  expect_false(grepl("__WEEK_ID__", text, fixed = TRUE))
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

test_that("current vector-only configuration has an eligible starter set", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  bank <- scan_question_bank(question_bank_source_files(root))

  config <- list(
    questions_per_week = 10L,
    unlocked_topics = c("vector_creation", "vector_indexing")
  )

  expect_silent(validate_assignment_config(config, bank))

  eligible_starters <- bank[
    bank$event == "exercise_result" &
      bank$points > 0 &
      bank$starter_question %in% TRUE &
      bank$topic %in% config$unlocked_topics,
    ,
    drop = FALSE
  ]
  expect_gt(nrow(eligible_starters), 0)
})

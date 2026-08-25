test_that("player manifest contains only scored learnr exercises", {
  bank <- data.frame(
    item_label = c("q1", "q2", "q3"),
    event = c("exercise_result", "question_submission", "exercise_result"),
    topic = c("vectors", "vectors", "vectors"),
    points = c(1, 1, 0),
    starter_question = c(TRUE, FALSE, FALSE),
    source_file = c("a", "b", "c"),
    source_line = c(1L, 1L, 1L),
    source_end_line = c(1L, 1L, 1L),
    stringsAsFactors = FALSE
  )

  out <- player_manifest(bank)
  expect_equal(out$item_label, "q1")
})

test_that("manifest release is explicit and preserved", {
  path <- tempfile(fileext = ".csv")
  write.csv(
    data.frame(item_label = "q1", release = 7L),
    path,
    row.names = FALSE
  )

  expect_identical(current_manifest_release(path), 7L)
  expect_identical(current_manifest_release(tempfile()), 1L)
  expect_error(validate_manifest_release(0), "positive whole number")
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

  expect_match(text, "#### Example question", fixed = TRUE)
  expect_false(grepl("assignment-question-q1", text, fixed = TRUE))
  expect_false(grepl("q1-solution", text, fixed = TRUE))
  expect_false(grepl("1 + 1", text, fixed = TRUE))
  expect_true(grepl("q1-check", text, fixed = TRUE))
})

test_that("assignment-player script is inlined after the generated question pool", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  lines <- readLines(file.path(root, "index.Rmd"), warn = FALSE)

  pool_line <- grep('child=DRILLR_RUNTIME_BANK$pool_path', lines, fixed = TRUE)
  script_line <- grep('shiny::includeScript("www/assignment-player.js")', lines, fixed = TRUE)
  external_script <- grep('<script src="assignment-player.js"></script>', lines, fixed = TRUE)

  expect_length(pool_line, 1)
  expect_length(script_line, 1)
  expect_length(external_script, 0)
  expect_gt(script_line, pool_line)
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

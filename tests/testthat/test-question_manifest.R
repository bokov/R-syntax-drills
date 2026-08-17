test_that("scanner reads topic metadata", {
  manifest <- scan_question_bank(test_path("fixtures", "valid.Rmd"))

  expect_equal(nrow(manifest), 1)
  expect_equal(manifest$item_label, "vector_index")
  expect_equal(manifest$event, "exercise_result")
  expect_equal(manifest$topic, "vector_indexing")
  expect_equal(manifest$points, 1)
  expect_false(manifest$starter_question)
  expect_match(manifest$question_hash, "^[0-9a-f]{32}$")
})

test_that("missing topic defaults to unassigned when no legacy rule applies", {
  expect_warning(
    manifest <- scan_question_bank(test_path("fixtures", "missing_topic.Rmd")),
    "unassigned"
  )

  expect_equal(manifest$topic, "unassigned")
  expect_equal(manifest$points, 1)
})

test_that("legacy question families receive canonical topics", {
  expect_equal(legacy_question_topic("vector_c01"), "vector_creation")
  expect_equal(legacy_question_topic("vector_e30"), "vector_indexing")
  expect_equal(legacy_question_topic("df_r01"), "dataframe_indexing")
  expect_equal(legacy_question_topic("df_c16"), "dataframe_indexing")
  expect_equal(legacy_question_topic("df_b09"), "dataframe_indexing")
  expect_equal(legacy_question_topic("df_s16"), "subset_function")
  expect_equal(legacy_question_topic("expr_d50"), "expression_decomposition")
  expect_null(legacy_question_topic("vector_c01-solution"))
  expect_null(legacy_question_topic("unknown_question"))
})

test_that("explicit topic metadata overrides legacy topic rules", {
  f <- tempfile(fileext = ".Rmd")
  writeLines(c(
    "## Explicit topic",
    "",
    "```{r vector_c01, exercise=TRUE, topic=\"custom_topic\"}",
    "",
    "```"
  ), f)

  manifest <- scan_question_bank(f)
  expect_equal(manifest$topic, "custom_topic")
})

test_that("explicit points metadata is preserved", {
  manifest <- scan_question_bank(test_path("fixtures", "explicit_points.Rmd"))
  expect_equal(manifest$points, 0)
})

test_that("duplicate canonical question labels are rejected", {
  expect_error(
    scan_question_bank(test_path("fixtures", "duplicate_labels.Rmd")),
    "Duplicate canonical question label"
  )
})

test_that("starter_question metadata is parsed", {
  f <- tempfile(fileext = ".Rmd")
  writeLines(c(
    "<!-- question: starter_one -->",
    "## Starter",
    "",
    "Prompt.",
    "",
    "```{r starter_one, exercise=TRUE, topic=\"vectors\", starter_question=TRUE}",
    "",
    "```",
    "<!-- /question -->"
  ), f)

  manifest <- scan_question_bank(f)
  expect_true(manifest$starter_question)
})

test_that("explicit question marker must match item label", {
  f <- tempfile(fileext = ".Rmd")
  writeLines(c(
    "<!-- question: wrong_id -->",
    "## Starter",
    "",
    "```{r actual_id, exercise=TRUE, topic=\"vectors\"}",
    "",
    "```",
    "<!-- /question -->"
  ), f)

  expect_error(scan_question_bank(f), "does not match chunk label")
})

test_that("assignment validation detects changed copied questions", {
  bank_file <- tempfile(fileext = ".Rmd")
  assignment_file <- tempfile(fileext = ".Rmd")

  canonical <- c(
    "<!-- question: q1 -->",
    "## Question",
    "",
    "Return 1.",
    "",
    "```{r q1, exercise=TRUE, topic=\"basics\"}",
    "",
    "```",
    "<!-- /question -->"
  )
  writeLines(canonical, bank_file)

  bank <- scan_question_bank(bank_file)
  writeLines(canonical, assignment_file)
  expect_silent(validate_assignment_file(assignment_file, bank))

  changed <- canonical
  changed[4] <- "Return the number one."
  writeLines(changed, assignment_file)

  expect_error(
    validate_assignment_file(assignment_file, bank),
    "differ from their canonical bank copies"
  )
})

test_that("deployed runtime can use a prevalidated manifest without the bank", {
  manifest <- data.frame(
    item_label = "q1",
    event = "exercise_result",
    topic = "basics",
    points = 1,
    starter_question = FALSE,
    question_hash = "abc123",
    stringsAsFactors = FALSE
  )

  tmp <- tempfile()
  dir.create(tmp)

  write.csv(
    manifest,
    file.path(tmp, "question_manifest.csv"),
    row.names = FALSE
  )

  withr::local_dir(tmp)

  loaded <- build_question_manifest()

  expect_equal(loaded$item_label, "q1")
  expect_equal(loaded$topic, "basics")
  expect_equal(loaded$points, 1)
})

test_that("real canonical bank has complete topic coverage", {
  root <- normalizePath(file.path(test_path(), "..", ".."))

  expect_silent(
    bank <- scan_question_bank(
      question_bank_source_files(root)
    )
  )

  expect_false(any(bank$topic == "unassigned"))
  expect_true(all(c(
    "vector_creation",
    "vector_indexing",
    "dataframe_indexing",
    "subset_function",
    "expression_decomposition"
  ) %in% bank$topic))
  expect_true(all(sprintf("expr_d%02d", 1:50) %in% bank$item_label))
})

test_that("current assignment exposes the expected scored items", {
  root <- normalizePath(file.path(test_path(), "..", ".."))

  bank <- scan_question_bank(
    question_bank_source_files(root)
  )

  assignment <- validate_assignment_file(
    file.path(root, "index.Rmd"),
    bank
  )

  scored <- assignment[
    assignment$event == "exercise_result" &
      assignment$points > 0,
    ,
    drop = FALSE
  ]

  expect_equal(nrow(scored), 8)
  expect_true(all(scored$points == 1))
})

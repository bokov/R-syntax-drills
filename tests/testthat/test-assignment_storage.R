test_that("question-bank sync keeps only backend metadata columns", {
  manifest <- data.frame(
    item_label = c("q1", "q2"),
    event = c("exercise_result", "exercise_result"),
    topic = c("vectors", "lists"),
    points = c(1, 1),
    starter_question = c(TRUE, FALSE),
    question_hash = c("aaa", "bbb"),
    source_file = c("a.Rmd", "b.Rmd"),
    source_line = c(1L, 2L),
    stringsAsFactors = FALSE
  )

  synced <- prepare_question_bank_sync(manifest)

  expect_named(synced, QUESTION_BANK_SYNC_COLUMNS)
  expect_equal(synced$item_label, c("q1", "q2"))
})

test_that("question-bank sync rejects duplicate IDs", {
  manifest <- data.frame(
    item_label = c("q1", "q1"),
    event = c("exercise_result", "exercise_result"),
    topic = c("vectors", "vectors"),
    points = c(1, 1),
    starter_question = c(FALSE, FALSE),
    question_hash = c("aaa", "aaa"),
    stringsAsFactors = FALSE
  )

  expect_error(
    prepare_question_bank_sync(manifest),
    "duplicate item_label"
  )
})

test_that("assignment lookup payload contains only lookup fields", {
  config <- list(
    course_id = "R101",
    week_id = "week-01",
    webhook_url = "unused"
  )

  payload <- assignment_service_payload(
    "get_assignments",
    student_id = "abc123",
    config = config
  )

  expect_equal(payload$request_type, "get_assignments")
  expect_equal(payload$course_id, "R101")
  expect_equal(payload$week_id, "week-01")
  expect_equal(payload$student_id, "abc123")
  expect_null(payload$item_labels)
  expect_null(payload$assignment_reason)
})

test_that("assignment create payload preserves selected IDs and reason", {
  config <- list(
    course_id = "R101",
    week_id = "week-01",
    webhook_url = "unused"
  )

  payload <- assignment_service_payload(
    "get_or_create_assignments",
    student_id = "abc123",
    config = config,
    item_labels = c("q1", "q2"),
    assignment_reason = "static"
  )

  expect_equal(payload$item_labels, c("q1", "q2"))
  expect_equal(payload$assignment_reason, "static")
})

test_that("assignment create payload rejects duplicate question IDs", {
  config <- list(
    course_id = "R101",
    week_id = "week-01",
    webhook_url = "unused"
  )

  expect_error(
    assignment_service_payload(
      "get_or_create_assignments",
      student_id = "abc123",
      config = config,
      item_labels = c("q1", "q1"),
      assignment_reason = "static"
    ),
    "must not contain duplicates"
  )
})

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

test_that("question-bank sync rejects unassigned topics", {
  manifest <- data.frame(
    item_label = "q1",
    event = "exercise_result",
    topic = "unassigned",
    points = 1,
    starter_question = FALSE,
    question_hash = "aaa",
    stringsAsFactors = FALSE
  )

  expect_error(
    prepare_question_bank_sync(manifest),
    "unassigned topics"
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

test_that("assignment service response converts to a stable table", {
  body <- list(
    ok = TRUE,
    assignments = list(
      list(
        assignment_id = "a1",
        course_id = "R101",
        week_id = "week-01",
        student_id = "abc123",
        item_label = "q1",
        topic = "vectors",
        points = 1,
        question_hash = "aaa",
        assigned_at_utc = "2026-08-17T12:00:00.000Z",
        assignment_reason = "static"
      ),
      list(
        assignment_id = "a2",
        course_id = "R101",
        week_id = "week-01",
        student_id = "abc123",
        item_label = "q2",
        topic = "lists",
        points = 1,
        question_hash = "bbb",
        assigned_at_utc = "2026-08-17T12:00:00.000Z",
        assignment_reason = "static"
      )
    )
  )

  assignments <- assignment_response_table(body)

  expect_named(assignments, ASSIGNMENT_COLUMNS)
  expect_equal(assignments$item_label, c("q1", "q2"))
  expect_equal(assignments$points, c(1, 1))
})

test_that("static assignment validation orders rows and preserves IDs", {
  manifest <- data.frame(
    item_label = c("q1", "q2"),
    topic = c("vectors", "lists"),
    points = c(1, 1),
    question_hash = c("aaa", "bbb"),
    stringsAsFactors = FALSE
  )

  assignments <- data.frame(
    assignment_id = c("a2", "a1"),
    course_id = c("R101", "R101"),
    week_id = c("week-01", "week-01"),
    student_id = c("abc123", "abc123"),
    item_label = c("q2", "q1"),
    topic = c("lists", "vectors"),
    points = c(1, 1),
    question_hash = c("bbb", "aaa"),
    assigned_at_utc = c("t", "t"),
    assignment_reason = c("static", "static"),
    stringsAsFactors = FALSE
  )

  validated <- validate_static_assignments(assignments, manifest)
  ids <- assignment_id_map(validated)

  expect_equal(validated$item_label, c("q1", "q2"))
  expect_equal(unname(ids[c("q1", "q2")]), c("a1", "a2"))
})

test_that("static assignment validation rejects stale metadata", {
  manifest <- data.frame(
    item_label = "q1",
    topic = "vectors",
    points = 1,
    question_hash = "newhash",
    stringsAsFactors = FALSE
  )

  assignments <- data.frame(
    assignment_id = "a1",
    course_id = "R101",
    week_id = "week-01",
    student_id = "abc123",
    item_label = "q1",
    topic = "vectors",
    points = 1,
    question_hash = "oldhash",
    assigned_at_utc = "t",
    assignment_reason = "static",
    stringsAsFactors = FALSE
  )

  expect_error(
    validate_static_assignments(assignments, manifest),
    "do not match the current assignment manifest"
  )
})

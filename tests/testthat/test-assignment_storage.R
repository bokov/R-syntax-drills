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

assignment_test_bank <- function() {
  data.frame(
    item_label = c("q1", "q2", "q3", "q4"),
    event = rep("exercise_result", 4),
    topic = c("vectors", "vectors", "lists", "locked"),
    points = rep(1, 4),
    starter_question = c(TRUE, FALSE, FALSE, TRUE),
    question_hash = paste0("h", 1:4),
    stringsAsFactors = FALSE
  )
}

test_that("assignment config validates workload and unlocked topics", {
  config <- list(
    questions_per_week = 2L,
    unlocked_topics = c("vectors", "lists")
  )

  expect_warning(
    settings <- validate_assignment_config(config, assignment_test_bank()),
    "locked topics"
  )
  expect_equal(settings$questions_per_week, 2L)
  expect_equal(settings$unlocked_topics, c("vectors", "lists"))
})

test_that("assignment config rejects unknown or empty unlocked topics", {
  expect_error(
    validate_assignment_config(
      list(questions_per_week = 2L, unlocked_topics = "unknown"),
      assignment_test_bank()
    ),
    "unknown topic"
  )

  expect_error(
    assignment_config(list(questions_per_week = 2L, unlocked_topics = character())),
    "at least one topic"
  )
})

test_that("assignment config requires enough eligible questions and a starter", {
  expect_error(
    validate_assignment_config(
      list(questions_per_week = 3L, unlocked_topics = "vectors"),
      assignment_test_bank()
    ),
    "Only 2"
  )

  bank <- assignment_test_bank()
  bank$starter_question <- FALSE
  expect_error(
    validate_assignment_config(
      list(questions_per_week = 2L, unlocked_topics = c("vectors", "lists")),
      bank
    ),
    "No starter questions"
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
  expect_null(payload$questions_per_week)
  expect_null(payload$unlocked_topics)
})

test_that("dynamic assignment payload carries selection configuration", {
  config <- list(
    course_id = "R101",
    week_id = "week-02",
    questions_per_week = 10L,
    unlocked_topics = c("vector_creation", "vector_indexing"),
    webhook_url = "unused"
  )

  payload <- assignment_service_payload(
    "get_or_create_dynamic_assignments",
    student_id = "abc123",
    config = config
  )

  expect_equal(payload$questions_per_week, 10L)
  expect_equal(
    payload$unlocked_topics,
    c("vector_creation", "vector_indexing")
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
        assignment_reason = "starter"
      ),
      list(
        assignment_id = "a2",
        course_id = "R101",
        week_id = "week-01",
        student_id = "abc123",
        item_label = "q2",
        topic = "vectors",
        points = 1,
        question_hash = "bbb",
        assigned_at_utc = "2026-08-17T12:00:00.000Z",
        assignment_reason = "starter"
      )
    )
  )

  assignments <- assignment_response_table(body)

  expect_named(assignments, ASSIGNMENT_COLUMNS)
  expect_equal(assignments$item_label, c("q1", "q2"))
  expect_equal(assignments$points, c(1, 1))
})

test_that("dynamic persisted assignment may be a canonical manifest subset", {
  manifest <- data.frame(
    item_label = c("q1", "q2", "q3"),
    topic = c("vectors", "vectors", "lists"),
    points = c(1, 1, 1),
    question_hash = c("aaa", "bbb", "ccc"),
    stringsAsFactors = FALSE
  )

  assignments <- data.frame(
    assignment_id = c("a2", "a1"),
    course_id = c("R101", "R101"),
    week_id = c("week-01", "week-01"),
    student_id = c("abc123", "abc123"),
    item_label = c("q2", "q1"),
    topic = c("vectors", "vectors"),
    points = c(1, 1),
    question_hash = c("bbb", "aaa"),
    assigned_at_utc = c("t", "t"),
    assignment_reason = c("starter", "starter"),
    stringsAsFactors = FALSE
  )

  validated <- validate_persisted_assignments(assignments, manifest)
  ids <- assignment_id_map(validated)

  expect_equal(validated$item_label, c("q2", "q1"))
  expect_equal(unname(ids[c("q1", "q2")]), c("a1", "a2"))
})

test_that("dynamic persisted assignment rejects stale metadata", {
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
    assignment_reason = "starter",
    stringsAsFactors = FALSE
  )

  expect_error(
    validate_persisted_assignments(assignments, manifest),
    "do not match the current question manifest"
  )
})

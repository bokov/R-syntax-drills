gradebook_test_manifest <- function() {
  data.frame(
    event = rep("exercise_result", 3),
    item_label = c("q1", "q2", "q3"),
    topic = c("vectors", "vectors", "lists"),
    points = c(1, 1, 1),
    question_hash = c("h1", "h2", "h3"),
    stringsAsFactors = FALSE
  )
}

gradebook_test_events <- function(
  item_label = character(),
  correct = character(),
  assignment_id = character(),
  student_id = character()
) {
  n <- length(item_label)
  if (!length(student_id)) student_id <- rep("abc123", n)
  if (!length(assignment_id)) assignment_id <- rep(NA_character_, n)

  data.frame(
    server_timestamp_utc = if (n) sprintf("2026-08-17T12:%02d:00Z", seq_len(n)) else character(),
    course_id = rep("R101", n),
    week_id = rep("week-01", n),
    session_token = rep("session-1", n),
    student_id = student_id,
    student_name = rep("Ada", n),
    event = rep("exercise_result", n),
    item_label = item_label,
    correct = correct,
    assignment_id = assignment_id,
    stringsAsFactors = FALSE
  )
}

gradebook_test_assignments <- function(
  item_label = c("q1", "q2", "q3"),
  student_id = "abc123",
  assignment_reason = "fsrs_retrievability"
) {
  n <- length(item_label)
  manifest <- gradebook_test_manifest()
  matched <- manifest[match(item_label, manifest$item_label), , drop = FALSE]

  data.frame(
    assignment_id = paste0(student_id, "-a", seq_len(n)),
    course_id = rep("R101", n),
    week_id = rep("week-01", n),
    student_id = rep(student_id, n),
    item_label = item_label,
    topic = matched$topic,
    points = matched$points,
    question_hash = matched$question_hash,
    assigned_at_utc = rep("2026-08-17T12:00:00Z", n),
    assignment_reason = rep(assignment_reason, n),
    stringsAsFactors = FALSE
  )
}

test_that("persisted dynamic assignments define the gradebook rows", {
  events <- gradebook_test_events(
    item_label = c("q1", "q2", "q2"),
    correct = c("true", "false", "false"),
    assignment_id = c("abc123-a1", "abc123-a2", "abc123-a2")
  )
  assignments <- gradebook_test_assignments()

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  expect_equal(tables$gradebook$points_earned, 1)
  expect_equal(tables$gradebook$points_possible, 3)
  expect_equal(tables$gradebook$items_possible, 3)
  expect_setequal(tables$item_detail$item_label, c("q1", "q2", "q3"))
  expect_setequal(
    tables$item_detail$assignment_id,
    c("abc123-a1", "abc123-a2", "abc123-a3")
  )
  expect_true(all(tables$item_detail$assignment_reason == "fsrs_retrievability"))
})

test_that("multiple attempts at one item remain one persisted exposure", {
  events <- gradebook_test_events(
    item_label = rep("q1", 3),
    correct = c("false", "false", "true"),
    assignment_id = rep("abc123-a1", 3)
  )
  assignments <- gradebook_test_assignments()

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  q1 <- tables$item_detail[tables$item_detail$item_label == "q1", , drop = FALSE]

  expect_equal(nrow(q1), 1)
  expect_equal(q1$assignment_id, "abc123-a1")
  expect_equal(q1$attempts, 3)
  expect_true(q1$ever_correct)
  expect_equal(q1$points_earned, 1)
})

test_that("pre-assignment-id attempts still grade against persisted assignments", {
  events <- gradebook_test_events(
    item_label = "q1",
    correct = "true",
    assignment_id = NA_character_
  )
  assignments <- gradebook_test_assignments()

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  q1 <- tables$item_detail[tables$item_detail$item_label == "q1", , drop = FALSE]
  expect_equal(q1$attempts, 1)
  expect_equal(tables$gradebook$points_earned, 1)
})

test_that("mismatched nonblank assignment IDs are excluded", {
  events <- gradebook_test_events(
    item_label = "q1",
    correct = "true",
    assignment_id = "wrong-assignment-id"
  )
  assignments <- gradebook_test_assignments()

  expect_warning(
    tables <- build_gradebook_tables(
      events = events,
      assignments = assignments,
      manifest = gradebook_test_manifest(),
      course_id = "R101"
    ),
    "were excluded"
  )

  q1 <- tables$item_detail[tables$item_detail$item_label == "q1", , drop = FALSE]
  expect_equal(q1$attempts, 0)
  expect_equal(q1$points_earned, 0)
})

test_that("identity backfill fills missing IDs without overwriting explicit IDs", {
  events <- gradebook_test_events(
    item_label = rep("q1", 3),
    correct = rep("true", 3),
    assignment_id = c(NA_character_, "student_a-a1", "student_b-a1"),
    student_id = c(NA_character_, "student_a", "student_b")
  )
  assignments <- dplyr::bind_rows(
    gradebook_test_assignments(student_id = "student_a"),
    gradebook_test_assignments(student_id = "student_b")
  )

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  q1 <- tables$item_detail[
    tables$item_detail$item_label == "q1",
    c("student_id", "attempts"),
    drop = FALSE
  ]

  expect_equal(q1$attempts[q1$student_id == "student_a"], 2)
  expect_equal(q1$attempts[q1$student_id == "student_b"], 1)
})

test_that("dynamic assignment subset sets the denominator", {
  events <- gradebook_test_events(
    item_label = "q1",
    correct = "true",
    assignment_id = "abc123-a1"
  )
  assignments <- gradebook_test_assignments(c("q1", "q2"))

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  expect_equal(tables$gradebook$points_possible, 2)
  expect_equal(tables$gradebook$items_possible, 2)
  expect_setequal(tables$item_detail$item_label, c("q1", "q2"))
})

test_that("assignment-only audit IDs do not become gradebook students", {
  events <- gradebook_test_events()
  assignments <- gradebook_test_assignments(
    student_id = "INSTRUCTOR_ASSIGNMENT_TEST_1"
  )

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  expect_equal(nrow(tables$gradebook), 0)
  expect_equal(nrow(tables$item_detail), 0)
})

test_that("logging-test events do not become gradebook students", {
  events <- gradebook_test_events(
    item_label = "webhook_test",
    correct = "true",
    student_id = "INSTRUCTOR_TEST"
  )
  events$event <- "logging_test"

  tables <- build_gradebook_tables(
    events = events,
    assignments = empty_assignment_table(),
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  expect_equal(nrow(tables$gradebook), 0)
  expect_equal(nrow(tables$item_detail), 0)
})

test_that("roster students without persisted rows have no grading denominator", {
  events <- gradebook_test_events()
  assignments <- empty_assignment_table()
  roster <- data.frame(
    student_id = "no_show",
    student_name = "No Show",
    stringsAsFactors = FALSE
  )

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    roster = roster,
    course_id = "R101"
  )

  expect_equal(tables$gradebook$points_earned, 0)
  expect_equal(tables$gradebook$points_possible, 0)
  expect_equal(tables$gradebook$items_possible, 0)
  expect_true(is.na(tables$gradebook$percent))
  expect_equal(nrow(tables$item_detail), 0)
  expect_equal(nrow(tables$effective_assignments), 0)
})

test_that("retired rolling assignments remain valid historical gradebook rows", {
  assignments <- gradebook_test_assignments(c("q1", "q2"))
  assignments$assignment_status <- c("retired", "active")
  assignments$retired_at_utc <- c("2026-08-17T12:05:00Z", "")
  assignments$retired_reason <- c("correct", "")
  assignments$retired_request_id <- c("req-retire-q1", "")
  events <- gradebook_test_events(
    item_label = "q1",
    correct = "true",
    assignment_id = "abc123-a1"
  )

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  expect_equal(tables$gradebook$points_possible, 2)
  expect_equal(tables$gradebook$points_earned, 1)
  expect_setequal(tables$item_detail$assignment_id, c("abc123-a1", "abc123-a2"))
})

test_that("repeated literal questions remain distinct rolling exposures", {
  assignments <- gradebook_test_assignments(c("q1", "q1"))
  assignments$assignment_id <- c("abc123-old-q1", "abc123-new-q1")
  assignments$assigned_at_utc <- c(
    "2026-08-17T12:00:00Z",
    "2026-08-17T12:10:00Z"
  )
  events <- gradebook_test_events(
    item_label = c("q1", "q1"),
    correct = c("true", "false"),
    assignment_id = c("abc123-old-q1", "abc123-new-q1")
  )

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  q1 <- tables$item_detail[tables$item_detail$item_label == "q1", , drop = FALSE]
  expect_equal(nrow(q1), 2)
  expect_setequal(q1$assignment_id, c("abc123-old-q1", "abc123-new-q1"))
  expect_equal(sum(q1$attempts), 2)
  expect_equal(sum(q1$points_earned), 1)
  expect_equal(tables$gradebook$points_possible, 2)
})


test_that("rolling report is cumulative across historical week provenance", {
  assignments <- gradebook_test_assignments(c("q1", "q2"))
  assignments$week_id <- c("week-01", "week-02")
  events <- gradebook_test_events(
    item_label = c("q1", "q2"),
    correct = c("true", "true"),
    assignment_id = c("abc123-a1", "abc123-a2")
  )
  events$week_id <- c("week-01", "week-02")

  tables <- build_gradebook_tables(
    events = events,
    assignments = assignments,
    manifest = gradebook_test_manifest(),
    course_id = "R101"
  )

  expect_equal(tables$gradebook$points_possible, 2)
  expect_equal(tables$gradebook$points_earned, 2)
  expect_setequal(tables$item_detail$assignment_id, c("abc123-a1", "abc123-a2"))
})

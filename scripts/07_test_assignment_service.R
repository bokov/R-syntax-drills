source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")

library(httr2)

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url in R/app_config.R first.")
}

bank <- build_question_bank_manifest()
settings <- validate_assignment_config(APP_CONFIG, bank)
curriculum <- settings$topic_priority
first_topic <- curriculum[[1]]
service_timeout_sec <- 30

service_timing_number <- function(x) {
  if (is.null(x) || !length(x)) return(NA_real_)
  suppressWarnings(as.numeric(x[[1]]))
}

print_service_timing <- function(label, body, round_trip_ms) {
  timing <- body$service_timing
  if (is.null(timing)) {
    stop(
      "The assignment service did not return timing diagnostics. ",
      "Deploy the current google-apps-script/Code.gs as a new web-app version first."
    )
  }

  handler_total_ms <- service_timing_number(timing$total_ms)
  marks <- timing$marks_ms
  mark_values <- if (is.null(marks) || !length(marks)) {
    numeric()
  } else {
    vapply(marks, service_timing_number, numeric(1))
  }
  stage_values <- if (length(mark_values)) {
    c(mark_values[[1]], diff(mark_values))
  } else {
    numeric()
  }
  names(stage_values) <- names(mark_values)

  message("\nService timing -- ", label)
  message(sprintf("  %-30s %8.3f s", "round_trip", round_trip_ms / 1000))
  message(sprintf("  %-30s %8.3f s", "handler_total", handler_total_ms / 1000))
  if (length(stage_values)) {
    for (ii in seq_along(stage_values)) {
      message(sprintf(
        "  %-30s %8.3f s",
        names(stage_values)[[ii]],
        stage_values[[ii]] / 1000
      ))
    }
  }
  message(sprintf(
    "  %-30s %8.3f s",
    "outside_handler_or_network",
    max(0, round_trip_ms - handler_total_ms) / 1000
  ))
}

post_test_assignment_service <- function(payload, label) {
  payload$include_timing <- TRUE
  started <- proc.time()[["elapsed"]]
  body <- post_assignment_service(payload, timeout_sec = service_timeout_sec)
  round_trip_ms <- (proc.time()[["elapsed"]] - started) * 1000
  print_service_timing(label, body, round_trip_ms)
  body
}

eligible <- bank[
  bank$event == "exercise_result" &
    bank$points > 0 &
    bank$topic %in% curriculum,
  ,
  drop = FALSE
]
first_topic_starters <- eligible$item_label[
  eligible$topic == first_topic & eligible$starter_question %in% TRUE
]

student_id <- paste0(
  "INSTRUCTOR_ASSIGNMENT_TEST_",
  format(Sys.time(), "%Y%m%d%H%M%S", tz = "UTC")
)

lookup <- post_test_assignment_service(
  assignment_service_payload(
    "get_active_assignments",
    student_id = student_id
  ),
  "fresh active lookup"
)
if (length(lookup$assignments)) {
  stop("Fresh rolling-queue test ID unexpectedly already has active assignments.")
}

created <- post_test_assignment_service(
  assignment_service_payload(
    "get_or_create_active_assignments",
    student_id = student_id
  ),
  "initial queue creation"
)
if (!isTRUE(created$created)) {
  stop("Expected the first rolling-queue call to create active assignments.")
}
created_table <- assignment_response_table(created)
if (nrow(created_table) != settings$queue_size) {
  stop("Initial active queue did not contain queue_size rows.")
}
if (!all(created_table$assignment_status == "active")) {
  stop("Initial rolling queue contained a non-active assignment row.")
}
if (!all(created_table$topic == first_topic)) {
  stop("Initial rolling queue advanced beyond the first curriculum topic.")
}
if (!all(first_topic_starters %in% created_table$item_label)) {
  stop("Initial rolling queue did not contain every first-topic starter question.")
}

created_ids <- created_table$assignment_id

repeated <- post_test_assignment_service(
  assignment_service_payload(
    "get_or_create_active_assignments",
    student_id = student_id
  ),
  "repeat queue load"
)
if (isTRUE(repeated$created)) {
  stop("Repeated rolling-queue load created duplicate assignments.")
}
repeated_table <- assignment_response_table(repeated)
if (!identical(created_ids, repeated_table$assignment_id)) {
  stop("Repeated rolling-queue load did not return the original active queue in order.")
}

make_test_event <- function(assignment, correct, request_id) {
  list(
    schema_version = "1",
    request_type = "log_event",
    request_id = request_id,
    client_timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
    course_id = APP_CONFIG$course_id,
    week_id = APP_CONFIG$week_id,
    session_token = paste0("SERVICE_TEST_", student_id),
    student_id = student_id,
    student_name = "Instructor assignment-service test",
    event = "exercise_result",
    item_label = assignment$item_label[[1]],
    topic = assignment$topic[[1]],
    assignment_id = assignment$assignment_id[[1]],
    attempt_id = paste0("attempt-", request_id),
    submitted_code = "1 + 1",
    correct = correct,
    checked = TRUE,
    restore = FALSE,
    queue_size = settings$queue_size,
    topic_priority = unname(curriculum),
    # Transitional PR14 alias.
    unlocked_topics = unname(curriculum)
  )
}

target <- created_table[1, , drop = FALSE]

wrong_payload <- make_test_event(
  target,
  FALSE,
  make_service_request_id("rolling-wrong")
)
wrong <- post_test_assignment_service(wrong_payload, "wrong first attempt")
wrong_table <- assignment_response_table(wrong)
if (!identical(created_ids, wrong_table$assignment_id)) {
  stop("Incorrect first attempt changed the active queue.")
}

correct_payload <- make_test_event(
  target,
  TRUE,
  make_service_request_id("rolling-correct")
)
correct <- post_test_assignment_service(correct_payload, "correct after retry")
correct_table <- assignment_response_table(correct)

if (nrow(correct_table) != settings$queue_size) {
  stop("Correct answer did not refill the rolling queue to queue_size.")
}
if (target$assignment_id[[1]] %in% correct_table$assignment_id) {
  stop("Correctly answered assignment remained active.")
}
new_ids <- setdiff(correct_table$assignment_id, created_ids)
if (length(new_ids) != 1L) {
  stop("Correct answer should retire exactly one assignment and create exactly one replacement.")
}
if (!identical(tail(correct_table$assignment_id, 1), new_ids)) {
  stop("Replacement question was not returned last in oldest-to-newest queue order.")
}
retry_replacement <- correct_table[
  correct_table$assignment_id %in% new_ids,
  ,
  drop = FALSE
]
if (
  retry_replacement$topic[[1]] != target$topic[[1]] ||
  retry_replacement$assignment_reason[[1]] != "same_topic_retry"
) {
  stop("A question missed on its first attempt was not replaced from the same topic.")
}

# Reposting the identical successful request must be a no-op. This is the
# server-side prerequisite for the future local outbox retry mechanism.
duplicate <- post_test_assignment_service(correct_payload, "duplicate correct retry")
if (!isTRUE(duplicate$duplicate)) {
  stop("Reposting the same correct request_id was not recognized as a duplicate.")
}
duplicate_table <- assignment_response_table(duplicate)
if (!identical(correct_table$assignment_id, duplicate_table$assignment_id)) {
  stop("Duplicate correct request changed the rolling queue.")
}

# A first-try correct answer this early cannot satisfy the 10-observation/90%
# mastery rule, so it should remain at the current frontier unless an older
# introduced topic is due. This fresh test student has only the first topic.
fresh_target <- correct_table[
  correct_table$assignment_id != new_ids[[1]],
  ,
  drop = FALSE
][1, , drop = FALSE]
first_try_payload <- make_test_event(
  fresh_target,
  TRUE,
  make_service_request_id("rolling-first-try")
)
first_try <- post_test_assignment_service(first_try_payload, "first-try correct")
first_try_table <- assignment_response_table(first_try)
first_try_new_ids <- setdiff(
  first_try_table$assignment_id,
  correct_table$assignment_id
)
if (length(first_try_new_ids) != 1L) {
  stop("First-try correct answer did not create exactly one replacement.")
}
first_try_replacement <- first_try_table[
  first_try_table$assignment_id %in% first_try_new_ids,
  ,
  drop = FALSE
]
if (
  first_try_replacement$topic[[1]] != first_topic ||
  first_try_replacement$assignment_reason[[1]] != "frontier_practice"
) {
  stop("An unmastered frontier advanced after an early first-try correct answer.")
}

final_lookup <- post_test_assignment_service(
  assignment_service_payload(
    "get_active_assignments",
    student_id = student_id
  ),
  "final active lookup"
)
final_table <- assignment_response_table(final_lookup)
if (!identical(first_try_table$assignment_id, final_table$assignment_id)) {
  stop("Active-assignment lookup did not return the current rolling queue.")
}

message("\nCurriculum-aware rolling assignment service test passed for student ID: ", student_id)
message("The test rows remain in assignments/events/reviews as an audit trail.")
source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")

library(httr2)

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url in R/app_config.R first.")
}

bank <- build_question_bank_manifest()
settings <- validate_assignment_config(APP_CONFIG, bank)

eligible <- bank[
  bank$event == "exercise_result" &
    bank$points > 0 &
    bank$topic %in% settings$unlocked_topics,
  ,
  drop = FALSE
]
starter_labels <- eligible$item_label[eligible$starter_question %in% TRUE]

student_id <- paste0(
  "INSTRUCTOR_ASSIGNMENT_TEST_",
  format(Sys.time(), "%Y%m%d%H%M%S", tz = "UTC")
)

lookup <- post_assignment_service(
  assignment_service_payload(
    "get_assignments",
    student_id = student_id
  )
)
if (length(lookup$assignments)) {
  stop("Fresh assignment-service test ID unexpectedly already has assignments.")
}

created <- post_assignment_service(
  assignment_service_payload(
    "get_or_create_dynamic_assignments",
    student_id = student_id
  )
)
if (!isTRUE(created$created)) {
  stop("Expected the first dynamic assignment call to create assignments.")
}
created_table <- assignment_response_table(created)
if (!setequal(created_table$item_label, starter_labels)) {
  stop("First-week dynamic assignment did not equal the eligible starter set.")
}
if (!all(created_table$assignment_reason == "starter")) {
  stop("First-week assignment_reason was not 'starter'.")
}

created_ids <- created_table$assignment_id

repeated <- post_assignment_service(
  assignment_service_payload(
    "get_or_create_dynamic_assignments",
    student_id = student_id
  )
)
if (isTRUE(repeated$created)) {
  stop("Repeated same-week dynamic call created duplicate assignments.")
}
repeated_table <- assignment_response_table(repeated)
if (!setequal(created_ids, repeated_table$assignment_id)) {
  stop("Repeated same-week dynamic call did not return the original assignments.")
}

next_config <- APP_CONFIG
next_config$week_id <- paste0(
  APP_CONFIG$week_id,
  "-service-test-next-",
  format(Sys.time(), "%Y%m%d%H%M%S", tz = "UTC")
)

next_week <- post_assignment_service(
  assignment_service_payload(
    "get_or_create_dynamic_assignments",
    student_id = student_id,
    config = next_config
  ),
  config = next_config
)
if (!isTRUE(next_week$created)) {
  stop("Expected a new synthetic week to create a returning-student assignment.")
}
next_table <- assignment_response_table(next_week)
if (nrow(next_table) != settings$questions_per_week) {
  stop("Returning-student assignment did not contain questions_per_week rows.")
}
if (!all(next_table$assignment_reason == "fsrs_retrievability")) {
  stop("Returning-student assignment_reason was not 'fsrs_retrievability'.")
}
if (!all(next_table$topic %in% settings$unlocked_topics)) {
  stop("Returning-student assignment included a locked topic.")
}

# This smoke-test ID never submits a question. Its first-week assignment rows
# therefore do not count as literal exposures; next-week literal tie-breaking is
# allowed to select either previously assigned or never-assigned probes.

next_repeat <- post_assignment_service(
  assignment_service_payload(
    "get_or_create_dynamic_assignments",
    student_id = student_id,
    config = next_config
  ),
  config = next_config
)
if (isTRUE(next_repeat$created)) {
  stop("Repeated synthetic next-week call created duplicate assignments.")
}
next_repeat_table <- assignment_response_table(next_repeat)
if (!setequal(next_table$assignment_id, next_repeat_table$assignment_id)) {
  stop("Repeated synthetic next-week call did not return the original assignments.")
}

message("Adaptive assignment service test passed for student ID: ", student_id)
message("The test rows remain in the assignments tab as an audit trail.")

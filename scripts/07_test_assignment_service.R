source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")

library(httr2)

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url in R/app_config.R first.")
}

manifest <- build_question_manifest()
item_labels <- head(manifest$item_label, 2)
if (!length(item_labels)) stop("The current assignment contains no questions.")

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
    "get_or_create_assignments",
    student_id = student_id,
    item_labels = item_labels,
    assignment_reason = "manual_test"
  )
)
if (!isTRUE(created$created)) {
  stop("Expected the first get_or_create call to create assignments.")
}
if (length(created$assignments) != length(item_labels)) {
  stop("Assignment service returned the wrong number of created assignments.")
}

created_ids <- vapply(
  created$assignments,
  function(x) as.character(x$assignment_id),
  character(1)
)

repeated <- post_assignment_service(
  assignment_service_payload(
    "get_or_create_assignments",
    student_id = student_id,
    item_labels = rev(item_labels),
    assignment_reason = "manual_test_repeat"
  )
)
if (isTRUE(repeated$created)) {
  stop("Repeated get_or_create call created duplicate assignments.")
}

repeated_ids <- vapply(
  repeated$assignments,
  function(x) as.character(x$assignment_id),
  character(1)
)
if (!setequal(created_ids, repeated_ids)) {
  stop("Repeated get_or_create call did not return the original assignments.")
}

lookup_again <- post_assignment_service(
  assignment_service_payload(
    "get_assignments",
    student_id = student_id
  )
)
lookup_ids <- vapply(
  lookup_again$assignments,
  function(x) as.character(x$assignment_id),
  character(1)
)
if (!setequal(created_ids, lookup_ids)) {
  stop("Assignment lookup did not return the created assignments.")
}

message("Assignment service test passed for student ID: ", student_id)
message("The test rows remain in the assignments tab as an audit trail.")

source("R/app_config.R")

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url in R/app_config.R first.")
}

payload <- list(
  schema_version = "1",
  request_id = paste0("manual-test-", as.integer(Sys.time())),
  client_timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  course_id = APP_CONFIG$course_id,
  week_id = APP_CONFIG$week_id,
  session_token = "manual-test",
  student_id = "INSTRUCTOR_TEST",
  student_name = "",
  event = "logging_test",
  item_label = "webhook_test",
  assignment_id = "",
  attempt_id = "",
  submitted_code = "",
  correct = TRUE,
  answer = "",
  checked = TRUE,
  restore = FALSE,
  time_elapsed_sec = 0,
  timeout_exceeded = FALSE,
  error_message = ""
)

response <- httr2::request(APP_CONFIG$webhook_url) |>
  httr2::req_method("POST") |>
  httr2::req_body_json(payload, auto_unbox = TRUE, null = "null") |>
  httr2::req_timeout(8) |>
  httr2::req_perform()

print(httr2::resp_body_json(response, simplifyVector = TRUE))
message("Check the events tab in the Google Sheet for an INSTRUCTOR_TEST row.")

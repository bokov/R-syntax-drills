source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")

library(googlesheets4)

if (grepl("PASTE_", APP_CONFIG$google_sheet_id, fixed = TRUE)) {
  stop("Set APP_CONFIG$google_sheet_id in R/app_config.R first.")
}

bank_manifest <- build_question_bank_manifest()
validate_assignment_config(APP_CONFIG, bank_manifest)
question_bank <- prepare_question_bank_sync(bank_manifest)
bank_version <- unique(question_bank$bank_version)

if (length(bank_version) != 1 || !nzchar(bank_version)) {
  stop("Question-bank sync did not produce exactly one bank_version.")
}

gs4_auth()

sheet_write(
  question_bank,
  ss = APP_CONFIG$google_sheet_id,
  sheet = "question_bank"
)

message(
  "Synced ", nrow(question_bank),
  " canonical question(s) to the private question_bank tab; bank version ",
  bank_version, "."
)
message(
  "Available topics: ",
  paste(sort(unique(question_bank$topic)), collapse = ", "),
  "."
)
message(
  "Curriculum priority: ", paste(APP_CONFIG$topic_priority, collapse = ", "),
  "; active queue size: ", APP_CONFIG$queue_size, "."
)

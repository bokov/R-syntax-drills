source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")

library(googlesheets4)

if (grepl("PASTE_", APP_CONFIG$google_sheet_id, fixed = TRUE)) {
  stop("Set APP_CONFIG$google_sheet_id in R/app_config.R first.")
}

bank_manifest <- build_question_bank_manifest()
question_bank <- prepare_question_bank_sync(bank_manifest)

gs4_auth()

sheet_write(
  question_bank,
  ss = APP_CONFIG$google_sheet_id,
  sheet = "question_bank"
)

message(
  "Synced ", nrow(question_bank),
  " canonical question(s) to the private question_bank tab."
)

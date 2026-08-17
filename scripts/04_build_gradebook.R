source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")
source("R/gradebook.R")

library(googlesheets4)
library(dplyr)
library(tidyr)
library(readr)

if (grepl("PASTE_", APP_CONFIG$google_sheet_id, fixed = TRUE)) {
  stop("Set APP_CONFIG$google_sheet_id in R/app_config.R first.")
}

manifest <- build_question_manifest()

gs4_auth()

events <- read_sheet(
  APP_CONFIG$google_sheet_id,
  sheet = "events",
  col_types = "c"
)

if (!nrow(events)) stop("The events sheet contains no rows.")

assignments <- read_sheet(
  APP_CONFIG$google_sheet_id,
  sheet = "assignments",
  col_types = "c"
)

roster <- NULL
if (file.exists("roster.csv")) {
  roster <- read_csv("roster.csv", show_col_types = FALSE)
}

tables <- build_gradebook_tables(
  events = events,
  assignments = assignments,
  manifest = manifest,
  roster = roster,
  course_id = APP_CONFIG$course_id,
  week_id = APP_CONFIG$week_id,
  deadline_utc = APP_CONFIG$deadline_utc
)

gradebook <- tables$gradebook
item_detail <- tables$item_detail

dir.create("output", showWarnings = FALSE)
week_safe <- gsub("[^A-Za-z0-9_-]", "_", APP_CONFIG$week_id)
write_csv(gradebook, file.path("output", paste0("grades_", week_safe, ".csv")))
write_csv(item_detail, file.path("output", paste0("item_detail_", week_safe, ".csv")))

# Also maintain human-readable grade tabs in the same Google spreadsheet.
sheet_write(
  gradebook,
  ss = APP_CONFIG$google_sheet_id,
  sheet = paste0("grades_", week_safe)
)
sheet_write(
  item_detail,
  ss = APP_CONFIG$google_sheet_id,
  sheet = paste0("detail_", week_safe)
)

print(gradebook)
message("Gradebook CSVs written to output/ and grade tabs updated in Google Sheets.")

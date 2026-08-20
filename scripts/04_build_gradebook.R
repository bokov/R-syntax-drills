source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")
source("R/player_builder.R")
source("R/gradebook.R")

library(googlesheets4)
library(dplyr)
library(tidyr)
library(readr)

if (grepl("PASTE_", APP_CONFIG$google_sheet_id, fixed = TRUE)) {
  stop("Set APP_CONFIG$google_sheet_id in R/app_config.R first.")
}

build_player_assets(config = APP_CONFIG)
manifest <- read_question_manifest()

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
  deadline_utc = APP_CONFIG$deadline_utc
)

gradebook <- tables$gradebook
item_detail <- tables$item_detail

dir.create("output", showWarnings = FALSE)
write_csv(gradebook, file.path("output", "grades.csv"))
write_csv(item_detail, file.path("output", "item_detail.csv"))

sheet_write(
  gradebook,
  ss = APP_CONFIG$google_sheet_id,
  sheet = "grades"
)
sheet_write(
  item_detail,
  ss = APP_CONFIG$google_sheet_id,
  sheet = "detail"
)

print(gradebook)
message("Cumulative drill-report CSVs written to output/ and grades/detail tabs updated in Google Sheets.")

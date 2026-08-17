source("R/app_config.R")
source("R/question_manifest.R")

library(googlesheets4)
library(dplyr)
library(tidyr)
library(readr)

if (grepl("PASTE_", APP_CONFIG$google_sheet_id, fixed = TRUE)) {
  stop("Set APP_CONFIG$google_sheet_id in R/app_config.R first.")
}

manifest <- build_question_manifest()
scored_manifest <- manifest |>
  filter(event == "exercise_result", points > 0) |>
  select(event, item_label, topic, points)

if (!nrow(scored_manifest)) stop("The question manifest contains no scored exercises.")

gs4_auth()

events <- read_sheet(
  APP_CONFIG$google_sheet_id,
  sheet = "events",
  col_types = "c"
)

if (!nrow(events)) stop("The events sheet contains no rows.")

required <- c(
  "server_timestamp_utc", "week_id", "session_token", "student_id",
  "student_name", "event", "item_label", "correct"
)
missing <- setdiff(required, names(events))
if (length(missing)) stop("Missing event columns: ", paste(missing, collapse = ", "))

events <- events |>
  mutate(
    server_timestamp_utc = readr::parse_datetime(server_timestamp_utc),
    student_id = na_if(trimws(student_id), ""),
    student_name = na_if(trimws(student_name), ""),
    correct_bool = tolower(correct) == "true"
  ) |>
  filter(week_id == APP_CONFIG$week_id)

if (!is.na(APP_CONFIG$deadline_utc)) {
  deadline <- as.POSIXct(APP_CONFIG$deadline_utc, tz = "UTC")
  events <- events |> filter(server_timestamp_utc <= deadline)
}

# Backfill identity across a session. This rescues attempts made just before a
# student remembered to click Save identity.
identity_by_session <- events |>
  filter(!is.na(student_id)) |>
  arrange(server_timestamp_utc) |>
  group_by(session_token) |>
  summarise(
    session_student_id = dplyr::last(student_id),
    session_student_name = dplyr::last(student_name[!is.na(student_name)], default = NA_character_),
    .groups = "drop"
  )

events <- events |>
  select(-student_id, -student_name) |>
  left_join(identity_by_session, by = "session_token") |>
  rename(
    student_id = session_student_id,
    student_name = session_student_name
  )

unidentified <- events |>
  filter(is.na(student_id), event %in% c("exercise_result", "question_submission"))
if (nrow(unidentified)) {
  warning(nrow(unidentified), " graded event(s) could not be linked to a student ID.")
}

attempts <- events |>
  filter(!is.na(student_id)) |>
  inner_join(scored_manifest, by = c("event", "item_label")) |>
  group_by(student_id, student_name, event, item_label, topic, points) |>
  summarise(
    attempts = n(),
    ever_correct = any(correct_bool, na.rm = TRUE),
    first_correct_utc = if (any(correct_bool, na.rm = TRUE)) {
      min(server_timestamp_utc[correct_bool], na.rm = TRUE)
    } else {
      as.POSIXct(NA, tz = "UTC")
    },
    .groups = "drop"
  ) |>
  mutate(points_earned = if_else(ever_correct, points, 0))

# Use roster.csv when present so students with zero attempts still appear.
if (file.exists("roster.csv")) {
  roster <- read_csv("roster.csv", show_col_types = FALSE)
  if (!"student_id" %in% names(roster)) stop("roster.csv must contain student_id.")
  if (!"student_name" %in% names(roster)) roster$student_name <- NA_character_
  students <- roster |>
    transmute(
      student_id = as.character(student_id),
      student_name = as.character(student_name)
    )
} else {
  students <- events |>
    filter(
      !is.na(student_id),
      event %in% c("identity_saved", "exercise_result", "question_submission")
    ) |>
    group_by(student_id) |>
    summarise(
      student_name = dplyr::last(student_name[!is.na(student_name)], default = NA_character_),
      .groups = "drop"
    )
}

item_detail <- tidyr::crossing(
  students,
  scored_manifest
) |>
  left_join(
    attempts,
    by = c("student_id", "event", "item_label", "topic", "points")
  ) |>
  mutate(
    student_name = coalesce(student_name.x, student_name.y),
    attempts = coalesce(attempts, 0L),
    ever_correct = coalesce(ever_correct, FALSE),
    points_earned = coalesce(points_earned, 0)
  ) |>
  select(
    student_id, student_name, event, item_label, topic, points,
    attempts, ever_correct, first_correct_utc, points_earned
  )

gradebook <- item_detail |>
  group_by(student_id, student_name) |>
  summarise(
    points_earned = sum(points_earned),
    points_possible = sum(points),
    percent = 100 * points_earned / points_possible,
    items_correct = sum(ever_correct),
    items_possible = n(),
    .groups = "drop"
  ) |>
  arrange(student_name, student_id)

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

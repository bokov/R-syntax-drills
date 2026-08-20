APP_CONFIG <- list(
  course_id = "R101",
  week_id = "week-01",
  app_name = "r-syntax-drills",
  questions_per_week = 10L,
  # Transitional PR14 name: order these from earliest to most advanced topic.
  # PR15 will rename unlocked_topics to reflect its curriculum-priority meaning.
  unlocked_topics = c(
    "vector_creation",
    "vector_indexing"
  ),
  google_sheet_id = "PASTE_GOOGLE_SHEET_ID_HERE",
  webhook_url = "PASTE_APPS_SCRIPT_WEB_APP_URL_HERE",
  deadline_utc = NA_character_
)

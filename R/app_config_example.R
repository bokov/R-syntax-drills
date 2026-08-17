APP_CONFIG <- list(
  course_id = "ID_GOES_HERE",
  week_id = "week-01",
  app_name = "r-syntax-drill",
  google_sheet_id = "XXXXXXX-XXXXXX_XXXX-XXXXXXXXXXXXXXXXXXXXXXXX",
  webhook_url = "https://script.google.com/macros/s/XXXXXXXXX-XX-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/exec",
  deadline_utc = NA_character_,
  scored_items = data.frame(
    event = rep("exercise_result", 8),
    label = c(
      "assignment",
      "vector_index",
      "list_extract",
      "named_argument",
      "dollar_extract",
      "native_pipe",
      "function_definition",
      "logical_subset"
    ),
    points = rep(1, 8),
    stringsAsFactors = FALSE
  )
)

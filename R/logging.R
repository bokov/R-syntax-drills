# Server-side logging helpers. Event logging remains append-only. The same Apps
# Script also exposes active-assignment operations, but no grade/event read endpoint.

log_scalar <- function(x, default = NA) {
  if (is.null(x) || length(x) == 0) return(default)
  if (inherits(x, "html")) return(as.character(x))
  x[[1]]
}

make_request_id <- function() {
  paste0(
    format(Sys.time(), "%Y%m%d%H%M%OS6", tz = "UTC"), "-",
    paste(sample(c(letters, LETTERS, 0:9), 20, replace = TRUE), collapse = "")
  )
}

current_identity <- function(session) {
  identity <- tryCatch(
    shiny::isolate(session$userData$identity()),
    error = function(e) NULL
  )
  if (is.null(identity)) {
    identity <- list(student_id = NA_character_, student_name = NA_character_)
  }
  identity
}

current_assignment_id <- function(session, item_label) {
  if (is.null(item_label) || is.na(item_label) || !nzchar(item_label)) {
    return(NA_character_)
  }

  ids <- tryCatch(
    shiny::isolate(session$userData$assignment_ids()),
    error = function(e) NULL
  )
  if (is.null(ids) || !length(ids) || !item_label %in% names(ids)) {
    return(NA_character_)
  }

  as.character(ids[[item_label]])
}

set_logging_status <- function(session, ok, message) {
  tryCatch(
    session$userData$logging_status(list(ok = ok, message = message)),
    error = function(e) invisible(NULL)
  )
  invisible(NULL)
}

set_active_assignment_player <- function(session, assignments) {
  session$userData$assignment_ids(assignment_id_map(assignments))
  session$sendCustomMessage(
    "assignment:set",
    list(item_labels = unname(as.character(assignments$item_label)))
  )
  invisible(assignments)
}

post_log_event <- function(
  session,
  event,
  data = list(),
  config = APP_CONFIG,
  manifest = read_question_manifest()
) {
  identity <- current_identity(session)
  item_label <- log_scalar(data$label, NA_character_)
  assignment_id <- log_scalar(
    data$assignment_id,
    current_assignment_id(session, item_label)
  )
  graded_event <- event %in% c("exercise_result", "question_submission")

  payload <- list(
    schema_version = "1",
    request_id = make_request_id(),
    client_timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
    course_id = config$course_id,
    # Retained as provenance until the later weekly-config cleanup PR.
    week_id = config$week_id,
    session_token = session$token,
    student_id = log_scalar(identity$student_id, NA_character_),
    student_name = log_scalar(identity$student_name, NA_character_),
    event = event,
    item_label = item_label,
    topic = if (graded_event) question_topic(item_label, manifest) else NA_character_,
    assignment_id = assignment_id,
    attempt_id = log_scalar(data$id, NA_character_),
    submitted_code = log_scalar(data$code, NA_character_),
    correct = if (!is.null(data$feedback$correct)) {
      isTRUE(data$feedback$correct)
    } else {
      log_scalar(data$correct, NA)
    },
    answer = if (!is.null(data$answer)) paste(data$answer, collapse = " | ") else NA_character_,
    checked = log_scalar(data$checked, NA),
    restore = log_scalar(data$restore, NA),
    time_elapsed_sec = log_scalar(data$time_elapsed, NA_real_),
    timeout_exceeded = log_scalar(data$timeout_exceeded, NA),
    error_message = log_scalar(data$error_message, NA_character_)
  )

  if (graded_event) {
    settings <- assignment_config(config)
    payload$queue_size <- settings$queue_size
    payload$unlocked_topics <- unname(settings$unlocked_topics)
  }

  if (!nzchar(config$webhook_url) || grepl("PASTE_", config$webhook_url, fixed = TRUE)) {
    msg <- "Logging is not configured: set APP_CONFIG$webhook_url."
    set_logging_status(session, FALSE, msg)
    return(invisible(list(ok = FALSE, message = msg)))
  }

  result <- tryCatch({
    response <- httr2::request(config$webhook_url) |>
      # Do not add req_method("POST"): req_body_json() already selects POST,
      # and the Apps Script redirect path has previously rejected an explicit method.
      httr2::req_body_json(payload, auto_unbox = TRUE, null = "null") |>
      httr2::req_timeout(8) |>
      httr2::req_perform()

    body <- httr2::resp_body_json(response, simplifyVector = FALSE)
    if (!isTRUE(body$ok)) {
      stop(body$error %||% "The logging endpoint returned ok=false.")
    }

    # Incorrect answers leave the queue unchanged, so avoid moving DOM nodes and
    # disturbing learnr's just-rendered feedback. A correct answer retires the
    # current assignment and the returned queue must be applied immediately.
    if (
      graded_event &&
      isTRUE(as.logical(payload$correct)) &&
      !is.null(body$assignments)
    ) {
      assignments <- assignment_response_table(body)
      assignments <- validate_persisted_assignments(assignments, manifest)
      set_active_assignment_player(session, assignments)
    }

    list(
      ok = TRUE,
      message = "Responses are being recorded.",
      duplicate = isTRUE(body$duplicate)
    )
  }, error = function(e) {
    list(ok = FALSE, message = paste("Logging failed:", conditionMessage(e)))
  })

  set_logging_status(session, result$ok, result$message)
  invisible(result)
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

register_logging_handlers <- function(config = APP_CONFIG) {
  manifest <- read_question_manifest()

  learnr::event_register_handler("exercise_result", function(session, event, data) {
    post_log_event(session, event, data, config, manifest)
  })

  learnr::event_register_handler("question_submission", function(session, event, data) {
    post_log_event(session, event, data, config, manifest)
  })

  invisible(TRUE)
}

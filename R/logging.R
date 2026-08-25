# Server-side logging helpers. Event logging remains append-only. The same Apps
# Script also exposes active-assignment operations, but no grade/event read endpoint.

# Logging value and identity helpers -----------------------------------------

#' Extract one scalar value for an event payload
#'
#' Normalizes event fields that may be absent, vector-valued, or HTML before
#' they are serialized into the logging request.
#'
#' @param x Event field value.
#' @param default Value returned for `NULL` or length-zero input.
#' @return The first element of `x`, `x` converted to character for HTML values,
#'   or `default` for missing input.
#' @details Called only by `post_log_event()`. It has no within-repo function
#'   dependencies.
log_scalar <- function(x, default = NA) {
  if (is.null(x) || length(x) == 0) return(default)
  if (inherits(x, "html")) return(as.character(x))
  x[[1]]
}

#' Generate a request ID for one logged event
#'
#' Combines a UTC timestamp and random suffix so the Apps Script service can
#' deduplicate and trace individual event requests.
#'
#' @return A length-one character request ID.
#' @details Called only by `post_log_event()`. It has no within-repo function
#'   dependencies.
make_request_id <- function() {
  paste0(
    format(Sys.time(), "%Y%m%d%H%M%OS6", tz = "UTC"), "-",
    paste(sample(c(letters, LETTERS, 0:9), 20, replace = TRUE), collapse = "")
  )
}

#' Read the current Shiny session identity
#'
#' Isolates the reactive identity saved on the session and substitutes an
#' NA-valued identity when the reactive is unavailable or unset.
#'
#' @param session Current Shiny session.
#' @return A list containing `student_id` and `student_name`.
#' @details Called only by `post_log_event()`. It has no within-repo function
#'   dependencies.
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

#' Find the active assignment ID for a question label
#'
#' Reads the session's reactive item-label-to-assignment-ID map so a graded event
#' can be tied to the exact persisted question exposure.
#'
#' @param session Current Shiny session.
#' @param item_label Question label being logged.
#' @return The assignment ID as character, or `NA_character_` when unavailable.
#' @details Called only by `post_log_event()`. It has no within-repo function
#'   dependencies.
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

# Session state ---------------------------------------------------------------

#' Update the logging-status reactive for the student UI
#'
#' Stores success/failure state and a message for `index.Rmd` while tolerating
#' sessions where the logging-status reactive is unavailable.
#'
#' @param session Current Shiny session.
#' @param ok Logical status value (`TRUE`, `FALSE`, or `NA`).
#' @param message Student-facing status message.
#' @return Invisibly, `NULL`.
#' @details Called by `post_log_event()`. It has no within-repo function
#'   dependencies.
set_logging_status <- function(session, ok, message) {
  tryCatch(
    session$userData$logging_status(list(ok = ok, message = message)),
    error = function(e) invisible(NULL)
  )
  invisible(NULL)
}

#' Activate an assignment queue in the session and browser player
#'
#' Stores the item-label-to-assignment-ID map in session state and sends the
#' active item labels to the JavaScript assignment player.
#'
#' @param session Current Shiny session.
#' @param assignments Validated active assignment data frame.
#' @return Invisibly, `assignments`.
#' @details Called by `post_log_event()` after a correct graded response and by
#'   the `save_identity` observer in `index.Rmd`. Depends on
#'   `assignment_id_map()`.
set_active_assignment_player <- function(session, assignments) {
  session$userData$assignment_ids(assignment_id_map(assignments))
  session$sendCustomMessage(
    "assignment:set",
    list(item_labels = unname(as.character(assignments$item_label)))
  )
  invisible(assignments)
}

# Event logging ---------------------------------------------------------------

#' Build, send, and apply one tutorial logging event
#'
#' Combines learnr event data with identity, assignment, curriculum, and manifest
#' metadata; posts the resulting append-only event to Apps Script; and, after a
#' correct graded response, applies any replacement assignment queue returned by
#' the service. Logging failures are converted to status results so they do not
#' abort the tutorial session.
#'
#' @param session Current Shiny session.
#' @param event Learnr event name.
#' @param data Event data list supplied by learnr.
#' @param config Runtime configuration list.
#' @param manifest Current question manifest.
#' @return Invisibly, a result list containing `ok`, `message`, and on success
#'   `duplicate`.
#' @details Called directly by the `identity_saved` path in `index.Rmd` and by
#'   both callbacks registered in `register_logging_handlers()`. Depends on
#'   `read_question_manifest()` through its default, `current_identity()`,
#'   `log_scalar()`, `current_assignment_id()`, `make_request_id()`,
#'   `question_topic()`, `assignment_config()`, `scored_manifest_labels()`,
#'   `%||%`, `assignment_response_table()`,
#'   `validate_persisted_assignments()`, `set_active_assignment_player()`, and
#'   `set_logging_status()`.
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
    payload$topic_priority <- unname(settings$topic_priority)
    payload$reconcile_bank <- TRUE
    payload$available_item_labels <- unname(scored_manifest_labels(manifest))
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
      httr2::req_timeout(30) |>
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

# Utility helpers -------------------------------------------------------------

#' Substitute a fallback for a null or empty value
#'
#' Provides the small null-coalescing operation used for optional Apps Script
#' response fields.
#'
#' @param x Value to return unless it is `NULL` or length zero.
#' @param y Fallback value.
#' @return `y` when `x` is `NULL` or empty; otherwise `x`.
#' @details Called by `post_log_event()` when interpreting an Apps Script error
#'   body. No other within-repository caller was found.
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Handler registration --------------------------------------------------------

#' Register learnr event handlers for grading/logging events
#'
#' Connects both `exercise_result` and `question_submission` learnr events to the
#' common `post_log_event()` pipeline using the configuration and manifest
#' captured at registration time.
#'
#' @param config Runtime configuration list captured by the handlers.
#' @param manifest Question manifest captured by the handlers.
#' @return Invisibly, `TRUE` after both handlers are registered.
#' @details Called from the `logging-start` server-start chunk in `index.Rmd`.
#'   Depends on `read_question_manifest()` through its default and
#'   `post_log_event()`.
register_logging_handlers <- function(
  config = APP_CONFIG,
  manifest = read_question_manifest()
) {
  learnr::event_register_handler("exercise_result", function(session, event, data) {
    post_log_event(session, event, data, config, manifest)
  })

  learnr::event_register_handler("question_submission", function(session, event, data) {
    post_log_event(session, event, data, config, manifest)
  })

  invisible(TRUE)
}

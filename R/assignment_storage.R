QUESTION_BANK_COLUMNS <- c(
  "item_label",
  "event",
  "topic",
  "points",
  "starter_question"
)

QUESTION_BANK_SYNC_COLUMNS <- c(
  QUESTION_BANK_COLUMNS,
  "legacy_unused_1",
  "legacy_unused_2"
)

ASSIGNMENT_COLUMNS <- c(
  "assignment_id",
  "course_id",
  "week_id",
  "student_id",
  "item_label",
  "topic",
  "points",
  "assigned_at_utc",
  "assignment_reason",
  "assignment_status",
  "retired_at_utc",
  "retired_reason",
  "retired_request_id"
)

# Question-bank synchronization ----------------------------------------------

#' Prepare canonical question metadata for the Apps Script question-bank tab
#'
#' Validates the canonical manifest fields needed by the assignment service,
#' rejects duplicate IDs and unusable topics, and appends the two legacy columns
#' expected by the existing Google Sheet schema.
#'
#' @param manifest Canonical question-bank manifest data frame.
#' @return A data frame containing `QUESTION_BANK_SYNC_COLUMNS` in backend sheet
#'   order.
#' @details Called by `scripts/06_sync_question_bank.R` before writing the
#'   `question_bank` sheet and directly by `test-assignment_storage.R`. It uses
#'   `QUESTION_BANK_COLUMNS` and `QUESTION_BANK_SYNC_COLUMNS` but has no
#'   within-repo function dependencies.
prepare_question_bank_sync <- function(manifest) {
  missing <- setdiff(QUESTION_BANK_COLUMNS, names(manifest))
  if (length(missing)) {
    stop(
      "Question-bank manifest is missing required column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  out <- manifest[, QUESTION_BANK_COLUMNS, drop = FALSE]

  if (anyDuplicated(out$item_label)) {
    stop("Question-bank sync data contain duplicate item_label values.")
  }
  if (any(is.na(out$item_label) | !nzchar(out$item_label))) {
    stop("Question-bank sync data contain a missing item_label.")
  }
  if (any(is.na(out$topic) | !nzchar(out$topic) | out$topic == "unassigned")) {
    stop("Question-bank sync data contain missing or unassigned topics.")
  }

  out$legacy_unused_1 <- ""
  out$legacy_unused_2 <- ""
  out[, QUESTION_BANK_SYNC_COLUMNS, drop = FALSE]
}

# Assignment curriculum configuration ----------------------------------------

#' Normalize active-queue assignment configuration
#'
#' Validates the queue size and ordered curriculum topics that are sent to the
#' assignment service and used when graded events request a replacement item.
#'
#' @param config Runtime/authoring configuration list, normally `APP_CONFIG`.
#' @return A list containing integer `queue_size` and character
#'   `topic_priority`.
#' @details Called by `validate_assignment_config()`,
#'   `assignment_service_payload()`, and `post_log_event()`, and directly by
#'   `test-assignment_storage.R`. It has no within-repo function dependencies.
assignment_config <- function(config = APP_CONFIG) {
  if (is.null(config$queue_size) || length(config$queue_size) != 1) {
    stop("APP_CONFIG$queue_size must be one positive integer.")
  }

  queue_size <- suppressWarnings(as.numeric(config$queue_size))
  if (
    is.na(queue_size) ||
    !is.finite(queue_size) ||
    queue_size < 1 ||
    queue_size != floor(queue_size) ||
    queue_size > 500
  ) {
    stop("APP_CONFIG$queue_size must be an integer from 1 through 500.")
  }

  topic_priority <- trimws(as.character(config$topic_priority))
  topic_priority <- topic_priority[nzchar(topic_priority)]
  if (!length(topic_priority)) {
    stop("APP_CONFIG$topic_priority must contain the ordered topic curriculum.")
  }
  if (anyDuplicated(topic_priority)) {
    stop("APP_CONFIG$topic_priority must not contain duplicates.")
  }

  list(
    queue_size = as.integer(queue_size),
    topic_priority = topic_priority
  )
}

#' Validate assignment configuration against the canonical bank
#'
#' Checks that configured topics exist, each curriculum topic contains scored
#' exercises, and the first topic has enough distinct questions and a starter
#' set that fits within the active queue.
#'
#' @param config Runtime/authoring configuration list, normally `APP_CONFIG`.
#' @param bank_manifest Optional canonical question-bank manifest. When `NULL`,
#'   only scalar configuration validation is performed.
#' @return Invisibly, the normalized settings returned by
#'   `assignment_config()`.
#' @details Called by `build_player_assets()`, `scripts/06_sync_question_bank.R`,
#'   and `test-assignment_storage.R`. Depends on `assignment_config()` and the
#'   `QUESTION_BANK_COLUMNS` schema constant.
validate_assignment_config <- function(config = APP_CONFIG, bank_manifest = NULL) {
  settings <- assignment_config(config)

  if (is.null(bank_manifest)) return(invisible(settings))

  missing <- setdiff(QUESTION_BANK_COLUMNS, names(bank_manifest))
  if (length(missing)) {
    stop(
      "Canonical question bank is missing required column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  known_topics <- sort(unique(bank_manifest$topic[bank_manifest$topic != "unassigned"]))
  unknown_topics <- setdiff(settings$topic_priority, known_topics)
  if (length(unknown_topics)) {
    stop(
      "APP_CONFIG$topic_priority contains unknown curriculum topic(s): ",
      paste(unknown_topics, collapse = ", "),
      "."
    )
  }

  scored_exercises <- bank_manifest[
    bank_manifest$event == "exercise_result" &
      bank_manifest$points > 0,
    ,
    drop = FALSE
  ]

  empty_topics <- settings$topic_priority[
    !settings$topic_priority %in% unique(scored_exercises$topic)
  ]
  if (length(empty_topics)) {
    stop(
      "Curriculum topic(s) contain no scored exercise questions: ",
      paste(empty_topics, collapse = ", "),
      "."
    )
  }

  first_topic <- settings$topic_priority[[1]]
  first_topic_questions <- scored_exercises[
    scored_exercises$topic == first_topic,
    ,
    drop = FALSE
  ]
  if (nrow(first_topic_questions) < settings$queue_size) {
    stop(
      "The first curriculum topic, ", first_topic, ", has only ",
      nrow(first_topic_questions), " scored exercise question(s), but active queue size ",
      settings$queue_size, " requires that many distinct initial questions."
    )
  }

  first_topic_starters <- first_topic_questions[
    first_topic_questions$starter_question %in% TRUE,
    ,
    drop = FALSE
  ]
  if (!nrow(first_topic_starters)) {
    stop(
      "The first curriculum topic has no starter questions. Mark at least one scored ",
      "exercise in ", first_topic, " with starter_question=TRUE."
    )
  }
  if (nrow(first_topic_starters) > settings$queue_size) {
    stop(
      "There are ", nrow(first_topic_starters),
      " starter questions in the first curriculum topic but the active queue size is only ",
      settings$queue_size, ". Increase the queue or reduce that starter set."
    )
  }

  invisible(settings)
}

# Assignment-service requests -------------------------------------------------

#' Generate an assignment-service request ID
#'
#' Combines a request-family prefix, UTC timestamp, and random suffix to produce
#' an identifier used for service-side idempotency and tracing.
#'
#' @param prefix Character prefix describing the request family.
#' @return A length-one character request ID.
#' @details Called only by `assignment_service_payload()`. It has no within-repo
#'   function dependencies.
make_service_request_id <- function(prefix = "assignment") {
  paste0(
    prefix, "-",
    format(Sys.time(), "%Y%m%d%H%M%OS6", tz = "UTC"), "-",
    paste(sample(c(letters, LETTERS, 0:9), 16, replace = TRUE), collapse = "")
  )
}

#' Return scored exercise labels from a manifest
#'
#' Extracts unique positive-point `exercise_result` item labels so requests can
#' tell the backend which canonical questions are currently available.
#'
#' @param manifest Question-manifest data frame, or `NULL`.
#' @return A character vector of unique scored item labels, possibly empty.
#' @details Called by `assignment_service_payload()` and `post_log_event()`. It
#'   has no within-repo function dependencies.
scored_manifest_labels <- function(manifest) {
  if (is.null(manifest) || !nrow(manifest)) return(character())
  unique(as.character(manifest$item_label[
    manifest$event == "exercise_result" & manifest$points > 0
  ]))
}

#' Build an active-assignment service request
#'
#' Validates the request type and student ID, adds course and bank-reconciliation
#' metadata, and for create requests includes the active queue size and ordered
#' curriculum.
#'
#' @param request_type Either `"get_active_assignments"` or
#'   `"get_or_create_active_assignments"`.
#' @param student_id Student identifier sent to the assignment service.
#' @param config Runtime/authoring configuration list.
#' @param manifest Optional current question manifest used to advertise usable
#'   scored item labels.
#' @return A JSON-ready request payload list.
#' @details Called by `initialize_student_assignments()`, assignment-service
#'   smoke/testing code, and `test-assignment_storage.R`. Depends on
#'   `make_service_request_id()`, `scored_manifest_labels()`, and, for create
#'   requests, `assignment_config()`.
assignment_service_payload <- function(
  request_type,
  student_id,
  config = APP_CONFIG,
  manifest = NULL
) {
  if (!request_type %in% c("get_active_assignments", "get_or_create_active_assignments")) {
    stop("Unsupported assignment request_type: ", request_type, ".")
  }

  student_id <- trimws(as.character(student_id)[[1]])
  if (!grepl("^[A-Za-z0-9._@-]{2,100}$", student_id)) {
    stop("student_id has an invalid format.")
  }

  payload <- list(
    schema_version = "1",
    request_type = request_type,
    request_id = make_service_request_id(),
    course_id = config$course_id,
    student_id = student_id,
    reconcile_bank = TRUE
  )

  available <- scored_manifest_labels(manifest)
  if (length(available)) payload$available_item_labels <- unname(available)

  if (identical(request_type, "get_or_create_active_assignments")) {
    settings <- assignment_config(config)
    payload$queue_size <- settings$queue_size
    payload$topic_priority <- unname(settings$topic_priority)
  }

  payload
}

#' Send an active-assignment request to Apps Script
#'
#' Posts the request payload as JSON to the configured webhook, parses the
#' response, and raises an R error when the service reports `ok = false`.
#'
#' @param payload Assignment-service request list.
#' @param config Configuration containing `webhook_url`.
#' @param timeout_sec HTTP request timeout in seconds.
#' @return The parsed successful response body.
#' @details Called by `initialize_student_assignments()` and authoring-side
#'   assignment-service test/smoke code. It has no within-repo function
#'   dependencies.
post_assignment_service <- function(
  payload,
  config = APP_CONFIG,
  timeout_sec = 30
) {
  if (!nzchar(config$webhook_url) || grepl("PASTE_", config$webhook_url, fixed = TRUE)) {
    stop("Set APP_CONFIG$webhook_url before calling the assignment service.")
  }

  response <- httr2::request(config$webhook_url) |>
    httr2::req_body_json(payload, auto_unbox = TRUE, null = "null") |>
    httr2::req_timeout(timeout_sec) |>
    httr2::req_perform()

  body <- httr2::resp_body_json(response, simplifyVector = FALSE)
  if (!isTRUE(body$ok)) {
    msg <- if (!is.null(body$error) && length(body$error)) {
      as.character(body$error)[[1]]
    } else {
      "The assignment service returned ok=false."
    }
    stop(msg)
  }

  body
}

# Assignment response normalization ------------------------------------------

#' Extract one scalar assignment-response field
#'
#' Normalizes empty or vector-valued Apps Script response fields before they are
#' placed into the rectangular assignment table.
#'
#' @param x Response field value.
#' @param default Value returned for `NULL` or length-zero input.
#' @return The first element of `x`, or `default`.
#' @details Called only by `assignment_response_table()`. It has no within-repo
#'   function dependencies.
assignment_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x[[1]]
}

#' Create an empty assignment table
#'
#' Supplies the canonical zero-row assignment schema for service responses and
#' gradebook construction when no persisted assignments are available.
#'
#' @return A zero-row data frame containing all `ASSIGNMENT_COLUMNS` with stable
#'   types.
#' @details Called by `assignment_response_table()` and `build_gradebook_tables()`.
#'   It has no within-repo function dependencies.
empty_assignment_table <- function() {
  data.frame(
    assignment_id = character(),
    course_id = character(),
    week_id = character(),
    student_id = character(),
    item_label = character(),
    topic = character(),
    points = numeric(),
    assigned_at_utc = character(),
    assignment_reason = character(),
    assignment_status = character(),
    retired_at_utc = character(),
    retired_reason = character(),
    retired_request_id = character(),
    stringsAsFactors = FALSE
  )
}

#' Convert assignment-service rows to a data frame
#'
#' Flattens returned assignment objects into the stable local schema and orders
#' them oldest-first by assignment time.
#'
#' @param body Parsed Apps Script response body containing an `assignments` list.
#' @return An assignment data frame, or the canonical empty table when no rows
#'   are returned.
#' @details Called by `initialize_student_assignments()` and `post_log_event()`,
#'   and directly by `test-assignment_storage.R`. Depends on
#'   `assignment_scalar()` and `empty_assignment_table()`.
assignment_response_table <- function(body) {
  rows <- body$assignments
  if (is.null(rows) || !length(rows)) return(empty_assignment_table())

  out <- do.call(rbind, lapply(rows, function(row) {
    data.frame(
      assignment_id = as.character(assignment_scalar(row$assignment_id)),
      course_id = as.character(assignment_scalar(row$course_id)),
      week_id = as.character(assignment_scalar(row$week_id)),
      student_id = as.character(assignment_scalar(row$student_id)),
      item_label = as.character(assignment_scalar(row$item_label)),
      topic = as.character(assignment_scalar(row$topic)),
      points = suppressWarnings(as.numeric(assignment_scalar(row$points, NA_real_))),
      assigned_at_utc = as.character(assignment_scalar(row$assigned_at_utc)),
      assignment_reason = as.character(assignment_scalar(row$assignment_reason)),
      assignment_status = as.character(assignment_scalar(row$assignment_status)),
      retired_at_utc = as.character(assignment_scalar(row$retired_at_utc, "")),
      retired_reason = as.character(assignment_scalar(row$retired_reason, "")),
      retired_request_id = as.character(assignment_scalar(row$retired_request_id, "")),
      stringsAsFactors = FALSE
    )
  }))

  rownames(out) <- NULL
  out[order(out$assigned_at_utc), , drop = FALSE]
}

#' Validate active assignment rows against the current manifest
#'
#' Checks assignment schema, uniqueness, required metadata, and active status;
#' removes server rows whose IDs are absent from the locally usable manifest;
#' and verifies topic/point metadata for the remaining rows.
#'
#' @param assignments Assignment data frame returned by
#'   `assignment_response_table()`.
#' @param manifest Current question-manifest data frame.
#' @return The validated assignment data frame, possibly restricted to the local
#'   manifest intersection.
#' @details Called by `initialize_student_assignments()` and `post_log_event()`,
#'   and directly by `test-assignment_storage.R`. It uses `ASSIGNMENT_COLUMNS`
#'   but has no within-repo function dependencies.
validate_persisted_assignments <- function(assignments, manifest) {
  missing_assignment <- setdiff(ASSIGNMENT_COLUMNS, names(assignments))
  if (length(missing_assignment)) {
    stop(
      "Assignment rows are missing required column(s): ",
      paste(missing_assignment, collapse = ", "),
      "."
    )
  }

  manifest_required <- c("item_label", "topic", "points")
  missing_manifest <- setdiff(manifest_required, names(manifest))
  if (length(missing_manifest)) {
    stop(
      "Question manifest is missing required column(s): ",
      paste(missing_manifest, collapse = ", "),
      "."
    )
  }

  if (anyDuplicated(assignments$item_label)) {
    stop("Active assignment rows contain duplicate item_label values.")
  }
  if (anyDuplicated(assignments$assignment_id)) {
    stop("Active assignment rows contain duplicate assignment_id values.")
  }
  if (
    anyNA(assignments$assignment_id) || any(!nzchar(assignments$assignment_id)) ||
    anyNA(assignments$item_label) || any(!nzchar(assignments$item_label)) ||
    anyNA(assignments$topic) || any(!nzchar(assignments$topic)) ||
    anyNA(assignments$points)
  ) {
    stop("Active assignment rows contain missing required metadata.")
  }
  if (nrow(assignments) && any(assignments$assignment_status != "active")) {
    stop("The assignment service returned a non-active row in the active queue.")
  }

  assignments <- assignments[
    assignments$item_label %in% manifest$item_label,
    ,
    drop = FALSE
  ]
  if (!nrow(assignments)) return(assignments)

  expected <- manifest[
    match(assignments$item_label, manifest$item_label),
    ,
    drop = FALSE
  ]

  if (
    any(assignments$topic != expected$topic) ||
    !isTRUE(all.equal(
      as.numeric(assignments$points),
      as.numeric(expected$points),
      check.attributes = FALSE
    ))
  ) {
    stop("Persistent assignment metadata do not match the current question manifest.")
  }

  assignments
}

# Assignment lifecycle --------------------------------------------------------

#' Load or create a student's active assignment queue
#'
#' Builds a create-or-load request, calls the assignment service, converts and
#' validates the response against the current manifest, and preserves any
#' retired-assignment metadata as an attribute on the resulting table.
#'
#' @param student_id Student identifier whose active queue should be loaded.
#' @param manifest Current question manifest.
#' @param config Runtime configuration list.
#' @return A validated active assignment data frame with a
#'   `retired_assignments` attribute.
#' @details Called directly by the `save_identity` observer in `index.Rmd`.
#'   Depends on `read_question_manifest()` through its default,
#'   `assignment_service_payload()`, `post_assignment_service()`,
#'   `assignment_response_table()`, and `validate_persisted_assignments()`.
initialize_student_assignments <- function(
  student_id,
  manifest = read_question_manifest(),
  config = APP_CONFIG
) {
  payload <- assignment_service_payload(
    "get_or_create_active_assignments",
    student_id = student_id,
    config = config,
    manifest = manifest
  )

  body <- post_assignment_service(payload, config = config)
  assignments <- assignment_response_table(body)
  assignments <- validate_persisted_assignments(assignments, manifest)
  attr(assignments, "retired_assignments") <- body$retired_assignments
  assignments
}

#' Map active item labels to their assignment IDs
#'
#' Converts a validated active queue to the named vector stored in Shiny session
#' state so logging events can carry the exact persisted exposure ID.
#'
#' @param assignments Active assignment data frame.
#' @return A character vector of assignment IDs named by `item_label`, or an
#'   empty named character vector for an empty queue.
#' @details Called by `set_active_assignment_player()` in `R/logging.R` and
#'   directly by `test-assignment_storage.R`. It has no within-repo function
#'   dependencies.
assignment_id_map <- function(assignments) {
  if (!nrow(assignments)) return(setNames(character(), character()))
  if (anyDuplicated(assignments$item_label)) {
    stop("Cannot build assignment ID map from duplicate item_label values.")
  }
  stats::setNames(as.character(assignments$assignment_id), assignments$item_label)
}

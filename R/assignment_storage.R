QUESTION_BANK_SYNC_COLUMNS <- c(
  "item_label",
  "event",
  "topic",
  "points",
  "starter_question",
  "question_hash"
)

prepare_question_bank_sync <- function(manifest) {
  missing <- setdiff(QUESTION_BANK_SYNC_COLUMNS, names(manifest))
  if (length(missing)) {
    stop(
      "Question-bank manifest is missing required column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  out <- manifest[, QUESTION_BANK_SYNC_COLUMNS, drop = FALSE]

  if (anyDuplicated(out$item_label)) {
    stop("Question-bank sync data contain duplicate item_label values.")
  }
  if (any(is.na(out$item_label) | !nzchar(out$item_label))) {
    stop("Question-bank sync data contain a missing item_label.")
  }

  out
}

make_service_request_id <- function(prefix = "assignment") {
  paste0(
    prefix, "-",
    format(Sys.time(), "%Y%m%d%H%M%OS6", tz = "UTC"), "-",
    paste(sample(c(letters, LETTERS, 0:9), 16, replace = TRUE), collapse = "")
  )
}

assignment_service_payload <- function(
  request_type,
  student_id,
  config = APP_CONFIG,
  item_labels = NULL,
  assignment_reason = NULL
) {
  if (!request_type %in% c("get_assignments", "get_or_create_assignments")) {
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
    week_id = config$week_id,
    student_id = student_id
  )

  if (identical(request_type, "get_or_create_assignments")) {
    item_labels <- as.character(item_labels)
    if (!length(item_labels) || anyNA(item_labels) || any(!nzchar(item_labels))) {
      stop("item_labels must contain at least one non-empty item label.")
    }
    if (anyDuplicated(item_labels)) {
      stop("item_labels must not contain duplicates.")
    }
    if (
      is.null(assignment_reason) ||
      length(assignment_reason) == 0 ||
      !nzchar(trimws(as.character(assignment_reason)[[1]]))
    ) {
      stop("assignment_reason is required when creating assignments.")
    }

    payload$item_labels <- unname(item_labels)
    payload$assignment_reason <- trimws(as.character(assignment_reason)[[1]])
  }

  payload
}

post_assignment_service <- function(
  payload,
  config = APP_CONFIG,
  timeout_sec = 8
) {
  if (!nzchar(config$webhook_url) || grepl("PASTE_", config$webhook_url, fixed = TRUE)) {
    stop("Set APP_CONFIG$webhook_url before calling the assignment service.")
  }

  response <- httr2::request(config$webhook_url) |>
    httr2::req_method("POST") |>
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

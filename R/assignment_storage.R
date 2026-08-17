QUESTION_BANK_SYNC_COLUMNS <- c(
  "item_label",
  "event",
  "topic",
  "points",
  "starter_question",
  "question_hash"
)

ASSIGNMENT_COLUMNS <- c(
  "assignment_id",
  "course_id",
  "week_id",
  "student_id",
  "item_label",
  "topic",
  "points",
  "question_hash",
  "assigned_at_utc",
  "assignment_reason"
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
  if (any(is.na(out$topic) | !nzchar(out$topic) | out$topic == "unassigned")) {
    stop("Question-bank sync data contain missing or unassigned topics.")
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

assignment_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x[[1]]
}

empty_assignment_table <- function() {
  data.frame(
    assignment_id = character(),
    course_id = character(),
    week_id = character(),
    student_id = character(),
    item_label = character(),
    topic = character(),
    points = numeric(),
    question_hash = character(),
    assigned_at_utc = character(),
    assignment_reason = character(),
    stringsAsFactors = FALSE
  )
}

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
      question_hash = as.character(assignment_scalar(row$question_hash)),
      assigned_at_utc = as.character(assignment_scalar(row$assigned_at_utc)),
      assignment_reason = as.character(assignment_scalar(row$assignment_reason)),
      stringsAsFactors = FALSE
    )
  }))

  rownames(out) <- NULL
  out
}

static_assignment_item_labels <- function(manifest) {
  labels <- as.character(manifest$item_label)
  if (!length(labels) || anyNA(labels) || any(!nzchar(labels))) {
    stop("The current assignment manifest contains invalid item_label values.")
  }
  if (anyDuplicated(labels)) {
    stop("The current assignment manifest contains duplicate item_label values.")
  }
  labels
}

validate_static_assignments <- function(assignments, manifest) {
  missing_assignment <- setdiff(ASSIGNMENT_COLUMNS, names(assignments))
  if (length(missing_assignment)) {
    stop(
      "Assignment rows are missing required column(s): ",
      paste(missing_assignment, collapse = ", "),
      "."
    )
  }

  manifest_required <- c("item_label", "topic", "points", "question_hash")
  missing_manifest <- setdiff(manifest_required, names(manifest))
  if (length(missing_manifest)) {
    stop(
      "Current assignment manifest is missing required column(s): ",
      paste(missing_manifest, collapse = ", "),
      "."
    )
  }

  expected_labels <- static_assignment_item_labels(manifest)

  if (anyDuplicated(assignments$item_label)) {
    stop("Persistent assignment rows contain duplicate item_label values.")
  }
  if (anyDuplicated(assignments$assignment_id)) {
    stop("Persistent assignment rows contain duplicate assignment_id values.")
  }
  if (
    anyNA(assignments$assignment_id) || any(!nzchar(assignments$assignment_id)) ||
    anyNA(assignments$topic) || any(!nzchar(assignments$topic)) ||
    anyNA(assignments$question_hash) || any(!nzchar(assignments$question_hash)) ||
    anyNA(assignments$points)
  ) {
    stop("Persistent assignment rows contain missing required metadata.")
  }

  missing <- setdiff(expected_labels, assignments$item_label)
  extra <- setdiff(assignments$item_label, expected_labels)
  if (length(missing) || length(extra)) {
    stop(
      "Persistent assignments do not match the current static assignment. ",
      if (length(missing)) paste0("Missing: ", paste(missing, collapse = ", "), ". ") else "",
      if (length(extra)) paste0("Extra: ", paste(extra, collapse = ", "), ".") else ""
    )
  }

  assignments <- assignments[
    match(expected_labels, assignments$item_label),
    ,
    drop = FALSE
  ]
  expected <- manifest[
    match(expected_labels, manifest$item_label),
    ,
    drop = FALSE
  ]

  if (
    anyNA(expected$topic) || any(!nzchar(expected$topic)) ||
    anyNA(expected$question_hash) || any(!nzchar(expected$question_hash)) ||
    anyNA(expected$points)
  ) {
    stop("Current assignment manifest contains missing required metadata.")
  }

  topic_mismatch <- assignments$topic != expected$topic
  points_mismatch <- !isTRUE(all.equal(
    as.numeric(assignments$points),
    as.numeric(expected$points),
    check.attributes = FALSE
  ))
  hash_mismatch <- assignments$question_hash != expected$question_hash

  if (any(topic_mismatch) || points_mismatch || any(hash_mismatch)) {
    stop(
      "Persistent assignment metadata do not match the current assignment manifest. ",
      "Re-sync question_bank and use a new week_id if the assignment changed after students began."
    )
  }

  assignments
}

initialize_static_assignments <- function(
  student_id,
  manifest = read_question_manifest(),
  config = APP_CONFIG
) {
  payload <- assignment_service_payload(
    "get_or_create_assignments",
    student_id = student_id,
    config = config,
    item_labels = static_assignment_item_labels(manifest),
    assignment_reason = "static"
  )

  body <- post_assignment_service(payload, config = config)
  assignments <- assignment_response_table(body)
  validate_static_assignments(assignments, manifest)
}

assignment_id_map <- function(assignments) {
  if (!nrow(assignments)) return(setNames(character(), character()))
  if (anyDuplicated(assignments$item_label)) {
    stop("Cannot build assignment ID map from duplicate item_label values.")
  }
  stats::setNames(as.character(assignments$assignment_id), assignments$item_label)
}

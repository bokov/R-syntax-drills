QUESTION_BANK_VERSION_COLUMNS <- c(
  "item_label",
  "event",
  "topic",
  "points",
  "starter_question",
  "question_hash"
)

QUESTION_BANK_SYNC_COLUMNS <- c(
  QUESTION_BANK_VERSION_COLUMNS,
  "bank_version"
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
  "assignment_reason",
  "assignment_status",
  "retired_at_utc",
  "retired_reason",
  "retired_request_id"
)

runtime_question_bank_version <- function(manifest) {
  missing <- setdiff(QUESTION_BANK_VERSION_COLUMNS, names(manifest))
  if (length(missing)) {
    stop(
      "Question-bank manifest is missing required version column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  runtime <- manifest[
    manifest$event == "exercise_result" & manifest$points > 0,
    QUESTION_BANK_VERSION_COLUMNS,
    drop = FALSE
  ]
  if (!nrow(runtime)) {
    stop("Question-bank manifest contains no scored runtime exercises.")
  }
  if (anyDuplicated(runtime$item_label)) {
    stop("Question-bank version data contain duplicate item_label values.")
  }

  runtime <- runtime[order(runtime$item_label), , drop = FALSE]
  canonical <- data.frame(
    item_label = enc2utf8(as.character(runtime$item_label)),
    event = enc2utf8(as.character(runtime$event)),
    topic = enc2utf8(as.character(runtime$topic)),
    points = sprintf("%.15g", as.numeric(runtime$points)),
    starter_question = ifelse(runtime$starter_question %in% TRUE, "1", "0"),
    question_hash = enc2utf8(as.character(runtime$question_hash)),
    stringsAsFactors = FALSE
  )

  path <- tempfile("drillr-bank-version-")
  on.exit(unlink(path), add = TRUE)
  write.table(
    canonical,
    file = path,
    sep = "\t",
    quote = TRUE,
    row.names = FALSE,
    col.names = TRUE,
    na = "",
    eol = "\n",
    fileEncoding = "UTF-8"
  )

  paste0("md5-", unname(tools::md5sum(path)))
}

prepare_question_bank_sync <- function(manifest) {
  missing <- setdiff(QUESTION_BANK_VERSION_COLUMNS, names(manifest))
  if (length(missing)) {
    stop(
      "Question-bank manifest is missing required column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }

  out <- manifest[, QUESTION_BANK_VERSION_COLUMNS, drop = FALSE]

  if (anyDuplicated(out$item_label)) {
    stop("Question-bank sync data contain duplicate item_label values.")
  }
  if (any(is.na(out$item_label) | !nzchar(out$item_label))) {
    stop("Question-bank sync data contain a missing item_label.")
  }
  if (any(is.na(out$topic) | !nzchar(out$topic) | out$topic == "unassigned")) {
    stop("Question-bank sync data contain missing or unassigned topics.")
  }

  out$bank_version <- runtime_question_bank_version(out)
  out[, QUESTION_BANK_SYNC_COLUMNS, drop = FALSE]
}

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

validate_assignment_config <- function(config = APP_CONFIG, bank_manifest = NULL) {
  settings <- assignment_config(config)

  if (is.null(bank_manifest)) return(invisible(settings))

  required <- c(
    "item_label", "event", "topic", "points", "starter_question", "question_hash"
  )
  missing <- setdiff(required, names(bank_manifest))
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
  config = APP_CONFIG
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
    student_id = student_id
  )

  if (identical(request_type, "get_or_create_active_assignments")) {
    settings <- assignment_config(config)
    payload$queue_size <- settings$queue_size
    payload$topic_priority <- unname(settings$topic_priority)
  }

  payload
}

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
    assignment_status = character(),
    retired_at_utc = character(),
    retired_reason = character(),
    retired_request_id = character(),
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

validate_persisted_assignments <- function(assignments, manifest) {
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
    anyNA(assignments$question_hash) || any(!nzchar(assignments$question_hash)) ||
    anyNA(assignments$points)
  ) {
    stop("Active assignment rows contain missing required metadata.")
  }
  if (nrow(assignments) && any(assignments$assignment_status != "active")) {
    stop("The assignment service returned a non-active row in the active queue.")
  }

  missing_from_manifest <- setdiff(assignments$item_label, manifest$item_label)
  if (length(missing_from_manifest)) {
    stop(
      "Persisted assignment question(s) are absent from the deployed question manifest: ",
      paste(missing_from_manifest, collapse = ", "),
      ". Rebuild/deploy the player from the canonical bank."
    )
  }

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
    )) ||
    any(assignments$question_hash != expected$question_hash)
  ) {
    stop(
      "Persistent assignment metadata do not match the current question manifest. ",
      "Do not change a canonical question under an item_label after it has been assigned."
    )
  }

  assignments
}

initialize_student_assignments <- function(
  student_id,
  manifest = read_question_manifest(),
  config = APP_CONFIG
) {
  payload <- assignment_service_payload(
    "get_or_create_active_assignments",
    student_id = student_id,
    config = config
  )

  body <- post_assignment_service(payload, config = config)
  assignments <- assignment_response_table(body)
  validate_persisted_assignments(assignments, manifest)
}

assignment_id_map <- function(assignments) {
  if (!nrow(assignments)) return(setNames(character(), character()))
  if (anyDuplicated(assignments$item_label)) {
    stop("Cannot build assignment ID map from duplicate item_label values.")
  }
  stats::setNames(as.character(assignments$assignment_id), assignments$item_label)
}

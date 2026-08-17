require_columns <- function(data, required, object_name) {
  missing <- setdiff(required, names(data))
  if (length(missing)) {
    stop(
      object_name, " is missing required column(s): ",
      paste(missing, collapse = ", "),
      "."
    )
  }
  invisible(TRUE)
}

build_gradebook_tables <- function(
  events,
  assignments,
  manifest,
  roster = NULL,
  course_id,
  week_id,
  deadline_utc = NA_character_
) {
  require_columns(
    manifest,
    c("event", "item_label", "topic", "points", "question_hash"),
    "Question manifest"
  )

  scored_manifest <- manifest |>
    dplyr::filter(.data$points > 0) |>
    dplyr::select(event, item_label, topic, points, question_hash)

  if (!nrow(scored_manifest)) {
    stop("The question manifest contains no scored items.")
  }

  require_columns(
    events,
    c(
      "server_timestamp_utc", "course_id", "week_id", "session_token",
      "student_id", "student_name", "event", "item_label", "correct"
    ),
    "Events"
  )

  if (!"assignment_id" %in% names(events)) {
    events$assignment_id <- NA_character_
  }

  events <- events |>
    dplyr::mutate(
      server_timestamp_utc = readr::parse_datetime(.data$server_timestamp_utc),
      course_id = trimws(as.character(.data$course_id)),
      week_id = trimws(as.character(.data$week_id)),
      student_id = dplyr::na_if(trimws(as.character(.data$student_id)), ""),
      student_name = dplyr::na_if(trimws(as.character(.data$student_name)), ""),
      assignment_id = dplyr::na_if(trimws(as.character(.data$assignment_id)), ""),
      item_label = dplyr::na_if(trimws(as.character(.data$item_label)), ""),
      correct_bool = tolower(as.character(.data$correct)) == "true"
    ) |>
    dplyr::filter(
      .data$course_id == course_id,
      .data$week_id == week_id
    )

  if (!is.na(deadline_utc)) {
    deadline <- as.POSIXct(deadline_utc, tz = "UTC")
    events <- events |>
      dplyr::filter(.data$server_timestamp_utc <= deadline)
  }

  # Rescue attempts submitted before identity was saved, but never overwrite an
  # identity that was already logged on an event. If a session contains more
  # than one identity, pre-identity attempts belong to the first saved identity.
  identity_by_session <- events |>
    dplyr::filter(!is.na(.data$student_id)) |>
    dplyr::arrange(.data$server_timestamp_utc) |>
    dplyr::group_by(.data$session_token) |>
    dplyr::summarise(
      session_student_id = dplyr::first(.data$student_id),
      session_student_name = {
        first_id <- dplyr::first(.data$student_id)
        dplyr::first(
          .data$student_name[
            .data$student_id == first_id & !is.na(.data$student_name)
          ],
          default = NA_character_
        )
      },
      .groups = "drop"
    )

  events <- events |>
    dplyr::left_join(identity_by_session, by = "session_token") |>
    dplyr::mutate(
      student_id = dplyr::coalesce(.data$student_id, .data$session_student_id),
      student_name = dplyr::coalesce(.data$student_name, .data$session_student_name)
    ) |>
    dplyr::select(-session_student_id, -session_student_name)

  unidentified <- events |>
    dplyr::filter(
      is.na(.data$student_id),
      .data$event %in% c("exercise_result", "question_submission")
    )
  if (nrow(unidentified)) {
    warning(
      nrow(unidentified),
      " graded event(s) could not be linked to a student ID.",
      call. = FALSE
    )
  }

  if (is.null(assignments)) assignments <- empty_assignment_table()
  require_columns(assignments, ASSIGNMENT_COLUMNS, "Assignments")

  assignments <- assignments |>
    dplyr::mutate(
      assignment_id = dplyr::na_if(trimws(as.character(.data$assignment_id)), ""),
      course_id = trimws(as.character(.data$course_id)),
      week_id = trimws(as.character(.data$week_id)),
      student_id = dplyr::na_if(trimws(as.character(.data$student_id)), ""),
      item_label = dplyr::na_if(trimws(as.character(.data$item_label)), ""),
      topic = dplyr::na_if(trimws(as.character(.data$topic)), ""),
      points = suppressWarnings(as.numeric(.data$points)),
      question_hash = dplyr::na_if(trimws(as.character(.data$question_hash)), ""),
      assigned_at_utc = dplyr::na_if(trimws(as.character(.data$assigned_at_utc)), ""),
      assignment_reason = dplyr::na_if(trimws(as.character(.data$assignment_reason)), "")
    ) |>
    dplyr::filter(
      .data$course_id == course_id,
      .data$week_id == week_id
    )

  if (any(is.na(assignments$student_id) | is.na(assignments$item_label))) {
    stop("Assignments contain missing student_id or item_label values.")
  }
  if (any(is.na(assignments$assignment_id) | !nzchar(assignments$assignment_id))) {
    stop("Assignments contain a missing assignment_id.")
  }
  if (any(is.na(assignments$topic) | !nzchar(assignments$topic))) {
    stop("Assignments contain a missing topic.")
  }
  if (any(is.na(assignments$question_hash) | !nzchar(assignments$question_hash))) {
    stop("Assignments contain a missing question_hash.")
  }
  if (any(is.na(assignments$points) | assignments$points < 0)) {
    stop("Assignments contain invalid points values.")
  }

  duplicate_assignment_items <- assignments |>
    dplyr::count(.data$student_id, .data$item_label, name = "n") |>
    dplyr::filter(.data$n > 1)
  if (nrow(duplicate_assignment_items)) {
    stop("Assignments contain duplicate student/week/item exposures.")
  }
  if (anyDuplicated(assignments$assignment_id)) {
    stop("Assignments contain duplicate assignment_id values.")
  }

  event_students <- events |>
    dplyr::filter(
      !is.na(.data$student_id),
      .data$event %in% c("identity_saved", "exercise_result", "question_submission")
    ) |>
    dplyr::group_by(.data$student_id) |>
    dplyr::summarise(
      student_name = dplyr::last(
        .data$student_name[!is.na(.data$student_name)],
        default = NA_character_
      ),
      .groups = "drop"
    )

  if (!is.null(roster)) {
    require_columns(roster, "student_id", "Roster")
    if (!"student_name" %in% names(roster)) roster$student_name <- NA_character_

    students <- roster |>
      dplyr::transmute(
        student_id = trimws(as.character(.data$student_id)),
        student_name = dplyr::na_if(trimws(as.character(.data$student_name)), "")
      )

    if (any(is.na(students$student_id) | !nzchar(students$student_id))) {
      stop("Roster contains a missing student_id.")
    }
    if (anyDuplicated(students$student_id)) {
      stop("Roster contains duplicate student_id values.")
    }
  } else {
    # Assignment-service smoke tests intentionally leave assignment rows behind,
    # and logging_test intentionally leaves an event row behind. Neither alone
    # should create a gradebook student.
    students <- event_students
  }

  assignments_for_students <- assignments |>
    dplyr::semi_join(students, by = "student_id")

  # During this static phase, any student who has persisted rows must have the
  # entire current assignment, not a subset. A partial set must never lower the
  # denominator. The same validator also checks topic/points/hash snapshots.
  if (nrow(assignments_for_students)) {
    by_student <- split(
      assignments_for_students,
      assignments_for_students$student_id,
      drop = TRUE
    )
    invisible(lapply(
      by_student,
      validate_static_assignments,
      manifest = manifest
    ))
  }

  assigned_scored <- assignments_for_students |>
    dplyr::filter(.data$points > 0) |>
    dplyr::left_join(
      scored_manifest |>
        dplyr::select(item_label, assignment_event = event),
      by = "item_label"
    ) |>
    dplyr::transmute(
      student_id = .data$student_id,
      assignment_id = .data$assignment_id,
      item_label = .data$item_label,
      event = .data$assignment_event,
      topic = .data$topic,
      points = .data$points,
      question_hash = .data$question_hash,
      assigned_at_utc = .data$assigned_at_utc,
      assignment_reason = .data$assignment_reason
    )

  if (any(is.na(assigned_scored$event))) {
    stop("A scored persisted assignment is absent from the current scored manifest.")
  }

  students_with_persisted_assignments <- assignments_for_students |>
    dplyr::distinct(.data$student_id)

  fallback_students <- students |>
    dplyr::anti_join(students_with_persisted_assignments, by = "student_id") |>
    dplyr::select(student_id)

  # Transitional compatibility: roster/event students who predate assignment
  # rows keep the old static denominator until they next save identity.
  fallback_assignments <- tidyr::crossing(
    fallback_students,
    scored_manifest
  ) |>
    dplyr::transmute(
      student_id = .data$student_id,
      assignment_id = NA_character_,
      item_label = .data$item_label,
      event = .data$event,
      topic = .data$topic,
      points = .data$points,
      question_hash = .data$question_hash,
      assigned_at_utc = NA_character_,
      assignment_reason = "legacy_static_fallback"
    )

  effective_assignments <- dplyr::bind_rows(
    assigned_scored,
    fallback_assignments
  )

  duplicate_effective <- effective_assignments |>
    dplyr::count(.data$student_id, .data$item_label, name = "n") |>
    dplyr::filter(.data$n > 1)
  if (nrow(duplicate_effective)) {
    stop("Effective assignments contain duplicate student/item rows.")
  }

  persisted_keys <- assignments_for_students |>
    dplyr::select(student_id, item_label, persisted_assignment_id = assignment_id)

  graded_event_candidates <- events |>
    dplyr::filter(
      !is.na(.data$student_id),
      !is.na(.data$item_label),
      .data$event %in% c("exercise_result", "question_submission")
    ) |>
    dplyr::left_join(
      persisted_keys,
      by = c("student_id", "item_label")
    )

  bad_assignment_ids <- graded_event_candidates |>
    dplyr::filter(
      !is.na(.data$assignment_id),
      is.na(.data$persisted_assignment_id) |
        .data$assignment_id != .data$persisted_assignment_id
    )

  if (nrow(bad_assignment_ids)) {
    warning(
      nrow(bad_assignment_ids),
      " graded event(s) contained an assignment_id that did not match the student's persisted assignment and were excluded.",
      call. = FALSE
    )
  }

  attempt_events <- graded_event_candidates |>
    dplyr::filter(
      is.na(.data$assignment_id) |
        (!is.na(.data$persisted_assignment_id) &
          .data$assignment_id == .data$persisted_assignment_id)
    ) |>
    dplyr::select(-persisted_assignment_id)

  attempts <- attempt_events |>
    dplyr::inner_join(
      effective_assignments |>
        dplyr::select(student_id, item_label, assignment_event = event),
      by = c("student_id", "item_label")
    ) |>
    dplyr::filter(.data$event == .data$assignment_event) |>
    dplyr::group_by(.data$student_id, .data$item_label) |>
    dplyr::summarise(
      attempts = dplyr::n(),
      ever_correct = any(.data$correct_bool, na.rm = TRUE),
      first_correct_utc = if (any(.data$correct_bool, na.rm = TRUE)) {
        min(.data$server_timestamp_utc[.data$correct_bool], na.rm = TRUE)
      } else {
        as.POSIXct(NA, tz = "UTC")
      },
      .groups = "drop"
    )

  item_detail <- effective_assignments |>
    dplyr::left_join(students, by = "student_id") |>
    dplyr::left_join(attempts, by = c("student_id", "item_label")) |>
    dplyr::mutate(
      attempts = dplyr::coalesce(.data$attempts, 0L),
      ever_correct = dplyr::coalesce(.data$ever_correct, FALSE),
      points_earned = dplyr::if_else(.data$ever_correct, .data$points, 0)
    ) |>
    dplyr::select(
      student_id, student_name, assignment_id, assignment_reason,
      assigned_at_utc, event, item_label, topic, question_hash, points,
      attempts, ever_correct, first_correct_utc, points_earned
    )

  grade_summary <- item_detail |>
    dplyr::group_by(.data$student_id) |>
    dplyr::summarise(
      points_earned = sum(.data$points_earned),
      points_possible = sum(.data$points),
      items_correct = sum(.data$ever_correct),
      items_possible = dplyr::n(),
      .groups = "drop"
    )

  gradebook <- students |>
    dplyr::left_join(grade_summary, by = "student_id") |>
    dplyr::mutate(
      points_earned = dplyr::coalesce(.data$points_earned, 0),
      points_possible = dplyr::coalesce(.data$points_possible, 0),
      percent = dplyr::if_else(
        .data$points_possible > 0,
        100 * .data$points_earned / .data$points_possible,
        NA_real_
      ),
      items_correct = dplyr::coalesce(.data$items_correct, 0L),
      items_possible = dplyr::coalesce(.data$items_possible, 0L)
    ) |>
    dplyr::select(
      student_id, student_name, points_earned, points_possible,
      percent, items_correct, items_possible
    ) |>
    dplyr::arrange(.data$student_name, .data$student_id)

  list(
    gradebook = gradebook,
    item_detail = item_detail,
    effective_assignments = effective_assignments
  )
}

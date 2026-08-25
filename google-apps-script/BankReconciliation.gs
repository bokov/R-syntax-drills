// Client/content reconciliation is based on question IDs only.

let DRILLR_AVAILABLE_ITEM_LABELS = null;

/**
 * Reports whether a request needs client/content bank reconciliation.
 *
 * Called by bankReconciliationForRequest(). It has no within-repo function
 * dependencies.
 *
 * @param {Object} data Parsed request payload.
 * @return {boolean} True when reconciliation, progress, or explicit available
 *   item labels were requested.
 */
function requestUsesBankReconciliation(data) {
  return Boolean(
    data &&
    (
      data.reconcile_bank === true ||
      data.include_progress === true ||
      Array.isArray(data.available_item_labels)
    )
  );
}

/**
 * Validates and normalizes the item labels advertised by a client.
 *
 * Called by bankReconciliationForRequest(). The map/filter callbacks only trim
 * and remove blank values. It has no within-repo named-function dependencies.
 *
 * @param {Object} data Parsed request payload.
 * @return {?Array<string>} Normalized unique labels, or null when the client did
 *   not supply available_item_labels.
 */
function requestedAvailableItemLabels(data) {
  if (!data || typeof data.available_item_labels === 'undefined') return null;
  if (!Array.isArray(data.available_item_labels)) {
    throw new Error('available_item_labels must be an array.');
  }

  const labels = data.available_item_labels.map(function(value) {
    return String(value || '').trim();
  }).filter(function(value) {
    return Boolean(value);
  });

  if (new Set(labels).size !== labels.length) {
    throw new Error('available_item_labels must not contain duplicates.');
  }

  return labels;
}

/**
 * Builds the reconciliation/progress context for one service request.
 *
 * Called by the main request handlers in Code.gs before assignment/logging
 * responses are produced. Depends on requestUsesBankReconciliation(),
 * requestedAvailableItemLabels(), and progressPayloadForRequest() from
 * Progress.gs; also updates DRILLR_AVAILABLE_ITEM_LABELS for downstream
 * discontinued-question checks.
 *
 * @param {Object} data Parsed request payload.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} questionBankSheet Question-bank
 *   sheet used when progress is requested.
 * @return {?Object} Reconciliation object with compatibility/progress metadata,
 *   or null when the request does not require reconciliation.
 */
function bankReconciliationForRequest(data, questionBankSheet) {
  if (!requestUsesBankReconciliation(data)) return null;

  const available = requestedAvailableItemLabels(data);
  DRILLR_AVAILABLE_ITEM_LABELS = available === null
    ? null
    : new Set(available);

  return {
    compatible: true,
    progress: data.include_progress === true
      ? progressPayloadForRequest(data, questionBankSheet)
      : null
  };
}

/**
 * Adds reconciliation-derived progress fields to a successful response.
 *
 * Called by main response paths in Code.gs. It has no within-repo function
 * dependencies and mutates/returns the supplied response object.
 *
 * @param {Object} response Service response object.
 * @param {?Object} reconciliation Result from bankReconciliationForRequest().
 * @return {Object} The same response object, with progress fields when present.
 */
function attachBankReconciliation(response, reconciliation) {
  if (reconciliation && reconciliation.compatible && reconciliation.progress) {
    response.progress_as_of_utc = reconciliation.progress.as_of_utc;
    response.progress = reconciliation.progress.rows;
  }
  return response;
}

/**
 * Determines why one active assignment is no longer usable.
 *
 * Called by discontinuedActiveAssignments(). It consults the reconciled client
 * label set, the configured curriculum, and canonical question-bank metadata.
 * The Array.find callback locates the canonical row by permanent item label.
 *
 * @param {Object} assignment Persisted active assignment.
 * @param {Array<Object>} bank Canonical scored-question records.
 * @param {Array<string>} topicPriority Ordered active curriculum topics.
 * @return {string} Empty string when still usable; otherwise a retirement reason
 *   such as client_content_unavailable, topic_discontinued,
 *   question_discontinued, or question_updated.
 */
function discontinuedAssignmentReason(assignment, bank, topicPriority) {
  if (
    DRILLR_AVAILABLE_ITEM_LABELS !== null &&
    !DRILLR_AVAILABLE_ITEM_LABELS.has(String(assignment.item_label || ''))
  ) {
    return 'client_content_unavailable';
  }

  if (!topicPriority.includes(String(assignment.topic || ''))) {
    return 'topic_discontinued';
  }

  const canonical = bank.find(function(item) {
    return String(item.item_label || '') === String(assignment.item_label || '');
  });
  if (!canonical || canonical.event !== 'exercise_result' || canonical.points <= 0) {
    return 'question_discontinued';
  }

  if (
    String(canonical.topic || '') !== String(assignment.topic || '') ||
    Number(canonical.points) !== Number(assignment.points)
  ) {
    return 'question_updated';
  }

  return '';
}

/**
 * Finds all active assignments that should be retired during reconciliation.
 *
 * Called by retireDiscontinuedAssignmentsFromSnapshot(). Depends on
 * discontinuedAssignmentReason(); its map/filter callbacks package assignments
 * with reasons and discard still-valid rows.
 *
 * @param {Array<Object>} assignments Active assignments for one student.
 * @param {Array<Object>} bank Canonical question-bank records.
 * @param {Array<string>} topicPriority Ordered active curriculum topics.
 * @return {Array<Object>} Objects containing each discontinued assignment and
 *   its retirement reason.
 */
function discontinuedActiveAssignments(assignments, bank, topicPriority) {
  return assignments
    .map(function(assignment) {
      return {
        assignment: assignment,
        reason: discontinuedAssignmentReason(assignment, bank, topicPriority)
      };
    })
    .filter(function(item) { return Boolean(item.reason); });
}

/**
 * Retires discontinued active assignments against one assignment-sheet snapshot.
 *
 * Called by rolling-queue reconciliation paths in Code.gs. It identifies active
 * rows, rechecks each current sheet status before writing retirement metadata,
 * updates the in-memory snapshot to match those writes, and returns compact
 * retirement records for the response. Depends on activeAssignmentsFromRows(),
 * discontinuedActiveAssignments(), getAssignmentRecordByIdFromRows(), and
 * clean() from Code.gs.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} assignmentsSheet Assignments sheet.
 * @param {Array<Array<*>>} assignmentRows Snapshot including header and rows.
 * @param {Array<Object>} bank Canonical question-bank records.
 * @param {Object} data Parsed request payload containing course/student/request.
 * @param {Object} queueConfig Validated queue configuration.
 * @param {string} retiredAt UTC timestamp written to retired rows.
 * @return {Array<Object>} Retired assignment IDs, labels, and reasons.
 */
function retireDiscontinuedAssignmentsFromSnapshot(
  assignmentsSheet,
  assignmentRows,
  bank,
  data,
  queueConfig,
  retiredAt
) {
  const active = activeAssignmentsFromRows(
    assignmentRows,
    data.course_id,
    data.student_id
  );
  const candidates = discontinuedActiveAssignments(
    active,
    bank,
    queueConfig.topic_priority
  );
  const retired = [];

  candidates.forEach(function(candidate) {
    const record = getAssignmentRecordByIdFromRows(
      assignmentRows,
      candidate.assignment.assignment_id
    );
    if (!record) return;

    const currentState = assignmentsSheet
      .getRange(record.row_index, 11, 1, 4)
      .getValues()[0];
    const currentStatus = String(currentState[0] || '');

    if (currentStatus === ASSIGNMENT_STATUS_RETIRED) {
      record.row[10] = currentState[0];
      record.row[11] = currentState[1];
      record.row[12] = currentState[2];
      record.row[13] = currentState[3];
      return;
    }
    if (currentStatus !== ASSIGNMENT_STATUS_ACTIVE) {
      throw new Error(
        'Assignment has no rolling status. Run setupGradeSheet() before using the rolling queue.'
      );
    }

    assignmentsSheet
      .getRange(record.row_index, 11, 1, 4)
      .setValues([[
        ASSIGNMENT_STATUS_RETIRED,
        retiredAt,
        candidate.reason,
        clean(data.request_id, 200)
      ]]);

    record.row[10] = ASSIGNMENT_STATUS_RETIRED;
    record.row[11] = retiredAt;
    record.row[12] = candidate.reason;
    record.row[13] = clean(data.request_id, 200);

    retired.push({
      assignment_id: candidate.assignment.assignment_id,
      item_label: candidate.assignment.item_label,
      reason: candidate.reason
    });
  });

  return retired;
}

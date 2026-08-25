// Client/content reconciliation is based on question IDs only.

let DRILLR_AVAILABLE_ITEM_LABELS = null;

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

function attachBankReconciliation(response, reconciliation) {
  if (reconciliation && reconciliation.compatible && reconciliation.progress) {
    response.progress_as_of_utc = reconciliation.progress.as_of_utc;
    response.progress = reconciliation.progress.rows;
  }
  return response;
}

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

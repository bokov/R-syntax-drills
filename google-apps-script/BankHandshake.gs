// Optional bank-version handshake for version-aware clients. Legacy clients
// omit bank_version and continue on the pre-handshake service path unchanged.

function requestUsesBankHandshake(data) {
  return Boolean(
    data &&
    typeof data.bank_version !== 'undefined' &&
    data.bank_version !== null &&
    String(data.bank_version).trim()
  );
}

function questionBankVersionFromRows(rows) {
  const versions = Array.from(new Set(
    rows
      .map(function(row) { return String(row[6] || '').trim(); })
      .filter(function(version) { return Boolean(version); })
  ));

  if (versions.length > 1) {
    throw new Error(
      'question_bank contains multiple bank_version values. Re-run scripts/06_sync_question_bank.R.'
    );
  }

  return versions.length ? versions[0] : '';
}

function getQuestionBankVersion(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) {
    throw new Error(
      'The question_bank sheet is empty. Run scripts/06_sync_question_bank.R first.'
    );
  }

  return questionBankVersionFromRows(
    sheet
      .getRange(2, 1, lastRow - 1, QUESTION_BANK_HEADERS.length)
      .getValues()
  );
}

function bankHandshakeForRequest(data, questionBankSheet) {
  if (!requestUsesBankHandshake(data)) return null;

  const clientBankVersion = String(data.bank_version).trim();
  const clientPackageVersion = typeof data.package_version === 'undefined' ||
      data.package_version === null
    ? ''
    : String(data.package_version).trim();

  if (clientBankVersion.length > 100) {
    throw new Error('bank_version must be at most 100 characters.');
  }
  if (clientPackageVersion.length > 100) {
    throw new Error('package_version must be at most 100 characters.');
  }

  const currentBankVersion = getQuestionBankVersion(questionBankSheet);
  if (!currentBankVersion) {
    return {
      compatible: false,
      current_bank_version: '',
      response: {
        ok: false,
        code: 'bank_metadata_unavailable',
        error: 'The assignment service has not published versioned drill content yet.',
        client_bank_version: clientBankVersion,
        client_package_version: clientPackageVersion
      }
    };
  }

  if (clientBankVersion !== currentBankVersion) {
    return {
      compatible: false,
      current_bank_version: currentBankVersion,
      response: {
        ok: false,
        code: 'bank_update_required',
        error: 'Your local drill content is out of date. Update the drill bank and retry.',
        client_bank_version: clientBankVersion,
        current_bank_version: currentBankVersion,
        client_package_version: clientPackageVersion
      }
    };
  }

  return {
    compatible: true,
    current_bank_version: currentBankVersion,
    client_package_version: clientPackageVersion
  };
}

function attachBankVersion(response, handshake) {
  if (handshake && handshake.compatible) {
    response.bank_version = handshake.current_bank_version;
  }
  return response;
}

function discontinuedAssignmentReason(assignment, bank, topicPriority) {
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
    Number(canonical.points) !== Number(assignment.points) ||
    String(canonical.question_hash || '') !== String(assignment.question_hash || '')
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

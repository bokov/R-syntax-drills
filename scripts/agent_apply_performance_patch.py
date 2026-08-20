from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


code_path = Path("google-apps-script/Code.gs")
code = code_path.read_text()

code = replace_once(
    code,
    "const FSRS_DUE_RETRIEVABILITY = 0.9;\n",
    "const FSRS_DUE_RETRIEVABILITY = 0.9;\n"
    "const RUNTIME_SCHEMA_PROPERTY = 'RUNTIME_SCHEMA_VERSION';\n"
    "const RUNTIME_SCHEMA_VERSION = 'rolling-queue-v1';\n",
    "runtime schema constants",
)

code = replace_once(
    code,
    "  PropertiesService.getScriptProperties().setProperty('SPREADSHEET_ID', ss.getId());\n",
    "  const scriptProperties = PropertiesService.getScriptProperties();\n"
    "  scriptProperties.setProperty('SPREADSHEET_ID', ss.getId());\n",
    "setup script properties",
)

code = replace_once(
    code,
    "  const migrated = migrateLegacyAssignmentsForRollingQueue(ss);\n"
    "  if (migrated) {\n"
    "    Logger.log('Initialized rolling status on ' + migrated + ' legacy assignment row(s).');\n"
    "  }\n\n"
    "  Logger.log('Grade sheet is ready: ' + ss.getId());\n",
    "  const migrated = migrateLegacyAssignmentsForRollingQueue(ss);\n"
    "  if (migrated) {\n"
    "    Logger.log('Initialized rolling status on ' + migrated + ' legacy assignment row(s).');\n"
    "  }\n\n"
    "  scriptProperties.setProperty(RUNTIME_SCHEMA_PROPERTY, RUNTIME_SCHEMA_VERSION);\n"
    "  Logger.log('Grade sheet is ready: ' + ss.getId());\n",
    "setup schema marker",
)

code = replace_once(
    code,
    "    const data = JSON.parse(e.postData.contents);\n"
    "    const spreadsheetId = PropertiesService\n"
    "      .getScriptProperties()\n"
    "      .getProperty('SPREADSHEET_ID');\n"
    "    if (!spreadsheetId) {\n"
    "      throw new Error('Run setupGradeSheet() before deploying the web app.');\n"
    "    }\n\n"
    "    const ss = SpreadsheetApp.openById(spreadsheetId);\n",
    "    const data = JSON.parse(e.postData.contents);\n"
    "    const runtimeProperties = PropertiesService\n"
    "      .getScriptProperties()\n"
    "      .getProperties();\n"
    "    const spreadsheetId = runtimeProperties.SPREADSHEET_ID;\n"
    "    if (!spreadsheetId) {\n"
    "      throw new Error('Run setupGradeSheet() before deploying the web app.');\n"
    "    }\n"
    "    if (!runtimeSchemaIsReady(runtimeProperties)) {\n"
    "      throw new Error(\n"
    "        'Run setupGradeSheet() after updating Code.gs before using the web app.'\n"
    "      );\n"
    "    }\n\n"
    "    const ss = SpreadsheetApp.openById(spreadsheetId);\n",
    "doPost schema marker",
)

for old, label in [
    ("  ensureSheetHeaders(eventsSheet, EVENT_HEADERS, EVENT_SHEET);\n", "event hot header validation"),
    ("    ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);\n", "assignment hot header validation"),
    ("    ensureSheetHeaders(reviewsSheet, REVIEW_HEADERS, REVIEW_SHEET);\n", "review hot header validation"),
    ("    ensureSheetHeaders(questionBankSheet, QUESTION_BANK_HEADERS, QUESTION_BANK_SHEET);\n", "bank hot header validation"),
    ("  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);\n  markServiceTimer(timer, 'sheets_ready');\n", "lookup hot header validation"),
    ("  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);\n  ensureSheetHeaders(questionBankSheet, QUESTION_BANK_HEADERS, QUESTION_BANK_SHEET);\n  ensureSheetHeaders(reviewsSheet, REVIEW_HEADERS, REVIEW_SHEET);\n  markServiceTimer(timer, 'sheets_ready');\n", "queue hot header validation"),
]:
    replacement = "  markServiceTimer(timer, 'sheets_ready');\n" if label in {"lookup hot header validation", "queue hot header validation"} else ""
    code = replace_once(code, old, replacement, label)

old_event_block = """    const existingRequestRow = findSheetRowByValue(
      eventsSheet,
      4,
      clean(data.request_id, 200)
    );
    const duplicate = Boolean(existingRequestRow);
    markServiceTimer(timer, 'idempotency_checked');

    if (existingRequestRow) {
      validateDuplicateEventMatches(
        eventsSheet.getRange(existingRequestRow, 1, 1, EVENT_HEADERS.length).getValues()[0],
        data
      );
      markServiceTimer(timer, 'duplicate_validated');
    } else {
      eventsSheet
        .getRange(eventsSheet.getLastRow() + 1, 1, 1, EVENT_HEADERS.length)
        .setValues([row]);
      markServiceTimer(timer, 'event_written');
    }

    let activeAssignments = null;
    if (isGraded) {
      refreshReviewForAssignment(
        eventsSheet,
        reviewsSheet,
        assignmentRecord.assignment
      );
      markServiceTimer(timer, 'review_refreshed');

      const review = getReviewForAssignment(
        reviewsSheet,
        assignmentRecord.assignment.assignment_id
      );
      if (!review) {
        throw new Error(
          'Compact review was not available after graded event for assignment ' +
          assignmentRecord.assignment.assignment_id + '.'
        );
      }
      markServiceTimer(timer, 'review_loaded');
"""

new_event_block = """    const existingRequestRow = findSheetRowByValue(
      eventsSheet,
      4,
      clean(data.request_id, 200)
    );
    const duplicate = Boolean(existingRequestRow);
    markServiceTimer(timer, 'idempotency_checked');

    let existingReviewRecord = null;
    let repairReviewFromEvents = duplicate;
    if (isGraded && !duplicate) {
      existingReviewRecord = getReviewRecordByAssignmentId(
        reviewsSheet,
        assignmentRecord.assignment.assignment_id
      );
      markServiceTimer(timer, 'review_index_checked');
      if (
        !existingReviewRecord &&
        hasEventForAssignment(eventsSheet, assignmentRecord.assignment.assignment_id)
      ) {
        repairReviewFromEvents = true;
        markServiceTimer(timer, 'prior_assignment_event_found');
      }
    }

    if (existingRequestRow) {
      validateDuplicateEventMatches(
        eventsSheet.getRange(existingRequestRow, 1, 1, EVENT_HEADERS.length).getValues()[0],
        data
      );
      markServiceTimer(timer, 'duplicate_validated');
    } else {
      eventsSheet
        .getRange(eventsSheet.getLastRow() + 1, 1, 1, EVENT_HEADERS.length)
        .setValues([row]);
      markServiceTimer(timer, 'event_written');
    }

    let activeAssignments = null;
    if (isGraded) {
      let review;
      if (repairReviewFromEvents) {
        review = refreshReviewForAssignment(
          eventsSheet,
          reviewsSheet,
          assignmentRecord.assignment
        );
        markServiceTimer(timer, 'review_rebuilt');
      } else {
        review = updateReviewForNewEvent(
          reviewsSheet,
          assignmentRecord.assignment,
          serverTimestamp,
          data.correct,
          existingReviewRecord
        );
        markServiceTimer(timer, 'review_updated');
      }

      if (!review) {
        throw new Error(
          'Compact review was not available after graded event for assignment ' +
          assignmentRecord.assignment.assignment_id + '.'
        );
      }
"""
code = replace_once(code, old_event_block, new_event_block, "incremental review hot path")

code = replace_once(
    code,
    """  let active = getActiveAssignmentsForStudent(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );
""",
    """  const assignmentRows = getAssignmentRows(assignmentsSheet);
  let active = activeAssignmentsFromRows(
    assignmentRows,
    data.course_id,
    data.student_id
  );
""",
    "queue assignment snapshot",
)

code = replace_once(
    code,
    """  const history = getAssignmentsForStudentHistory(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );
""",
    """  const history = assignmentsForStudentHistoryFromRows(
    assignmentRows,
    data.course_id,
    data.student_id
  );
""",
    "queue history snapshot",
)

code = replace_once(
    code,
    """  appendActiveAssignments(assignmentsSheet, selected, data, new Date().toISOString());
  active = getActiveAssignmentsForStudent(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );
""",
    """  const createdAssignments = appendActiveAssignments(
    assignmentsSheet,
    selected,
    data,
    new Date().toISOString()
  );
  active = sortAssignmentsOldestFirst(active.concat(createdAssignments));
""",
    "queue return snapshot",
)

code = replace_once(
    code,
    "function appendActiveAssignments(assignmentsSheet, selected, data, assignedAt) {\n  if (!selected.length) return;\n",
    "function appendActiveAssignments(assignmentsSheet, selected, data, assignedAt) {\n  if (!selected.length) return [];\n",
    "append empty return",
)

code = replace_once(
    code,
    """  assignmentsSheet
    .getRange(
      assignmentsSheet.getLastRow() + 1,
      1,
      rows.length,
      ASSIGNMENT_HEADERS.length
    )
    .setValues(rows);
}
""",
    """  assignmentsSheet
    .getRange(
      assignmentsSheet.getLastRow() + 1,
      1,
      rows.length,
      ASSIGNMENT_HEADERS.length
    )
    .setValues(rows);

  return rows.map(assignmentRowToObject);
}
""",
    "append returns assignments",
)

old_refresh = """function refreshReviewForAssignment(eventsSheet, reviewsSheet, assignment) {
  const eventRows = getGradedEventRowsForAssignment(eventsSheet, assignment);
  if (!eventRows.length) {
    throw new Error(
      'No graded event rows were found while refreshing review ' + assignment.assignment_id + '.'
    );
  }

  const compact = compactReviewRowsFromEvents(
    [assignmentObjectToRow(assignment)],
    eventRows
  );
  if (compact.length !== 1) {
    throw new Error('Expected exactly one compact review row for assignment ' + assignment.assignment_id + '.');
  }

  const rowIndex = findSheetRowByValue(
    reviewsSheet,
    1,
    assignment.assignment_id
  );
  if (rowIndex) {
    reviewsSheet
      .getRange(rowIndex, 1, 1, REVIEW_HEADERS.length)
      .setValues([compact[0]]);
  } else {
    reviewsSheet
      .getRange(reviewsSheet.getLastRow() + 1, 1, 1, REVIEW_HEADERS.length)
      .setValues([compact[0]]);
  }
}

function getReviewForAssignment(reviewsSheet, assignmentId) {
  const rowIndex = findSheetRowByValue(reviewsSheet, 1, assignmentId);
  if (!rowIndex) return null;
  return reviewRowToObject(
    reviewsSheet
      .getRange(rowIndex, 1, 1, REVIEW_HEADERS.length)
      .getValues()[0]
  );
}
"""

new_refresh = """function refreshReviewForAssignment(eventsSheet, reviewsSheet, assignment) {
  const eventRows = getGradedEventRowsForAssignment(eventsSheet, assignment);
  if (!eventRows.length) {
    throw new Error(
      'No graded event rows were found while refreshing review ' + assignment.assignment_id + '.'
    );
  }

  const compact = compactReviewRowsFromEvents(
    [assignmentObjectToRow(assignment)],
    eventRows
  );
  if (compact.length !== 1) {
    throw new Error('Expected exactly one compact review row for assignment ' + assignment.assignment_id + '.');
  }

  const rowIndex = findSheetRowByValue(
    reviewsSheet,
    1,
    assignment.assignment_id
  );
  if (rowIndex) {
    reviewsSheet
      .getRange(rowIndex, 1, 1, REVIEW_HEADERS.length)
      .setValues([compact[0]]);
  } else {
    reviewsSheet
      .getRange(reviewsSheet.getLastRow() + 1, 1, 1, REVIEW_HEADERS.length)
      .setValues([compact[0]]);
  }

  return reviewRowToObject(compact[0]);
}

function reviewRowAfterNewEvent(existingRow, assignment, eventTime, correct) {
  const attemptTime = new Date(eventTime);
  if (isNaN(attemptTime.getTime())) {
    throw new Error('Invalid review event time.');
  }

  if (!existingRow) {
    return [
      assignment.assignment_id,
      assignment.course_id,
      assignment.week_id,
      assignment.student_id,
      assignment.item_label,
      assignment.topic,
      attemptTime.toISOString(),
      eventCorrectBoolean(correct),
      1,
      attemptTime.toISOString()
    ];
  }

  const review = reviewRowToObject(existingRow);
  validateReviewAgainstAssignment(review, assignment);

  let firstAttemptAt = review.first_attempt_at;
  let firstAttemptCorrect = review.first_attempt_correct;
  if (attemptTime.getTime() < firstAttemptAt.getTime()) {
    firstAttemptAt = attemptTime;
    firstAttemptCorrect = eventCorrectBoolean(correct);
  }

  const lastAttemptAt = attemptTime.getTime() > review.last_attempt_at.getTime()
    ? attemptTime
    : review.last_attempt_at;

  return [
    assignment.assignment_id,
    assignment.course_id,
    assignment.week_id,
    assignment.student_id,
    assignment.item_label,
    assignment.topic,
    firstAttemptAt.toISOString(),
    firstAttemptCorrect,
    review.attempt_count + 1,
    lastAttemptAt.toISOString()
  ];
}

function validateReviewAgainstAssignment(review, assignment) {
  const checks = [
    [review.assignment_id, assignment.assignment_id, 'assignment_id'],
    [review.course_id, assignment.course_id, 'course_id'],
    [review.student_id, assignment.student_id, 'student_id'],
    [review.item_label, assignment.item_label, 'item_label'],
    [review.topic, assignment.topic, 'topic']
  ];
  checks.forEach(function(check) {
    if (String(check[0] || '') !== String(check[1] || '')) {
      throw new Error(
        'Compact review does not match persisted assignment ' + assignment.assignment_id +
        ': ' + check[2] + '.'
      );
    }
  });
}

function getReviewRecordByAssignmentId(reviewsSheet, assignmentId) {
  const rowIndex = findSheetRowByValue(reviewsSheet, 1, assignmentId);
  if (!rowIndex) return null;
  const row = reviewsSheet
    .getRange(rowIndex, 1, 1, REVIEW_HEADERS.length)
    .getValues()[0];
  return {
    row_index: rowIndex,
    row: row,
    review: reviewRowToObject(row)
  };
}

function updateReviewForNewEvent(
  reviewsSheet,
  assignment,
  eventTime,
  correct,
  existingRecord
) {
  const nextRow = reviewRowAfterNewEvent(
    existingRecord ? existingRecord.row : null,
    assignment,
    eventTime,
    correct
  );

  if (existingRecord) {
    reviewsSheet
      .getRange(existingRecord.row_index, 1, 1, REVIEW_HEADERS.length)
      .setValues([nextRow]);
  } else {
    reviewsSheet
      .getRange(reviewsSheet.getLastRow() + 1, 1, 1, REVIEW_HEADERS.length)
      .setValues([nextRow]);
  }

  return reviewRowToObject(nextRow);
}

function getReviewForAssignment(reviewsSheet, assignmentId) {
  const record = getReviewRecordByAssignmentId(reviewsSheet, assignmentId);
  return record ? record.review : null;
}

function hasEventForAssignment(eventsSheet, assignmentId) {
  if (eventsSheet.getLastRow() <= 1) return false;
  return Boolean(
    eventsSheet
      .getRange(2, 22, eventsSheet.getLastRow() - 1, 1)
      .createTextFinder(String(assignmentId))
      .matchEntireCell(true)
      .findNext()
  );
}
"""
code = replace_once(code, old_refresh, new_refresh, "review helper optimization")

old_assignment_helpers = """function activeAssignmentsFromRows(assignmentRows, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return assignmentRows
    .filter(function(row) {
      return (
        row[1] === courseKey &&
        row[3] === studentKey &&
        String(row[10] || '') === ASSIGNMENT_STATUS_ACTIVE
      );
    })
    .map(assignmentRowToObject)
    .sort(function(aa, bb) {
      const aaTime = new Date(aa.assigned_at_utc).getTime();
      const bbTime = new Date(bb.assigned_at_utc).getTime();
      const safeAA = isNaN(aaTime) ? 0 : aaTime;
      const safeBB = isNaN(bbTime) ? 0 : bbTime;
      return safeAA - safeBB;
    });
}

function getActiveAssignmentsForStudent(sheet, courseId, studentId) {
  return activeAssignmentsFromRows(
    getAssignmentRows(sheet),
    courseId,
    studentId
  );
}

function getAssignmentsForStudentHistory(sheet, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return getAssignmentRows(sheet)
    .filter(function(row) {
      return row[1] === courseKey && row[3] === studentKey;
    })
    .map(assignmentRowToObject);
}
"""

new_assignment_helpers = """function sortAssignmentsOldestFirst(assignments) {
  return assignments
    .slice()
    .sort(function(aa, bb) {
      const aaTime = new Date(aa.assigned_at_utc).getTime();
      const bbTime = new Date(bb.assigned_at_utc).getTime();
      const safeAA = isNaN(aaTime) ? 0 : aaTime;
      const safeBB = isNaN(bbTime) ? 0 : bbTime;
      return safeAA - safeBB;
    });
}

function activeAssignmentsFromRows(assignmentRows, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return sortAssignmentsOldestFirst(
    assignmentRows
      .filter(function(row) {
        return (
          row[1] === courseKey &&
          row[3] === studentKey &&
          String(row[10] || '') === ASSIGNMENT_STATUS_ACTIVE
        );
      })
      .map(assignmentRowToObject)
  );
}

function assignmentsForStudentHistoryFromRows(assignmentRows, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return assignmentRows
    .filter(function(row) {
      return row[1] === courseKey && row[3] === studentKey;
    })
    .map(assignmentRowToObject);
}

function getActiveAssignmentsForStudent(sheet, courseId, studentId) {
  return activeAssignmentsFromRows(
    getAssignmentRows(sheet),
    courseId,
    studentId
  );
}

function getAssignmentsForStudentHistory(sheet, courseId, studentId) {
  return assignmentsForStudentHistoryFromRows(
    getAssignmentRows(sheet),
    courseId,
    studentId
  );
}
"""
code = replace_once(code, old_assignment_helpers, new_assignment_helpers, "assignment snapshot helpers")

code = replace_once(
    code,
    "function startServiceTimer(operation, requestId) {\n",
    "function runtimeSchemaIsReady(runtimeProperties) {\n"
    "  return Boolean(\n"
    "    runtimeProperties &&\n"
    "    String(runtimeProperties[RUNTIME_SCHEMA_PROPERTY] || '') === RUNTIME_SCHEMA_VERSION\n"
    "  );\n"
    "}\n\n"
    "function startServiceTimer(operation, requestId) {\n",
    "runtime schema helper",
)

code_path.write_text(code)


test_path = Path("tests/js/test-fsrs.js")
test = test_path.read_text()

test = replace_once(
    test,
    "      legacyAssignmentMigrationValues,\n",
    "      legacyAssignmentMigrationValues,\n"
    "      reviewRowAfterNewEvent,\n"
    "      assignmentsForStudentHistoryFromRows,\n"
    "      sortAssignmentsOldestFirst,\n"
    "      runtimeSchemaIsReady,\n"
    "      RUNTIME_SCHEMA_PROPERTY,\n"
    "      RUNTIME_SCHEMA_VERSION,\n",
    "export performance helpers",
)

insert_before = "console.log('FSRS, mastery-frontier, review-history, and rolling-queue helper tests passed.');\n"
extra_tests = r"""
const runtimeProperties = {};
runtimeProperties[api.RUNTIME_SCHEMA_PROPERTY] = api.RUNTIME_SCHEMA_VERSION;
assert(
  api.runtimeSchemaIsReady(runtimeProperties) === true,
  'The runtime schema marker should accept the current schema version.'
);
assert(
  api.runtimeSchemaIsReady({}) === false,
  'A missing runtime schema marker should require setupGradeSheet().' 
);

const incrementalAssignment = {
  assignment_id: 'incremental-a1',
  course_id: 'R101',
  week_id: 'week-01',
  student_id: 'abc123',
  item_label: 'incremental-q1',
  topic: 'weak'
};
const incrementalFirstRow = api.reviewRowAfterNewEvent(
  null,
  incrementalAssignment,
  '2026-01-01T12:00:00Z',
  false
);
const incrementalFirst = api.reviewRowToObject(incrementalFirstRow);
assert(
  incrementalFirst.first_attempt_correct === false &&
    incrementalFirst.attempt_count === 1,
  'The first incremental review update should create one failed first attempt.'
);
const incrementalSecondRow = api.reviewRowAfterNewEvent(
  incrementalFirstRow,
  incrementalAssignment,
  '2026-01-01T12:01:00Z',
  true
);
const incrementalSecond = api.reviewRowToObject(incrementalSecondRow);
assert(
  incrementalSecond.first_attempt_correct === false &&
    incrementalSecond.attempt_count === 2 &&
    incrementalSecond.last_attempt_at.getTime() ===
      new Date('2026-01-01T12:01:00Z').getTime(),
  'Incremental review updates must preserve first-attempt outcome while advancing count/time.'
);

const snapshotHistory = api.assignmentsForStudentHistoryFromRows(
  activeRows,
  'R101',
  'abc123'
);
assert(
  snapshotHistory.length === 3,
  'One assignment-sheet snapshot should retain both active and retired history rows.'
);
const snapshotSorted = api.sortAssignmentsOldestFirst([
  api.activeAssignmentsFromRows(activeRows, 'R101', 'abc123')[1],
  api.activeAssignmentsFromRows(activeRows, 'R101', 'abc123')[0]
]);
assert(
  snapshotSorted.map(function(row) { return row.item_label; }).join(',') === 'q-old,q-new',
  'In-memory queue reconstruction should preserve oldest-to-newest ordering.'
);

"""
if insert_before not in test:
    raise RuntimeError("performance test insertion point not found")
test = test.replace(insert_before, extra_tests + insert_before, 1)
test_path.write_text(test)

print("Applied assignment-service performance patch.")

const EVENT_SHEET = 'events';
const ASSIGNMENT_SHEET = 'assignments';
const QUESTION_BANK_SHEET = 'question_bank';
const REVIEW_SHEET = 'reviews';

const EVENT_HEADERS = [
  'server_timestamp_utc',
  'client_timestamp_utc',
  'schema_version',
  'request_id',
  'course_id',
  'week_id',
  'session_token',
  'student_id',
  'student_name',
  'event',
  'item_label',
  'attempt_id',
  'submitted_code',
  'correct',
  'answer',
  'checked',
  'restore',
  'time_elapsed_sec',
  'timeout_exceeded',
  'error_message',
  'topic',
  'assignment_id'
];

const ASSIGNMENT_HEADERS = [
  'assignment_id',
  'course_id',
  'week_id',
  'student_id',
  'item_label',
  'topic',
  'points',
  'legacy_unused_content',
  'assigned_at_utc',
  'assignment_reason',
  'assignment_status',
  'retired_at_utc',
  'retired_reason',
  'retired_request_id'
];

const QUESTION_BANK_HEADERS = [
  'item_label',
  'event',
  'topic',
  'points',
  'starter_question',
  'legacy_unused_1',
  'legacy_unused_2'
];

// One compact row per persisted assignment exposure after its first graded
// attempt. This is the scheduler/mastery index; events remains the full audit log.
const REVIEW_HEADERS = [
  'assignment_id',
  'course_id',
  'week_id',
  'student_id',
  'item_label',
  'topic',
  'first_attempt_at_utc',
  'first_attempt_correct',
  'attempt_count',
  'last_attempt_at_utc'
];

const ALLOWED_EVENTS = [
  'identity_saved',
  'exercise_result',
  'question_submission',
  'logging_test'
];

const GRADED_EVENTS = [
  'exercise_result',
  'question_submission'
];

const ASSIGNMENT_STATUS_ACTIVE = 'active';
const ASSIGNMENT_STATUS_RETIRED = 'retired';
const FSRS_DUE_RETRIEVABILITY = 0.9;
const RUNTIME_SCHEMA_PROPERTY = 'RUNTIME_SCHEMA_VERSION';
const RUNTIME_SCHEMA_VERSION = 'item-label-reconciliation-v1';

// FSRS-6 default parameters from the Open Spaced Repetition reference
// implementations. Each canonical topic is one FSRS memory item; literal
// questions are interchangeable probes of that topic.
const FSRS_PARAMETERS = [
  0.212,
  1.2931,
  2.3065,
  8.2956,
  6.4133,
  0.8334,
  3.0194,
  0.001,
  1.8722,
  0.1666,
  0.796,
  1.4835,
  0.0614,
  0.2629,
  1.6483,
  0.6014,
  1.8729,
  0.5425,
  0.0912,
  0.0658,
  0.1542
];
const FSRS_STABILITY_MIN = 0.001;
const FSRS_DIFFICULTY_MIN = 1.0;
const FSRS_DIFFICULTY_MAX = 10.0;
const FSRS_RATING_AGAIN = 1;
const FSRS_RATING_GOOD = 3;
const FSRS_DECAY = -FSRS_PARAMETERS[20];
const FSRS_FACTOR = Math.pow(0.9, 1 / FSRS_DECAY) - 1;
const MILLIS_PER_DAY = 24 * 60 * 60 * 1000;

// Spreadsheet setup and migrations ------------------------------------------

/**
 * Initializes the bound grading spreadsheet, managed sheets, migrations, and
 * runtime schema marker so the deployed web app can safely serve requests.
 *
 * Manual instructor entry point; not called by another repository function.
 * Depends on migrateLegacyPlaceholderHeaders() in SchemaMigration.gs,
 * ensureManagedSheet(), rebuildReviewHistoryForSpreadsheet(), and
 * migrateLegacyAssignmentsForRollingQueue().
 *
 * @return {void}
 */
function setupGradeSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) throw new Error('Run this from a script bound to the grading spreadsheet.');

  const scriptProperties = PropertiesService.getScriptProperties();
  scriptProperties.setProperty('SPREADSHEET_ID', ss.getId());

  migrateLegacyPlaceholderHeaders(ss);

  const eventSheet = ensureManagedSheet(ss, EVENT_SHEET, EVENT_HEADERS);
  const assignmentSheet = ensureManagedSheet(ss, ASSIGNMENT_SHEET, ASSIGNMENT_HEADERS);
  ensureManagedSheet(ss, QUESTION_BANK_SHEET, QUESTION_BANK_HEADERS);
  const reviewSheet = ensureManagedSheet(ss, REVIEW_SHEET, REVIEW_HEADERS);

  if (
    reviewSheet.getLastRow() <= 1 &&
    eventSheet.getLastRow() > 1 &&
    assignmentSheet.getLastRow() > 1
  ) {
    const rebuilt = rebuildReviewHistoryForSpreadsheet(ss);
    Logger.log('Backfilled ' + rebuilt + ' compact review row(s) from existing events.');
  }

  const migrated = migrateLegacyAssignmentsForRollingQueue(ss);
  if (migrated) {
    Logger.log('Initialized rolling status on ' + migrated + ' legacy assignment row(s).');
  }

  scriptProperties.setProperty(RUNTIME_SCHEMA_PROPERTY, RUNTIME_SCHEMA_VERSION);
  Logger.log('Grade sheet is ready: ' + ss.getId());
}

/**
 * Rebuilds the compact review index for the active bound spreadsheet from the
 * authoritative assignment and event history.
 *
 * Manual instructor maintenance entry point; not called by another repository
 * function. Depends on ensureManagedSheet() and
 * rebuildReviewHistoryForSpreadsheet().
 *
 * @return {number} Number of compact review rows rebuilt.
 */
function rebuildReviewHistory() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) throw new Error('Run this from a script bound to the grading spreadsheet.');

  ensureManagedSheet(ss, EVENT_SHEET, EVENT_HEADERS);
  ensureManagedSheet(ss, ASSIGNMENT_SHEET, ASSIGNMENT_HEADERS);
  ensureManagedSheet(ss, REVIEW_SHEET, REVIEW_HEADERS);

  const rebuilt = rebuildReviewHistoryForSpreadsheet(ss);
  Logger.log('Rebuilt ' + rebuilt + ' compact review row(s).');
  return rebuilt;
}

/**
 * Recomputes all compact review rows for one spreadsheet and replaces the
 * reviews-sheet data with the reconstructed result.
 *
 * Called by setupGradeSheet() and rebuildReviewHistory(). Depends on
 * ensureSheetHeaders(), getAssignmentRows(), getEventRows(), and
 * compactReviewRowsFromEvents().
 *
 * @param {GoogleAppsScript.Spreadsheet.Spreadsheet} ss Grading spreadsheet.
 * @return {number} Number of review rows written.
 */
function rebuildReviewHistoryForSpreadsheet(ss) {
  const started = Date.now();
  const assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  const eventsSheet = ss.getSheetByName(EVENT_SHEET);
  const reviewsSheet = ss.getSheetByName(REVIEW_SHEET);

  if (!assignmentsSheet || !eventsSheet || !reviewsSheet) {
    throw new Error('assignments, events, and reviews sheets must exist before rebuilding reviews.');
  }

  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);
  ensureSheetHeaders(eventsSheet, EVENT_HEADERS, EVENT_SHEET);
  ensureSheetHeaders(reviewsSheet, REVIEW_HEADERS, REVIEW_SHEET);

  const assignmentRows = getAssignmentRows(assignmentsSheet);
  const eventRows = getEventRows(eventsSheet);
  const reviewRows = compactReviewRowsFromEvents(assignmentRows, eventRows);

  if (reviewsSheet.getLastRow() > 1) {
    reviewsSheet
      .getRange(2, 1, reviewsSheet.getLastRow() - 1, REVIEW_HEADERS.length)
      .clearContent();
  }
  if (reviewRows.length) {
    reviewsSheet
      .getRange(2, 1, reviewRows.length, REVIEW_HEADERS.length)
      .setValues(reviewRows);
  }

  console.log(
    'service_timing ' + JSON.stringify({
      operation: 'rebuild_review_history',
      assignment_rows: assignmentRows.length,
      event_rows: eventRows.length,
      review_rows: reviewRows.length,
      total_ms: Date.now() - started
    })
  );

  return reviewRows.length;
}

/**
 * Initializes rolling active/retired status fields for pre-rolling assignment
 * rows while preserving their historical exposure records.
 *
 * Called only by setupGradeSheet(). Depends on ensureSheetHeaders(),
 * getAssignmentRows(), getEventRows(), and legacyAssignmentMigrationValues().
 *
 * @param {GoogleAppsScript.Spreadsheet.Spreadsheet} ss Grading spreadsheet.
 * @return {number} Number of legacy assignment rows requiring migration.
 */
function migrateLegacyAssignmentsForRollingQueue(ss) {
  const assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  const eventsSheet = ss.getSheetByName(EVENT_SHEET);
  if (!assignmentsSheet || !eventsSheet || assignmentsSheet.getLastRow() <= 1) return 0;

  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);
  ensureSheetHeaders(eventsSheet, EVENT_HEADERS, EVENT_SHEET);

  const assignmentRows = getAssignmentRows(assignmentsSheet);
  const legacyCount = assignmentRows.filter(function(row) {
    return !String(row[10] || '').trim();
  }).length;
  if (!legacyCount) return 0;

  const migrationTime = new Date().toISOString();
  const statusValues = legacyAssignmentMigrationValues(
    assignmentRows,
    getEventRows(eventsSheet),
    migrationTime
  );

  assignmentsSheet
    .getRange(2, 11, statusValues.length, 4)
    .setValues(statusValues);

  return legacyCount;
}

/**
 * Derives rolling status/retirement fields for legacy assignments from their
 * assignment times and historical correct events without modifying sheets.
 *
 * Called by migrateLegacyAssignmentsForRollingQueue() and directly by the FSRS
 * JavaScript tests. Depends on eventCorrectBoolean() and rolling-status constants.
 *
 * @param {Array<Array<*>>} assignmentRows Assignment-sheet rows.
 * @param {Array<Array<*>>} eventRows Event-sheet rows.
 * @param {string} migrationTime ISO timestamp used for migration retirements.
 * @return {Array<Array<*>>} Four-column rolling-state values for every row.
 */
function legacyAssignmentMigrationValues(assignmentRows, eventRows, migrationTime) {
  const latestAssignedByStudent = {};
  const correctByAssignment = {};

  assignmentRows.forEach(function(row) {
    if (String(row[10] || '').trim()) return;
    const key = String(row[1] || '') + '\n' + String(row[3] || '');
    const timestamp = new Date(row[8]).getTime();
    const comparable = isNaN(timestamp) ? -Infinity : timestamp;
    if (
      !Object.prototype.hasOwnProperty.call(latestAssignedByStudent, key) ||
      comparable > latestAssignedByStudent[key]
    ) {
      latestAssignedByStudent[key] = comparable;
    }
  });

  eventRows.forEach(function(row) {
    if (!GRADED_EVENTS.includes(String(row[9] || ''))) return;
    if (!eventCorrectBoolean(row[13])) return;
    const assignmentId = String(row[21] || '');
    if (!assignmentId) return;

    const timestamp = new Date(row[0]);
    if (isNaN(timestamp.getTime())) return;
    const existing = correctByAssignment[assignmentId];
    if (!existing || timestamp.getTime() < existing.timestamp.getTime()) {
      correctByAssignment[assignmentId] = {
        timestamp: timestamp,
        request_id: String(row[3] || '')
      };
    }
  });

  return assignmentRows.map(function(row) {
    const existingStatus = String(row[10] || '').trim();
    if (existingStatus) {
      return [row[10], row[11], row[12], row[13]];
    }

    const key = String(row[1] || '') + '\n' + String(row[3] || '');
    const timestamp = new Date(row[8]).getTime();
    const comparable = isNaN(timestamp) ? -Infinity : timestamp;
    const latest = latestAssignedByStudent[key];
    const correct = correctByAssignment[String(row[0] || '')];

    if (comparable < latest) {
      return [
        ASSIGNMENT_STATUS_RETIRED,
        migrationTime,
        'legacy_previous_queue',
        ''
      ];
    }

    if (correct) {
      return [
        ASSIGNMENT_STATUS_RETIRED,
        correct.timestamp.toISOString(),
        'legacy_already_correct',
        correct.request_id
      ];
    }

    return [ASSIGNMENT_STATUS_ACTIVE, '', '', ''];
  });
}

/**
 * Creates or validates a managed sheet, applies its standard header styling,
 * and returns the usable Sheet object.
 *
 * Called by setupGradeSheet() and rebuildReviewHistory(). Depends on
 * ensureSheetHeaders().
 *
 * @param {GoogleAppsScript.Spreadsheet.Spreadsheet} ss Grading spreadsheet.
 * @param {string} sheetName Managed sheet name.
 * @param {string[]} headers Required ordered headers.
 * @return {GoogleAppsScript.Spreadsheet.Sheet} Created or validated sheet.
 */
function ensureManagedSheet(ss, sheetName, headers) {
  let sheet = ss.getSheetByName(sheetName);
  if (!sheet) sheet = ss.insertSheet(sheetName);

  ensureSheetHeaders(sheet, headers, sheetName);

  sheet.setFrozenRows(1);
  sheet.getRange(1, 1, 1, headers.length).setFontWeight('bold');
  sheet.autoResizeColumns(1, headers.length);

  return sheet;
}

/**
 * Verifies that an existing managed sheet has the expected prefix of headers,
 * adding only missing trailing headers when the schema has grown.
 *
 * Called by ensureManagedSheet(), rebuildReviewHistoryForSpreadsheet(), and
 * migrateLegacyAssignmentsForRollingQueue(). It has no within-repo function
 * dependencies.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Sheet to validate.
 * @param {string[]} headers Required ordered headers.
 * @param {string} sheetName Human-readable sheet name for errors.
 * @return {void}
 */
function ensureSheetHeaders(sheet, headers, sheetName) {
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    return;
  }

  const currentHeaders = sheet
    .getRange(1, 1, 1, sheet.getLastColumn())
    .getValues()[0];

  if (currentHeaders.length > headers.length) {
    throw new Error(
      'The existing ' + sheetName + ' header has unexpected extra columns. No data were changed.'
    );
  }

  for (let ii = 0; ii < currentHeaders.length; ii++) {
    if (currentHeaders[ii] !== headers[ii]) {
      throw new Error(
        'The existing ' + sheetName + ' header does not match this schema. No data were changed.'
      );
    }
  }

  if (currentHeaders.length < headers.length) {
    const missingHeaders = headers.slice(currentHeaders.length);
    sheet
      .getRange(1, currentHeaders.length + 1, 1, missingHeaders.length)
      .setValues([missingHeaders]);
  }
}

// Web app entry points and request handlers ----------------------------------

/**
 * Responds to HTTP GET health checks with the service identity and schema.
 *
 * Apps Script web-app entry point; called by the platform rather than by a
 * repository function. Depends on jsonResponse().
 *
 * @return {GoogleAppsScript.Content.TextOutput} JSON health response.
 */
function doGet() {
  return jsonResponse({
    ok: true,
    service: 'learnr-grade-logger',
    schema_version: '1'
  });
}

/**
 * Parses and routes incoming HTTP POST requests to event logging or assignment
 * handlers, returning errors as JSON rather than uncaught web-app exceptions.
 *
 * Apps Script web-app entry point. Depends on runtimeSchemaIsReady(),
 * handleLogEvent(), handleGetActiveAssignments(),
 * handleGetOrCreateActiveAssignments(), and jsonResponse().
 *
 * @param {GoogleAppsScript.Events.DoPost} e Apps Script POST event.
 * @return {GoogleAppsScript.Content.TextOutput} JSON service response.
 */
function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      throw new Error('Missing JSON request body.');
    }

    const data = JSON.parse(e.postData.contents);
    const runtimeProperties = PropertiesService
      .getScriptProperties()
      .getProperties();
    const spreadsheetId = runtimeProperties.SPREADSHEET_ID;
    if (!spreadsheetId) {
      throw new Error('Run setupGradeSheet() before deploying the web app.');
    }
    if (!runtimeSchemaIsReady(runtimeProperties)) {
      throw new Error(
        'Run setupGradeSheet() after updating Code.gs before using the web app.'
      );
    }

    const ss = SpreadsheetApp.openById(spreadsheetId);
    const requestType = String(data.request_type || 'log_event');

    if (requestType === 'log_event') {
      return handleLogEvent(data, ss);
    }

    if (requestType === 'get_active_assignments') {
      return handleGetActiveAssignments(data, ss);
    }

    if (requestType === 'get_or_create_active_assignments') {
      return handleGetOrCreateActiveAssignments(data, ss);
    }

    throw new Error('Unsupported request_type.');
  } catch (err) {
    console.error(err);
    return jsonResponse({
      ok: false,
      error: String(err && err.message ? err.message : err)
    });
  }
}

/**
 * Validates and idempotently persists one client event, maintains the compact
 * review index, retires correct assignments, and optionally refills the queue.
 *
 * Called by doPost(). Depends on validation, snapshot, review, queue, timing,
 * scalar/response helpers in this file plus requestUsesBankReconciliation(),
 * bankReconciliationForRequest(), and attachBankReconciliation() from
 * BankReconciliation.gs.
 *
 * @param {Object} data Parsed log_event request payload.
 * @param {GoogleAppsScript.Spreadsheet.Spreadsheet} ss Grading spreadsheet.
 * @return {GoogleAppsScript.Content.TextOutput} JSON write/duplicate response,
 * optionally including the updated active assignments.
 */
function handleLogEvent(data, ss) {
  validateEventPayload(data);

  const timer = startServiceTimer('log_event', data.request_id);
  const eventsSheet = ss.getSheetByName(EVENT_SHEET);
  if (!eventsSheet) throw new Error('The events sheet does not exist.');

  const isGraded = GRADED_EVENTS.includes(String(data.event));
  const isCorrect = isGraded && eventCorrectBoolean(data.correct);
  let assignmentsSheet = null;
  let reviewsSheet = null;
  let questionBankSheet = null;

  if (isGraded) {
    assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
    reviewsSheet = ss.getSheetByName(REVIEW_SHEET);
    questionBankSheet = ss.getSheetByName(QUESTION_BANK_SHEET);
    if (!assignmentsSheet || !reviewsSheet || !questionBankSheet) {
      throw new Error(
        'assignments, reviews, and question_bank must exist. Run setupGradeSheet() after updating Code.gs.'
      );
    }
  }

  let bankReconciliation = null;
  if (isGraded && requestUsesBankReconciliation(data)) {
    bankReconciliation = bankReconciliationForRequest(data, questionBankSheet);
    if (!bankReconciliation.compatible) {
      return jsonResponse(bankReconciliation.response);
    }
  }

  const serverTimestamp = new Date().toISOString();
  const row = [
    serverTimestamp,
    clean(data.client_timestamp_utc, 100),
    clean(data.schema_version, 20),
    clean(data.request_id, 200),
    clean(data.course_id, 200),
    '',
    clean(data.session_token, 300),
    clean(data.student_id, 200),
    clean(data.student_name, 300),
    clean(data.event, 100),
    clean(data.item_label, 300),
    clean(data.attempt_id, 300),
    clean(data.submitted_code, 20000),
    clean(data.correct, 50),
    clean(data.answer, 5000),
    clean(data.checked, 50),
    clean(data.restore, 50),
    clean(data.time_elapsed_sec, 100),
    clean(data.timeout_exceeded, 50),
    clean(data.error_message, 5000),
    clean(data.topic, 300),
    clean(data.assignment_id, 300)
  ];

  markServiceTimer(timer, 'sheets_ready');

  // Slow Spreadsheet reads happen before the global write lock. Concurrent
  // requests reconcile only rows appended after these snapshots once they hold
  // the lock. Existing assignment status is rechecked only when correctness can
  // retire the submitted assignment.
  const eventSnapshot = readSheetSnapshot(eventsSheet, EVENT_HEADERS.length);
  markServiceTimer(timer, 'events_snapshotted');

  let assignmentSnapshot = null;
  let reviewIndexSnapshot = null;
  let assignmentRecord = null;
  let queueConfig = null;
  let bank = null;

  if (isGraded) {
    assignmentSnapshot = readSheetSnapshot(
      assignmentsSheet,
      ASSIGNMENT_HEADERS.length
    );
    assignmentRecord = getAssignmentRecordByIdFromRows(
      assignmentSnapshot.rows,
      clean(data.assignment_id, 300)
    );
    if (!assignmentRecord) {
      throw new Error('Unknown assignment_id for graded event.');
    }
    validateGradedEventAgainstAssignment(data, assignmentRecord.assignment);
    markServiceTimer(timer, 'assignment_validated');

    reviewIndexSnapshot = readColumnSnapshot(reviewsSheet, 1);
    markServiceTimer(timer, 'review_index_snapshotted');

    if (isCorrect) {
      queueConfig = optionalQueueSelectionConfig(data);
      if (queueConfig) {
        bank = getQuestionBank(questionBankSheet);
        markServiceTimer(timer, 'question_bank_loaded');
      }
    }
  }

  const preexistingRequest = findEventRowByRequestIdFromRows(
    eventSnapshot.rows,
    clean(data.request_id, 200)
  );
  if (preexistingRequest) {
    validateDuplicateEventMatches(preexistingRequest.row, data);
  }
  markServiceTimer(timer, 'idempotency_prechecked');

  const lock = LockService.getScriptLock();
  timer.lock_requested_at_ms = Date.now();
  lock.waitLock(10000);
  timer.lock_acquired_at_ms = Date.now();
  timer.lock_wait_ms = timer.lock_acquired_at_ms - timer.lock_requested_at_ms;
  markServiceTimer(timer, 'lock_acquired');

  try {
    extendSheetSnapshot(eventsSheet, eventSnapshot, EVENT_HEADERS.length);
    if (isGraded) {
      extendSheetSnapshot(
        assignmentsSheet,
        assignmentSnapshot,
        ASSIGNMENT_HEADERS.length
      );
      extendColumnSnapshot(reviewsSheet, reviewIndexSnapshot, 1);
    }
    markServiceTimer(timer, 'snapshots_reconciled');

    const existingRequest = findEventRowByRequestIdFromRows(
      eventSnapshot.rows,
      clean(data.request_id, 200)
    );
    const duplicate = Boolean(existingRequest);
    if (duplicate) {
      validateDuplicateEventMatches(existingRequest.row, data);
      markServiceTimer(timer, 'duplicate_validated');
    } else {
      appendRowToSnapshot(
        eventsSheet,
        eventSnapshot,
        row,
        EVENT_HEADERS.length
      );
      markServiceTimer(timer, 'event_written');
    }

    let activeAssignments = null;
    if (isGraded) {
      let effectiveAssignmentRows = applyCorrectEventRetirementsToAssignmentRows(
        assignmentSnapshot.rows,
        eventSnapshot.rows
      );
      assignmentRecord = getAssignmentRecordByIdFromRows(
        effectiveAssignmentRows,
        clean(data.assignment_id, 300)
      );
      if (!assignmentRecord) {
        throw new Error('Unknown assignment_id after snapshot reconciliation.');
      }

      const compactReviewRow = compactReviewRowForAssignment(
        effectiveAssignmentRows,
        eventSnapshot.rows,
        assignmentRecord.assignment
      );
      upsertReviewRowFromSnapshot(
        reviewsSheet,
        reviewIndexSnapshot,
        assignmentRecord.assignment.assignment_id,
        compactReviewRow
      );
      const review = reviewRowToObject(compactReviewRow);
      markServiceTimer(timer, duplicate ? 'review_rebuilt' : 'review_updated');

      if (isCorrect) {
        // A same-student request may have retired this row after our pre-lock
        // snapshot. Re-read only the four rolling-state cells, not the row/table.
        const currentState = assignmentsSheet
          .getRange(assignmentRecord.row_index, 11, 1, 4)
          .getValues()[0];
        const currentStatus = String(currentState[0] || '');
        markServiceTimer(timer, 'assignment_status_checked');

        if (currentStatus === ASSIGNMENT_STATUS_ACTIVE) {
          const retiredReason = review.first_attempt_correct
            ? 'correct_first_try'
            : 'correct_after_retry';
          assignmentsSheet
            .getRange(assignmentRecord.row_index, 11, 1, 4)
            .setValues([[
              ASSIGNMENT_STATUS_RETIRED,
              serverTimestamp,
              retiredReason,
              clean(data.request_id, 200)
            ]]);
        } else if (currentStatus !== ASSIGNMENT_STATUS_RETIRED) {
          throw new Error(
            'Assignment has no rolling status. Run setupGradeSheet() before using the rolling queue.'
          );
        }
        markServiceTimer(timer, 'assignment_retired');

        // The event log is authoritative for logical retirement while the
        // assignment snapshot may have been read before a concurrent write.
        effectiveAssignmentRows = applyCorrectEventRetirementsToAssignmentRows(
          assignmentSnapshot.rows,
          eventSnapshot.rows
        );

        if (queueConfig) {
          const reviews = reviewsForStudentFromEvents(
            effectiveAssignmentRows,
            eventSnapshot.rows,
            data.course_id,
            data.student_id
          );
          const plan = planActiveQueueFromSnapshots(
            effectiveAssignmentRows,
            bank,
            reviews,
            data,
            queueConfig,
            new Date(),
            {
              retired_assignment: assignmentRecord.assignment,
              first_attempt_correct: review.first_attempt_correct
            }
          );
          const createdAssignments = appendActiveAssignments(
            assignmentsSheet,
            plan.selected,
            data,
            new Date().toISOString(),
            assignmentSnapshot
          );
          activeAssignments = sortAssignmentsOldestFirst(
            plan.active.concat(createdAssignments)
          );
          if (activeAssignments.length !== queueConfig.queue_size) {
            throw new Error(
              'Active queue did not reach the requested size after assignment creation.'
            );
          }
          timer.created_count = createdAssignments.length;
          markServiceTimer(timer, 'queue_refilled');
        } else {
          activeAssignments = activeAssignmentsFromRows(
            effectiveAssignmentRows,
            data.course_id,
            data.student_id
          );
          markServiceTimer(timer, 'active_queue_loaded');
        }
      }

      // Incorrect answers intentionally do not reload/return the unchanged
      // queue. The R client does not apply it, and keeping the stale question in
      // a duplicate browser tab is the current intended behavior.
      if (activeAssignments !== null) {
        timer.assignment_count = activeAssignments.length;
      }
    }

    timer.result = duplicate ? 'duplicate' : 'written';
    const response = {
      ok: true,
      request_id: data.request_id,
      duplicate: duplicate
    };
    if (activeAssignments !== null) response.assignments = activeAssignments;
    attachBankReconciliation(response, bankReconciliation);
    markServiceTimer(timer, 'critical_section_done');
    timer.lock_hold_ms = Date.now() - timer.lock_acquired_at_ms;
    markServiceTimer(timer, 'response_ready');
    if (includeServiceTiming(data)) {
      response.service_timing = serviceTimerSnapshot(timer);
    }
    return jsonResponse(response);
  } finally {
    if (
      typeof timer.lock_acquired_at_ms !== 'undefined' &&
      typeof timer.lock_hold_ms === 'undefined'
    ) {
      timer.lock_hold_ms = Date.now() - timer.lock_acquired_at_ms;
    }
    lock.releaseLock();
    logServiceTimer(timer);
  }
}

/**
 * Confirms that a retried request_id refers to the same logical event identity
 * before treating the POST as an idempotent duplicate.
 *
 * Called twice by handleLogEvent(), before and after lock reconciliation.
 * Depends on clean().
 *
 * @param {Array<*>} existingRow Existing event-sheet row.
 * @param {Object} data Incoming event payload.
 * @return {void}
 */
function validateDuplicateEventMatches(existingRow, data) {
  const checks = [
    [existingRow[4], clean(data.course_id, 200), 'course_id'],
    [existingRow[7], clean(data.student_id, 200), 'student_id'],
    [existingRow[9], clean(data.event, 100), 'event'],
    [existingRow[21], clean(data.assignment_id, 300), 'assignment_id']
  ];

  checks.forEach(function(check) {
    if (String(check[0] || '') !== String(check[1] || '')) {
      throw new Error('request_id was reused with a different ' + check[2] + '.');
    }
  });
}

/**
 * Returns the student's current active assignment queue without creating new
 * assignments, optionally attaching content reconciliation/progress data.
 *
 * Called by doPost(). Depends on validateAssignmentRequest(), timing helpers,
 * getActiveAssignmentsForStudent(), jsonResponse(), and reconciliation helpers
 * from BankReconciliation.gs.
 *
 * @param {Object} data Parsed assignment lookup request.
 * @param {GoogleAppsScript.Spreadsheet.Spreadsheet} ss Grading spreadsheet.
 * @return {GoogleAppsScript.Content.TextOutput} JSON active-queue response.
 */
function handleGetActiveAssignments(data, ss) {
  validateAssignmentRequest(data);
  const timer = startServiceTimer('get_active_assignments', data.request_id);

  const assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  if (!assignmentsSheet) throw new Error('The assignments sheet does not exist.');

  let bankReconciliation = null;
  if (requestUsesBankReconciliation(data)) {
    const questionBankSheet = ss.getSheetByName(QUESTION_BANK_SHEET);
    if (!questionBankSheet) {
      throw new Error(
        'The question_bank sheet does not exist. Run setupGradeSheet() after updating Code.gs.'
      );
    }
    bankReconciliation = bankReconciliationForRequest(data, questionBankSheet);
    if (!bankReconciliation.compatible) {
      return jsonResponse(bankReconciliation.response);
    }
  }
  markServiceTimer(timer, 'sheets_ready');

  const assignments = getActiveAssignmentsForStudent(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );
  markServiceTimer(timer, 'active_queue_loaded');

  timer.result = 'existing';
  timer.assignment_count = assignments.length;
  const response = {
    ok: true,
    request_id: data.request_id,
    assignments: assignments
  };
  attachBankReconciliation(response, bankReconciliation);
  markServiceTimer(timer, 'response_ready');
  if (includeServiceTiming(data)) {
    response.service_timing = serviceTimerSnapshot(timer);
  }
  logServiceTimer(timer);
  return jsonResponse(response);
}

/**
 * Ensures a student has a full curriculum-aware active queue, reconciling
 * discontinued content and creating only the assignments needed to fill gaps.
 *
 * Called by doPost(). Depends on assignment validation, snapshot, review,
 * queue-planning, timing, bank helpers in this file and reconciliation helpers
 * in BankReconciliation.gs.
 *
 * @param {Object} data Parsed get_or_create_active_assignments request.
 * @param {GoogleAppsScript.Spreadsheet.Spreadsheet} ss Grading spreadsheet.
 * @return {GoogleAppsScript.Content.TextOutput} JSON queue response including
 * any created/retired assignments.
 */
function handleGetOrCreateActiveAssignments(data, ss) {
  validateAssignmentRequest(data);
  const queueConfig = validateQueueSelectionConfig(data);

  const timer = startServiceTimer(
    'get_or_create_active_assignments',
    data.request_id
  );

  const assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  const questionBankSheet = ss.getSheetByName(QUESTION_BANK_SHEET);
  const reviewsSheet = ss.getSheetByName(REVIEW_SHEET);
  const eventsSheet = ss.getSheetByName(EVENT_SHEET);
  if (!assignmentsSheet || !questionBankSheet || !reviewsSheet || !eventsSheet) {
    throw new Error(
      'assignments, question_bank, reviews, and events must exist. Run setupGradeSheet() after updating Code.gs.'
    );
  }

  let bankReconciliation = null;
  let bank = null;
  if (requestUsesBankReconciliation(data)) {
    bankReconciliation = bankReconciliationForRequest(data, questionBankSheet);
    if (!bankReconciliation.compatible) {
      return jsonResponse(bankReconciliation.response);
    }
    bank = getQuestionBank(questionBankSheet);
  }
  markServiceTimer(timer, 'sheets_ready');

  const assignmentSnapshot = readSheetSnapshot(
    assignmentsSheet,
    ASSIGNMENT_HEADERS.length
  );
  const existing = activeAssignmentsFromRows(
    assignmentSnapshot.rows,
    data.course_id,
    data.student_id
  );
  const preflightDiscontinued = bankReconciliation
    ? discontinuedActiveAssignments(existing, bank, queueConfig.topic_priority)
    : [];
  const currentExistingCount = existing.length - preflightDiscontinued.length;

  if (currentExistingCount > queueConfig.queue_size) {
    throw new Error(
      'Student has ' + currentExistingCount +
      ' current active questions, exceeding queue_size ' +
      queueConfig.queue_size + '. No assignments were changed.'
    );
  }

  // Legacy clients retain the original fast path. Version-aware clients use
  // the same path when their full queue contains no discontinued assignments.
  if (
    currentExistingCount === queueConfig.queue_size &&
    preflightDiscontinued.length === 0
  ) {
    timer.result = 'existing';
    timer.assignment_count = existing.length;
    timer.created_count = 0;
    const response = {
      ok: true,
      request_id: data.request_id,
      created: false,
      created_count: 0,
      assignments: existing
    };
    attachBankReconciliation(response, bankReconciliation);
    markServiceTimer(timer, 'response_ready');
    if (includeServiceTiming(data)) {
      response.service_timing = serviceTimerSnapshot(timer);
    }
    logServiceTimer(timer);
    return jsonResponse(response);
  }

  const eventSnapshot = readSheetSnapshot(eventsSheet, EVENT_HEADERS.length);
  if (!bank) bank = getQuestionBank(questionBankSheet);
  markServiceTimer(timer, 'snapshots_ready');

  const lock = LockService.getScriptLock();
  timer.lock_requested_at_ms = Date.now();
  lock.waitLock(10000);
  timer.lock_acquired_at_ms = Date.now();
  timer.lock_wait_ms = timer.lock_acquired_at_ms - timer.lock_requested_at_ms;
  markServiceTimer(timer, 'lock_acquired');

  try {
    extendSheetSnapshot(eventsSheet, eventSnapshot, EVENT_HEADERS.length);
    extendSheetSnapshot(
      assignmentsSheet,
      assignmentSnapshot,
      ASSIGNMENT_HEADERS.length
    );
    markServiceTimer(timer, 'snapshots_reconciled');

    const effectiveAssignmentRows = applyCorrectEventRetirementsToAssignmentRows(
      assignmentSnapshot.rows,
      eventSnapshot.rows
    );
    const discontinued = bankReconciliation
      ? retireDiscontinuedAssignmentsFromSnapshot(
          assignmentsSheet,
          effectiveAssignmentRows,
          bank,
          data,
          queueConfig,
          new Date().toISOString()
        )
      : [];
    if (discontinued.length) {
      markServiceTimer(timer, 'discontinued_retired');
    }

    const reviews = reviewsForStudentFromEvents(
      effectiveAssignmentRows,
      eventSnapshot.rows,
      data.course_id,
      data.student_id
    );
    const plan = planActiveQueueFromSnapshots(
      effectiveAssignmentRows,
      bank,
      reviews,
      data,
      queueConfig,
      new Date(),
      null
    );
    const createdAssignments = appendActiveAssignments(
      assignmentsSheet,
      plan.selected,
      data,
      new Date().toISOString(),
      assignmentSnapshot
    );
    const assignments = sortAssignmentsOldestFirst(
      plan.active.concat(createdAssignments)
    );
    if (assignments.length !== queueConfig.queue_size) {
      throw new Error('Active queue did not reach the requested size after assignment creation.');
    }
    markServiceTimer(timer, 'queue_ensured');

    timer.result = discontinued.length
      ? 'reconciled'
      : (createdAssignments.length ? 'filled' : 'existing');
    timer.assignment_count = assignments.length;
    timer.created_count = createdAssignments.length;
    const response = {
      ok: true,
      request_id: data.request_id,
      created: createdAssignments.length > 0,
      created_count: createdAssignments.length,
      assignments: assignments
    };
    if (discontinued.length) response.retired_assignments = discontinued;
    attachBankReconciliation(response, bankReconciliation);
    markServiceTimer(timer, 'critical_section_done');
    timer.lock_hold_ms = Date.now() - timer.lock_acquired_at_ms;
    markServiceTimer(timer, 'response_ready');
    if (includeServiceTiming(data)) {
      response.service_timing = serviceTimerSnapshot(timer);
    }
    return jsonResponse(response);
  } finally {
    if (
      typeof timer.lock_acquired_at_ms !== 'undefined' &&
      typeof timer.lock_hold_ms === 'undefined'
    ) {
      timer.lock_hold_ms = Date.now() - timer.lock_acquired_at_ms;
    }
    lock.releaseLock();
    logServiceTimer(timer);
  }
}

// Rolling queue planning and persistence -------------------------------------

/**
 * Loads current assignment/bank/review state and fills a student's active queue
 * to the requested size using the shared queue planner.
 *
 * No current production caller; retained helper is not used by the active
 * request handlers, which call planActiveQueueFromSnapshots() directly. Depends
 * on getAssignmentRows(), getQuestionBank(), getReviewsForStudent(),
 * planActiveQueueFromSnapshots(), appendActiveAssignments(), and
 * sortAssignmentsOldestFirst().
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} assignmentsSheet Assignments sheet.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} questionBankSheet Question bank.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} reviewsSheet Reviews sheet.
 * @param {Object} data Request identity fields.
 * @param {Object} queueConfig Validated queue configuration.
 * @param {Date} asOf Scheduling evaluation time.
 * @param {?Object} replacementContext Optional just-retired assignment context.
 * @return {Object} Full assignments array and created_count.
 */
function ensureActiveQueue(
  assignmentsSheet,
  questionBankSheet,
  reviewsSheet,
  data,
  queueConfig,
  asOf,
  replacementContext
) {
  const assignmentRows = getAssignmentRows(assignmentsSheet);
  const bank = getQuestionBank(questionBankSheet);
  const reviews = getReviewsForStudent(
    reviewsSheet,
    data.course_id,
    data.student_id
  );
  const plan = planActiveQueueFromSnapshots(
    assignmentRows,
    bank,
    reviews,
    data,
    queueConfig,
    asOf,
    replacementContext
  );
  const createdAssignments = appendActiveAssignments(
    assignmentsSheet,
    plan.selected,
    data,
    new Date().toISOString()
  );
  const active = sortAssignmentsOldestFirst(
    plan.active.concat(createdAssignments)
  );
  if (active.length !== queueConfig.queue_size) {
    throw new Error('Active queue did not reach the requested size after assignment creation.');
  }
  return { assignments: active, created_count: createdAssignments.length };
}

/**
 * Computes which distinct canonical questions should fill vacancies in a
 * student's active queue while enforcing starter, retry, FSRS, and curriculum
 * frontier rules.
 *
 * Called by handleLogEvent(), handleGetOrCreateActiveAssignments(), the unused
 * ensureActiveQueue() wrapper, and concurrency tests. Depends on active/history,
 * curriculum-routing, and least-used-question helpers.
 *
 * @param {Array<Array<*>>} assignmentRows Assignment snapshot rows.
 * @param {Object[]} bank Canonical scored-question metadata.
 * @param {Object[]} reviews Student compact review history.
 * @param {Object} data Request identity fields.
 * @param {Object} queueConfig Validated queue configuration.
 * @param {Date} asOf Scheduling evaluation time.
 * @param {?Object} replacementContext Optional just-retired assignment context.
 * @return {Object} Existing active assignments plus selected replacement specs.
 */
function planActiveQueueFromSnapshots(
  assignmentRows,
  bank,
  reviews,
  data,
  queueConfig,
  asOf,
  replacementContext
) {
  const active = activeAssignmentsFromRows(
    assignmentRows,
    data.course_id,
    data.student_id
  );

  if (active.length > queueConfig.queue_size) {
    throw new Error(
      'Student has ' + active.length + ' active questions, exceeding queue_size ' +
      queueConfig.queue_size + '. No assignments were changed.'
    );
  }
  if (active.length === queueConfig.queue_size) {
    return { active: active, selected: [] };
  }

  validateCurriculumAgainstBank(bank, queueConfig.topic_priority);

  const curriculum = new Set(queueConfig.topic_priority);
  const eligible = bank.filter(function(item) {
    return (
      item.event === 'exercise_result' &&
      item.points > 0 &&
      curriculum.has(item.topic)
    );
  });

  const history = assignmentsForStudentHistoryFromRows(
    assignmentRows,
    data.course_id,
    data.student_id
  );
  validateHistoryAgainstCurriculum(history, queueConfig.topic_priority);

  const activeLabels = new Set(active.map(function(item) { return item.item_label; }));
  let candidates = eligible.filter(function(item) {
    return !activeLabels.has(item.item_label);
  });
  const needed = queueConfig.queue_size - active.length;

  const selected = [];
  const workingHistory = history.slice();

  if (!history.length) {
    const firstTopic = queueConfig.topic_priority[0];
    const firstTopicCandidates = candidates.filter(function(item) {
      return item.topic === firstTopic;
    });
    if (firstTopicCandidates.length < needed) {
      throw new Error(
        'The first curriculum topic, ' + firstTopic + ', has only ' +
        firstTopicCandidates.length + ' distinct available question(s), but ' +
        needed + ' are needed to fill the initial queue.'
      );
    }

    const starters = firstTopicCandidates.filter(function(item) {
      return item.starter_question;
    });
    if (!starters.length) {
      throw new Error(
        'The first curriculum topic has no starter questions. Mark at least one ' +
        'scored exercise in ' + firstTopic + ' as starter_question and sync question_bank.'
      );
    }
    if (starters.length > queueConfig.queue_size) {
      throw new Error(
        'There are ' + starters.length + ' starter questions in the first curriculum topic ' +
        'but queue_size is only ' + queueConfig.queue_size + '.'
      );
    }

    starters.slice(0, needed).forEach(function(item) {
      selected.push({ item: item, reason: 'starter' });
      workingHistory.push({ item_label: item.item_label, topic: item.topic });
    });

    const selectedLabels = new Set(selected.map(function(x) { return x.item.item_label; }));
    candidates = candidates.filter(function(item) {
      return !selectedLabels.has(item.item_label);
    });

    while (selected.length < needed) {
      const item = selectLeastUsedQuestion(
        candidates,
        workingHistory,
        firstTopic
      );
      if (!item) {
        throw new Error('Not enough first-topic questions to complete the initial queue.');
      }
      selected.push({ item: item, reason: 'initial_fill' });
      workingHistory.push({ item_label: item.item_label, topic: item.topic });
      candidates = candidates.filter(function(candidate) {
        return candidate.item_label !== item.item_label;
      });
    }
  } else {
    while (selected.length < needed) {
      let route;
      if (
        selected.length === 0 &&
        replacementContext &&
        replacementContext.first_attempt_correct === false
      ) {
        route = {
          topic: replacementContext.retired_assignment.topic,
          reason: 'same_topic_retry'
        };
      } else {
        const availableTopics = new Set(candidates.map(function(item) {
          return item.topic;
        }));
        route = chooseCurriculumReplacementTopic(
          workingHistory,
          reviews,
          queueConfig.topic_priority,
          availableTopics,
          asOf
        );
      }

      const item = selectLeastUsedQuestion(
        candidates,
        workingHistory,
        route.topic
      );
      if (!item) {
        throw new Error(
          'No distinct replacement question is available in selected topic ' + route.topic + '.'
        );
      }

      selected.push({ item: item, reason: route.reason });
      workingHistory.push({ item_label: item.item_label, topic: item.topic });
      candidates = candidates.filter(function(candidate) {
        return candidate.item_label !== item.item_label;
      });
    }
  }

  if (selected.length !== needed) {
    throw new Error(
      'Queue selection produced ' + selected.length + ' replacement(s); expected ' + needed + '.'
    );
  }

  return { active: active, selected: selected };
}

/**
 * Verifies that every configured curriculum topic has at least one scored
 * exercise in the current question bank.
 *
 * Called only by planActiveQueueFromSnapshots().
 *
 * @param {Object[]} bank Canonical question metadata.
 * @param {string[]} topicPriority Ordered curriculum topics.
 * @return {void}
 */
function validateCurriculumAgainstBank(bank, topicPriority) {
  const scoredTopics = new Set(
    bank
      .filter(function(item) {
        return item.event === 'exercise_result' && item.points > 0;
      })
      .map(function(item) { return item.topic; })
  );

  const missing = topicPriority.filter(function(topic) {
    return !scoredTopics.has(topic);
  });
  if (missing.length) {
    throw new Error(
      'Curriculum topic(s) contain no scored exercise questions: ' + missing.join(', ') + '.'
    );
  }
}

/**
 * Accepts historical assignments from topics no longer in the current
 * curriculum so old exposures remain valid scheduling evidence.
 *
 * Called by planActiveQueueFromSnapshots(), curriculumStateFromHistory(), and
 * bank-reconciliation tests. It currently has no within-repo helper dependencies.
 *
 * @param {Object[]} history Historical assignment objects.
 * @param {string[]} topicPriority Current ordered curriculum topics.
 * @return {boolean} Always true under the current compatibility policy.
 */
function validateHistoryAgainstCurriculum(history, topicPriority) {
  // Historical assignments remain valid evidence even after a topic is removed
  // from the current curriculum. Current routing simply ignores topics that are
  // no longer present in topicPriority.
  return true;
}

/**
 * Derives the set of introduced current topics and the most advanced curriculum
 * frontier reached by a student's assignment history.
 *
 * Called by chooseCurriculumReplacementTopic() and FSRS tests. Depends on
 * validateHistoryAgainstCurriculum().
 *
 * @param {Object[]} history Historical assignment objects.
 * @param {string[]} topicPriority Ordered curriculum topics.
 * @return {Object} Introduced topics, frontier topic, and frontier index.
 */
function curriculumStateFromHistory(history, topicPriority) {
  validateHistoryAgainstCurriculum(history, topicPriority);

  const introduced = new Set();
  history.forEach(function(assignment) {
    if (topicPriority.includes(assignment.topic)) introduced.add(assignment.topic);
  });

  if (!introduced.size) {
    return {
      introduced_topics: [],
      frontier_topic: topicPriority[0],
      frontier_index: 0
    };
  }

  let frontierIndex = 0;
  topicPriority.forEach(function(topic, index) {
    if (introduced.has(topic) && index > frontierIndex) frontierIndex = index;
  });

  return {
    introduced_topics: topicPriority.filter(function(topic) {
      return introduced.has(topic);
    }),
    frontier_topic: topicPriority[frontierIndex],
    frontier_index: frontierIndex
  };
}

/**
 * Chooses the topic for a replacement question, prioritizing FSRS-due topics,
 * then curriculum advancement after mastery, then frontier/introduced practice.
 *
 * Called by planActiveQueueFromSnapshots() and FSRS tests. Depends on
 * curriculumStateFromHistory(), topicRetrievabilitiesFromReviews(), and
 * topicMasterySummary().
 *
 * @param {Object[]} history Historical assignment objects.
 * @param {Object[]} reviews Compact student reviews.
 * @param {string[]} topicPriority Ordered curriculum topics.
 * @param {Set<string>} availableTopics Topics with a distinct candidate question.
 * @param {Date} asOf Scheduling evaluation time.
 * @return {Object} Selected topic, reason, and sometimes retrievability.
 */
function chooseCurriculumReplacementTopic(
  history,
  reviews,
  topicPriority,
  availableTopics,
  asOf
) {
  const state = curriculumStateFromHistory(history, topicPriority);
  const introduced = state.introduced_topics;

  if (!introduced.length) {
    return { topic: topicPriority[0], reason: 'frontier_practice' };
  }

  const retrievabilities = topicRetrievabilitiesFromReviews(
    reviews,
    introduced,
    asOf
  );

  const priorityIndex = {};
  topicPriority.forEach(function(topic, index) {
    priorityIndex[topic] = index;
  });

  const due = introduced
    .filter(function(topic) {
      return (
        availableTopics.has(topic) &&
        retrievabilities[topic] < FSRS_DUE_RETRIEVABILITY
      );
    })
    .sort(function(aa, bb) {
      if (retrievabilities[aa] !== retrievabilities[bb]) {
        return retrievabilities[aa] - retrievabilities[bb];
      }
      return priorityIndex[aa] - priorityIndex[bb];
    });

  if (due.length) {
    return {
      topic: due[0],
      reason: 'fsrs_due',
      retrievability: retrievabilities[due[0]]
    };
  }

  const frontierMastery = topicMasterySummary(
    reviews,
    state.frontier_topic
  );
  const nextIndex = state.frontier_index + 1;

  if (
    frontierMastery.mastered &&
    nextIndex < topicPriority.length &&
    availableTopics.has(topicPriority[nextIndex])
  ) {
    return {
      topic: topicPriority[nextIndex],
      reason: 'curriculum_advance'
    };
  }

  if (availableTopics.has(state.frontier_topic)) {
    return {
      topic: state.frontier_topic,
      reason: 'frontier_practice'
    };
  }

  const introducedAvailable = introduced
    .filter(function(topic) { return availableTopics.has(topic); })
    .sort(function(aa, bb) {
      if (retrievabilities[aa] !== retrievabilities[bb]) {
        return retrievabilities[aa] - retrievabilities[bb];
      }
      return priorityIndex[bb] - priorityIndex[aa];
    });

  if (introducedAvailable.length) {
    return {
      topic: introducedAvailable[0],
      reason: 'introduced_practice'
    };
  }

  if (frontierMastery.mastered && nextIndex < topicPriority.length) {
    throw new Error(
      'The next curriculum topic, ' + topicPriority[nextIndex] +
      ', has no distinct question available for this queue.'
    );
  }

  throw new Error(
    'No distinct question is available without advancing past the unmastered curriculum frontier.'
  );
}

/**
 * Selects the least-exposed candidate question within one topic, breaking ties
 * randomly so repeated literal probes are minimized without deterministic bias.
 *
 * Called by planActiveQueueFromSnapshots() and FSRS tests.
 *
 * @param {Object[]} eligible Candidate question objects.
 * @param {Object[]} history Historical/current assignment objects.
 * @param {string} topic Topic to select within.
 * @param {Function=} randomFn Optional random-number function for deterministic tests.
 * @return {?Object} Selected question object, or null when none is available.
 */
function selectLeastUsedQuestion(eligible, history, topic, randomFn) {
  const exposureCounts = {};
  history.forEach(function(assignment) {
    const label = String(assignment.item_label);
    exposureCounts[label] = (exposureCounts[label] || 0) + 1;
  });

  const random = randomFn || Math.random;
  const ranked = eligible
    .filter(function(item) { return item.topic === topic; })
    .map(function(item) {
      return {
        item: item,
        exposure_count: exposureCounts[item.item_label] || 0,
        random_key: random()
      };
    })
    .sort(function(aa, bb) {
      if (aa.exposure_count !== bb.exposure_count) {
        return aa.exposure_count - bb.exposure_count;
      }
      return aa.random_key - bb.random_key;
    });

  return ranked.length ? ranked[0].item : null;
}

/**
 * Persists selected canonical questions as new active assignment exposures and
 * optionally extends the caller's in-memory assignment snapshot.
 *
 * Called by handleLogEvent(), handleGetOrCreateActiveAssignments(), and the
 * unused ensureActiveQueue(). Depends on clean() and assignmentRowToObject().
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} assignmentsSheet Assignments sheet.
 * @param {Object[]} selected Selection objects with item and reason.
 * @param {Object} data Request identity fields.
 * @param {string} assignedAt ISO assignment timestamp.
 * @param {Object=} assignmentSnapshot Optional mutable assignment snapshot.
 * @return {Object[]} Newly created assignment objects.
 */
function appendActiveAssignments(
  assignmentsSheet,
  selected,
  data,
  assignedAt,
  assignmentSnapshot
) {
  if (!selected.length) return [];

  const rows = selected.map(function(selection) {
    const canonical = selection.item;
    return [
      Utilities.getUuid(),
      clean(data.course_id, 200),
      '',
      clean(data.student_id, 200),
      clean(canonical.item_label, 300),
      clean(canonical.topic, 300),
      canonical.points,
      '',
      assignedAt,
      selection.reason,
      ASSIGNMENT_STATUS_ACTIVE,
      '',
      '',
      ''
    ];
  });

  const firstRow = assignmentSnapshot
    ? Math.max(2, assignmentSnapshot.last_row + 1)
    : assignmentsSheet.getLastRow() + 1;
  assignmentsSheet
    .getRange(
      firstRow,
      1,
      rows.length,
      ASSIGNMENT_HEADERS.length
    )
    .setValues(rows);

  if (assignmentSnapshot) {
    assignmentSnapshot.rows = assignmentSnapshot.rows.concat(rows);
    assignmentSnapshot.last_row = firstRow + rows.length - 1;
  }

  return rows.map(assignmentRowToObject);
}

/**
 * Retires one assignment row only if it is currently active, making the write
 * idempotent when the row was already retired.
 *
 * No current production or test caller was found in this repository. It has no
 * within-repo function dependencies beyond assignment-status constants.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} assignmentsSheet Assignments sheet.
 * @param {number} rowIndex One-based physical sheet row.
 * @param {string} requestId Request causing retirement.
 * @param {string} retiredAt ISO retirement timestamp.
 * @param {string} retiredReason Retirement reason.
 * @return {boolean} True when this call retired the row; false if already retired.
 */
function retireAssignmentIfActive(
  assignmentsSheet,
  rowIndex,
  requestId,
  retiredAt,
  retiredReason
) {
  const row = assignmentsSheet
    .getRange(rowIndex, 1, 1, ASSIGNMENT_HEADERS.length)
    .getValues()[0];
  const status = String(row[10] || '');

  if (status === ASSIGNMENT_STATUS_RETIRED) return false;
  if (status !== ASSIGNMENT_STATUS_ACTIVE) {
    throw new Error(
      'Assignment has no rolling status. Run setupGradeSheet() before using the rolling queue.'
    );
  }

  assignmentsSheet.getRange(rowIndex, 11, 1, 4).setValues([[
    ASSIGNMENT_STATUS_RETIRED,
    retiredAt,
    retiredReason || 'correct',
    requestId
  ]]);
  return true;
}

// Compact reviews and mastery -------------------------------------------------

/**
 * Replays each topic's first-attempt review sequence through FSRS and returns
 * current retrievability for every requested topic.
 *
 * Called by chooseCurriculumReplacementTopic(), studentProgressSummary() in
 * Progress.gs, and FSRS tests. Depends on fsrsReviewMemoryState() and
 * fsrsCurrentRetrievability().
 *
 * @param {Object[]} reviews Compact review objects.
 * @param {string[]} topics Topics to evaluate.
 * @param {Date} asOf Time at which recall is estimated.
 * @return {Object<string, number>} Retrievability keyed by topic.
 */
function topicRetrievabilitiesFromReviews(reviews, topics, asOf) {
  const reviewsByTopic = {};

  reviews.forEach(function(review) {
    if (!reviewsByTopic[review.topic]) reviewsByTopic[review.topic] = [];
    reviewsByTopic[review.topic].push(review);
  });

  const output = {};
  topics.forEach(function(topic) {
    let state = null;
    const topicReviews = reviewsByTopic[topic] || [];

    topicReviews
      .slice()
      .sort(function(aa, bb) {
        return aa.first_attempt_at.getTime() - bb.first_attempt_at.getTime();
      })
      .forEach(function(review) {
        state = fsrsReviewMemoryState(
          state,
          review.first_attempt_correct ? FSRS_RATING_GOOD : FSRS_RATING_AGAIN,
          review.first_attempt_at
        );
      });

    output[topic] = fsrsCurrentRetrievability(state, asOf);
  });

  return output;
}

/**
 * Summarizes first-attempt mastery for one topic over a recent moving window.
 *
 * Called by chooseCurriculumReplacementTopic(), studentProgressSummary() in
 * Progress.gs, and FSRS tests.
 *
 * @param {Object[]} reviews Compact review objects.
 * @param {string} topic Topic to summarize.
 * @param {number=} windowSize Number of recent observations; defaults to 10.
 * @param {number=} masteryThreshold Required recent accuracy; defaults to 0.9.
 * @return {Object} Observation counts, recent accuracy, and mastered flag.
 */
function topicMasterySummary(
  reviews,
  topic,
  windowSize,
  masteryThreshold
) {
  const size = typeof windowSize === 'undefined' ? 10 : Number(windowSize);
  const threshold = typeof masteryThreshold === 'undefined'
    ? 0.9
    : Number(masteryThreshold);

  if (!Number.isInteger(size) || size < 1) {
    throw new Error('Mastery window size must be a positive integer.');
  }
  if (!Number.isFinite(threshold) || threshold < 0 || threshold > 1) {
    throw new Error('Mastery threshold must be between 0 and 1.');
  }

  const topicReviews = reviews
    .filter(function(review) { return review.topic === topic; })
    .slice()
    .sort(function(aa, bb) {
      return aa.first_attempt_at.getTime() - bb.first_attempt_at.getTime();
    });
  const recent = topicReviews.slice(Math.max(0, topicReviews.length - size));
  const correct = recent.filter(function(review) {
    return review.first_attempt_correct;
  }).length;
  const accuracy = recent.length ? correct / recent.length : null;

  return {
    topic: topic,
    observations: topicReviews.length,
    recent_count: recent.length,
    recent_correct: correct,
    recent_accuracy: accuracy,
    mastered: (
      topicReviews.length >= size &&
      recent.length === size &&
      accuracy >= threshold
    )
  };
}

/**
 * Compacts graded event history into one review row per attempted persisted
 * assignment, preserving first-attempt outcome and total/last attempt metadata.
 *
 * Called by rebuildReviewHistoryForSpreadsheet(), compactReviewRowForAssignment(),
 * reviewsForStudentFromEvents(), refreshReviewForAssignment(), and JS tests.
 * Depends on assignmentRowToObject(), eventCorrectBoolean(), and
 * reviewObjectToRow().
 *
 * @param {Array<Array<*>>} assignmentRows Assignment-sheet rows.
 * @param {Array<Array<*>>} eventRows Event-sheet rows.
 * @return {Array<Array<*>>} Compact review rows sorted by first attempt.
 */
function compactReviewRowsFromEvents(assignmentRows, eventRows) {
  const assignmentsById = {};
  assignmentRows.forEach(function(row) {
    const assignment = assignmentRowToObject(row);
    const assignmentId = String(assignment.assignment_id || '');
    if (assignmentId) assignmentsById[assignmentId] = assignment;
  });

  const byAssignment = {};

  eventRows.forEach(function(row) {
    if (!GRADED_EVENTS.includes(String(row[9] || ''))) return;

    const assignmentId = String(row[21] || '');
    const assignment = assignmentsById[assignmentId];
    if (!assignment) return;
    if (String(row[4] || '') !== String(assignment.course_id || '')) return;
    if (String(row[7] || '') !== String(assignment.student_id || '')) return;

    const attemptTime = new Date(row[0]);
    if (isNaN(attemptTime.getTime())) return;

    const correct = eventCorrectBoolean(row[13]);
    let review = byAssignment[assignmentId];
    if (!review) {
      review = {
        assignment: assignment,
        first_attempt_at: attemptTime,
        first_attempt_correct: correct,
        attempt_count: 0,
        last_attempt_at: attemptTime
      };
      byAssignment[assignmentId] = review;
    }

    review.attempt_count += 1;
    if (attemptTime.getTime() < review.first_attempt_at.getTime()) {
      review.first_attempt_at = attemptTime;
      review.first_attempt_correct = correct;
    }
    if (attemptTime.getTime() > review.last_attempt_at.getTime()) {
      review.last_attempt_at = attemptTime;
    }
  });

  return Object.keys(byAssignment)
    .map(function(assignmentId) {
      return reviewObjectToRow(byAssignment[assignmentId]);
    })
    .sort(function(aa, bb) {
      return new Date(aa[6]).getTime() - new Date(bb[6]).getTime();
    });
}

/**
 * Converts one in-memory compact review aggregate to REVIEW_HEADERS row order.
 *
 * Called only by compactReviewRowsFromEvents().
 *
 * @param {Object} review Review aggregate containing its assignment object.
 * @return {Array<*>} Review-sheet row.
 */
function reviewObjectToRow(review) {
  const assignment = review.assignment;
  return [
    assignment.assignment_id,
    assignment.course_id,
    assignment.week_id,
    assignment.student_id,
    assignment.item_label,
    assignment.topic,
    review.first_attempt_at.toISOString(),
    review.first_attempt_correct,
    review.attempt_count,
    review.last_attempt_at.toISOString()
  ];
}

/**
 * Reconstructs and upserts the compact review for one assignment by re-reading
 * its matching graded events.
 *
 * No current production or test caller was found. Depends on
 * getGradedEventRowsForAssignment(), assignmentObjectToRow(),
 * compactReviewRowsFromEvents(), findSheetRowByValue(), and reviewRowToObject().
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} eventsSheet Events sheet.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} reviewsSheet Reviews sheet.
 * @param {Object} assignment Persisted assignment object.
 * @return {Object} Updated compact review object.
 */
function refreshReviewForAssignment(eventsSheet, reviewsSheet, assignment) {
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

/**
 * Produces the next compact review row after one newly observed graded event,
 * preserving the earliest first-attempt result and updating attempt metadata.
 *
 * Called by updateReviewForNewEvent() and performance tests. Depends on
 * eventCorrectBoolean(), reviewRowToObject(), and validateReviewAgainstAssignment().
 *
 * @param {?Array<*>} existingRow Existing compact review row, or null.
 * @param {Object} assignment Persisted assignment object.
 * @param {string|Date} eventTime New event timestamp.
 * @param {*} correct New event correctness value.
 * @return {Array<*>} Updated review row.
 */
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

/**
 * Verifies that a compact review still describes the same persisted assignment
 * before an incremental update is applied.
 *
 * Called only by reviewRowAfterNewEvent().
 *
 * @param {Object} review Compact review object.
 * @param {Object} assignment Persisted assignment object.
 * @return {void}
 */
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

/**
 * Finds and parses one reviews-sheet row by assignment ID.
 *
 * Called by updateReviewForNewEvent() and getReviewForAssignment(); both callers
 * are currently unused by production code. Depends on findSheetRowByValue() and
 * reviewRowToObject().
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} reviewsSheet Reviews sheet.
 * @param {string} assignmentId Assignment ID to locate.
 * @return {?Object} Row index, raw row, and parsed review; null if absent.
 */
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

/**
 * Incrementally writes one new graded event into a compact review row.
 *
 * No current production or test caller was found. Depends on
 * reviewRowAfterNewEvent() and reviewRowToObject().
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} reviewsSheet Reviews sheet.
 * @param {Object} assignment Persisted assignment object.
 * @param {string|Date} eventTime Event timestamp.
 * @param {*} correct Event correctness value.
 * @param {?Object} existingRecord Existing review record, if any.
 * @return {Object} Parsed updated review.
 */
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

/**
 * Returns the parsed compact review for one assignment when it exists.
 *
 * No current production or test caller was found. Depends on
 * getReviewRecordByAssignmentId().
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} reviewsSheet Reviews sheet.
 * @param {string} assignmentId Assignment ID to locate.
 * @return {?Object} Parsed review or null.
 */
function getReviewForAssignment(reviewsSheet, assignmentId) {
  const record = getReviewRecordByAssignmentId(reviewsSheet, assignmentId);
  return record ? record.review : null;
}

/**
 * Checks whether any event row references a given assignment ID.
 *
 * No current production or test caller was found. It has no within-repo
 * function dependencies.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} eventsSheet Events sheet.
 * @param {string} assignmentId Assignment ID to search for.
 * @return {boolean} Whether a matching event exists.
 */
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

/**
 * Reads all graded event rows that belong to one persisted assignment and
 * verifies their course/student identity while filtering.
 *
 * Called only by unused refreshReviewForAssignment(); therefore it currently has
 * no active production path. It has no within-repo function dependencies.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} eventsSheet Events sheet.
 * @param {Object} assignment Persisted assignment object.
 * @return {Array<Array<*>>} Matching graded event rows.
 */
function getGradedEventRowsForAssignment(eventsSheet, assignment) {
  if (eventsSheet.getLastRow() <= 1) return [];

  const matches = eventsSheet
    .getRange(2, 22, eventsSheet.getLastRow() - 1, 1)
    .createTextFinder(String(assignment.assignment_id))
    .matchEntireCell(true)
    .findAll();

  return matches
    .map(function(cell) {
      return eventsSheet
        .getRange(cell.getRow(), 1, 1, EVENT_HEADERS.length)
        .getValues()[0];
    })
    .filter(function(row) {
      return (
        GRADED_EVENTS.includes(String(row[9] || '')) &&
        String(row[4] || '') === String(assignment.course_id || '') &&
        String(row[7] || '') === String(assignment.student_id || '')
      );
    });
}

// FSRS memory calculations ----------------------------------------------------

/**
 * Applies one Again/Good FSRS review to an optional prior topic memory state.
 *
 * Called by topicRetrievabilitiesFromReviews() and FSRS tests. Depends on the
 * FSRS helper functions below.
 *
 * @param {?Object} state Prior FSRS state, or null for the first observation.
 * @param {number} rating Supported FSRS rating (Again or Good).
 * @param {string|Date} reviewTime Review timestamp.
 * @return {Object} Updated stability, difficulty, and last_review state.
 */
function fsrsReviewMemoryState(state, rating, reviewTime) {
  if (rating !== FSRS_RATING_AGAIN && rating !== FSRS_RATING_GOOD) {
    throw new Error('This drill scheduler supports FSRS Again/Good ratings only.');
  }

  const time = new Date(reviewTime);
  if (isNaN(time.getTime())) throw new Error('Invalid FSRS review time.');

  if (!state) {
    return {
      stability: fsrsInitialStability(rating),
      difficulty: fsrsInitialDifficulty(rating),
      last_review: time
    };
  }

  const elapsedDays = fsrsElapsedDays(state.last_review, time);
  const retrievability = fsrsCurrentRetrievability(state, time);

  let stability;
  if (elapsedDays < 1) {
    stability = fsrsShortTermStability(state.stability, rating);
  } else if (rating === FSRS_RATING_AGAIN) {
    stability = fsrsNextForgetStability(
      state.difficulty,
      state.stability,
      retrievability
    );
  } else {
    stability = fsrsNextRecallStability(
      state.difficulty,
      state.stability,
      retrievability,
      rating
    );
  }

  return {
    stability: fsrsClampStability(stability),
    difficulty: fsrsNextDifficulty(state.difficulty, rating),
    last_review: time
  };
}

/**
 * Computes current FSRS retrievability from a topic memory state.
 *
 * Called by topicRetrievabilitiesFromReviews(), fsrsReviewMemoryState(), and
 * FSRS tests. Depends on fsrsElapsedDays() and FSRS constants.
 *
 * @param {?Object} state FSRS state, or null for an unseen topic.
 * @param {string|Date} asOf Time at which recall is estimated.
 * @return {number} Retrievability from 0 upward, with unseen topics returning 0.
 */
function fsrsCurrentRetrievability(state, asOf) {
  if (!state || state.stability === null || !state.last_review) return 0;

  const time = new Date(asOf);
  if (isNaN(time.getTime())) throw new Error('Invalid FSRS as-of time.');

  const elapsedDays = fsrsElapsedDays(state.last_review, time);
  return Math.pow(
    1 + FSRS_FACTOR * elapsedDays / state.stability,
    FSRS_DECAY
  );
}

/**
 * Converts two timestamps to nonnegative whole elapsed days for FSRS updates.
 *
 * Called by fsrsReviewMemoryState() and fsrsCurrentRetrievability().
 *
 * @param {string|Date} fromTime Earlier timestamp.
 * @param {string|Date} toTime Later/as-of timestamp.
 * @return {number} Nonnegative floored elapsed days.
 */
function fsrsElapsedDays(fromTime, toTime) {
  return Math.max(
    0,
    Math.floor((new Date(toTime).getTime() - new Date(fromTime).getTime()) / MILLIS_PER_DAY)
  );
}

/**
 * Returns clamped FSRS initial stability for a rating.
 * Called by fsrsReviewMemoryState(); depends on fsrsClampStability().
 * @param {number} rating FSRS rating.
 * @return {number} Initial stability.
 */
function fsrsInitialStability(rating) {
  return fsrsClampStability(FSRS_PARAMETERS[rating - 1]);
}

/**
 * Returns clamped FSRS initial difficulty for a rating.
 * Called by fsrsReviewMemoryState(); depends on fsrsClampDifficulty().
 * @param {number} rating FSRS rating.
 * @return {number} Initial difficulty.
 */
function fsrsInitialDifficulty(rating) {
  const difficulty =
    FSRS_PARAMETERS[4] -
    Math.pow(Math.E, FSRS_PARAMETERS[5] * (rating - 1)) +
    1;
  return fsrsClampDifficulty(difficulty);
}

/**
 * Computes next FSRS difficulty after a review.
 * Called by fsrsReviewMemoryState(); depends on
 * fsrsInitialDifficultyUnclamped() and fsrsClampDifficulty().
 * @param {number} difficulty Prior difficulty.
 * @param {number} rating Review rating.
 * @return {number} Next clamped difficulty.
 */
function fsrsNextDifficulty(difficulty, rating) {
  const initialEasy = fsrsInitialDifficultyUnclamped(4);
  const deltaDifficulty = -(FSRS_PARAMETERS[6] * (rating - 3));
  const dampedDelta = (10.0 - difficulty) * deltaDifficulty / 9.0;
  const next =
    FSRS_PARAMETERS[7] * initialEasy +
    (1 - FSRS_PARAMETERS[7]) * (difficulty + dampedDelta);
  return fsrsClampDifficulty(next);
}

/**
 * Computes the raw, unclamped FSRS initial difficulty for a rating.
 * Called only by fsrsNextDifficulty().
 * @param {number} rating FSRS rating.
 * @return {number} Unclamped initial difficulty.
 */
function fsrsInitialDifficultyUnclamped(rating) {
  return (
    FSRS_PARAMETERS[4] -
    Math.pow(Math.E, FSRS_PARAMETERS[5] * (rating - 1)) +
    1
  );
}

/**
 * Computes FSRS short-term stability when reviews occur less than one day apart.
 * Called by fsrsReviewMemoryState(); depends on fsrsClampStability().
 * @param {number} stability Prior stability.
 * @param {number} rating Review rating.
 * @return {number} Next short-term stability.
 */
function fsrsShortTermStability(stability, rating) {
  let increase =
    Math.pow(
      Math.E,
      FSRS_PARAMETERS[17] * (rating - 3 + FSRS_PARAMETERS[18])
    ) *
    Math.pow(stability, -FSRS_PARAMETERS[19]);

  if (rating === FSRS_RATING_GOOD) {
    increase = Math.max(increase, 1.0);
  }

  return fsrsClampStability(stability * increase);
}

/**
 * Computes next FSRS stability after a forgetting/Again observation.
 * Called only by fsrsReviewMemoryState().
 * @param {number} difficulty Current difficulty.
 * @param {number} stability Current stability.
 * @param {number} retrievability Pre-review retrievability.
 * @return {number} Next forgetting stability before caller clamping.
 */
function fsrsNextForgetStability(difficulty, stability, retrievability) {
  const longTerm =
    FSRS_PARAMETERS[11] *
    Math.pow(difficulty, -FSRS_PARAMETERS[12]) *
    (Math.pow(stability + 1, FSRS_PARAMETERS[13]) - 1) *
    Math.pow(Math.E, (1 - retrievability) * FSRS_PARAMETERS[14]);

  const shortTerm =
    stability /
    Math.pow(Math.E, FSRS_PARAMETERS[17] * FSRS_PARAMETERS[18]);

  return Math.min(longTerm, shortTerm);
}

/**
 * Computes next FSRS stability after a successful recall observation.
 * Called only by fsrsReviewMemoryState().
 * @param {number} difficulty Current difficulty.
 * @param {number} stability Current stability.
 * @param {number} retrievability Pre-review retrievability.
 * @param {number} rating Review rating.
 * @return {number} Next recall stability before caller clamping.
 */
function fsrsNextRecallStability(
  difficulty,
  stability,
  retrievability,
  rating
) {
  const hardPenalty = rating === 2 ? FSRS_PARAMETERS[15] : 1;
  const easyBonus = rating === 4 ? FSRS_PARAMETERS[16] : 1;

  return stability * (
    1 +
    Math.pow(Math.E, FSRS_PARAMETERS[8]) *
      (11 - difficulty) *
      Math.pow(stability, -FSRS_PARAMETERS[9]) *
      (Math.pow(Math.E, (1 - retrievability) * FSRS_PARAMETERS[10]) - 1) *
      hardPenalty *
      easyBonus
  );
}

/**
 * Enforces the minimum valid FSRS stability.
 * Called by fsrsInitialStability(), fsrsReviewMemoryState(), and
 * fsrsShortTermStability().
 * @param {number} stability Candidate stability.
 * @return {number} Stability at or above the configured minimum.
 */
function fsrsClampStability(stability) {
  return Math.max(stability, FSRS_STABILITY_MIN);
}

/**
 * Restricts FSRS difficulty to its supported 1–10 range.
 * Called by fsrsInitialDifficulty() and fsrsNextDifficulty().
 * @param {number} difficulty Candidate difficulty.
 * @return {number} Clamped difficulty.
 */
function fsrsClampDifficulty(difficulty) {
  return Math.min(
    Math.max(difficulty, FSRS_DIFFICULTY_MIN),
    FSRS_DIFFICULTY_MAX
  );
}

// Request and configuration validation ---------------------------------------

/**
 * Validates common and event-specific fields for a log_event request.
 * Called only by handleLogEvent(); depends on validateCommonPayload().
 * @param {Object} data Parsed request payload.
 * @return {void}
 */
function validateEventPayload(data) {
  validateCommonPayload(data);
  if (!data.session_token) throw new Error('session_token is required.');
  if (!ALLOWED_EVENTS.includes(String(data.event))) {
    throw new Error('Unsupported event type.');
  }

  if (GRADED_EVENTS.includes(String(data.event))) {
    if (!data.student_id) throw new Error('student_id is required for graded events.');
    if (!data.assignment_id) throw new Error('assignment_id is required for graded events.');
    if (!data.item_label) throw new Error('item_label is required for graded events.');
    if (!data.topic) throw new Error('topic is required for graded events.');
  }
}

/**
 * Verifies that a graded event's course/student/question/topic identity matches
 * the persisted assignment referenced by assignment_id.
 * Called only by handleLogEvent(); depends on clean().
 * @param {Object} data Parsed graded event payload.
 * @param {Object} assignment Persisted assignment object.
 * @return {void}
 */
function validateGradedEventAgainstAssignment(data, assignment) {
  const checks = [
    [assignment.course_id, clean(data.course_id, 200), 'course_id'],
    [assignment.student_id, clean(data.student_id, 200), 'student_id'],
    [assignment.item_label, clean(data.item_label, 300), 'item_label'],
    [assignment.topic, clean(data.topic, 300), 'topic']
  ];
  checks.forEach(function(check) {
    if (String(check[0] || '') !== String(check[1] || '')) {
      throw new Error(
        'Graded event does not match persisted assignment ' + assignment.assignment_id +
        ': ' + check[2] + '.'
      );
    }
  });
}

/**
 * Validates common fields plus the student ID required by assignment requests.
 * Called by both assignment request handlers; depends on validateCommonPayload().
 * @param {Object} data Parsed assignment request.
 * @return {void}
 */
function validateAssignmentRequest(data) {
  validateCommonPayload(data);

  if (!data.student_id) throw new Error('student_id is required.');
  if (!/^[A-Za-z0-9._@-]{2,100}$/.test(String(data.student_id))) {
    throw new Error('student_id has an invalid format.');
  }
}

/**
 * Validates and normalizes queue_size and ordered topic_priority scheduling
 * fields supplied by rolling-queue requests.
 * Called by handleGetOrCreateActiveAssignments(), optionalQueueSelectionConfig(),
 * and FSRS tests.
 * @param {Object} data Parsed request payload.
 * @return {Object} Normalized queue_size and topic_priority.
 */
function validateQueueSelectionConfig(data) {
  const queueSize = Number(data.queue_size);
  if (!Number.isInteger(queueSize) || queueSize < 1 || queueSize > 500) {
    throw new Error('queue_size must be an integer from 1 through 500.');
  }

  if (!Array.isArray(data.topic_priority) || !data.topic_priority.length) {
    throw new Error('topic_priority must be a non-empty ordered array.');
  }

  const topics = data.topic_priority.map(function(x) {
    return String(x).trim();
  });
  if (topics.some(function(x) { return !x || x.length > 300; })) {
    throw new Error('Each curriculum topic must be a non-empty string of at most 300 characters.');
  }
  if (new Set(topics).size !== topics.length) {
    throw new Error('topic_priority must not contain duplicates.');
  }

  return {
    queue_size: queueSize,
    topic_priority: topics
  };
}

/**
 * Returns validated queue configuration only when both optional scheduling
 * fields were supplied, rejecting partial configuration.
 * Called only by handleLogEvent(); depends on validateQueueSelectionConfig().
 * @param {Object} data Parsed event payload.
 * @return {?Object} Validated queue config, or null when neither field is present.
 */
function optionalQueueSelectionConfig(data) {
  const hasSize = typeof data.queue_size !== 'undefined';
  const hasTopics = typeof data.topic_priority !== 'undefined';
  if (!hasSize && !hasTopics) return null;
  if (!hasSize || !hasTopics) {
    throw new Error('queue_size and topic_priority must be supplied together.');
  }
  return validateQueueSelectionConfig(data);
}

// Snapshot and concurrency helpers ------------------------------------------

/**
 * Reads all data rows of a sheet once, recording the physical last row so a
 * request can later reconcile only concurrently appended rows.
 * Called by request handlers and concurrency tests.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Sheet to snapshot.
 * @param {number} width Number of columns to read.
 * @return {Object} Snapshot with last_row and rows.
 */
function readSheetSnapshot(sheet, width) {
  const lastRow = sheet.getLastRow();
  return {
    last_row: lastRow,
    rows: lastRow <= 1
      ? []
      : sheet.getRange(2, 1, lastRow - 1, width).getValues()
  };
}

/**
 * Extends an existing row snapshot with rows appended since it was read, while
 * rejecting destructive row removal during a live request.
 * Called by request handlers and concurrency tests.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Source sheet.
 * @param {Object} snapshot Mutable snapshot from readSheetSnapshot().
 * @param {number} width Number of columns to read.
 * @return {Object} The updated snapshot.
 */
function extendSheetSnapshot(sheet, snapshot, width) {
  const currentLastRow = sheet.getLastRow();
  if (currentLastRow < snapshot.last_row) {
    throw new Error('Managed sheet rows were removed during a live request. Retry the request.');
  }
  if (currentLastRow > snapshot.last_row) {
    const firstNewRow = Math.max(2, snapshot.last_row + 1);
    const count = currentLastRow - firstNewRow + 1;
    snapshot.rows = snapshot.rows.concat(
      sheet.getRange(firstNewRow, 1, count, width).getValues()
    );
  }
  snapshot.last_row = currentLastRow;
  return snapshot;
}

/**
 * Reads one data column as a compact index snapshot with its physical last row.
 * Called by handleLogEvent() and concurrency tests.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Source sheet.
 * @param {number} columnIndex One-based column index.
 * @return {Object} Snapshot with last_row and scalar values.
 */
function readColumnSnapshot(sheet, columnIndex) {
  const lastRow = sheet.getLastRow();
  return {
    last_row: lastRow,
    values: lastRow <= 1
      ? []
      : sheet.getRange(2, columnIndex, lastRow - 1, 1).getValues().map(function(row) {
          return row[0];
        })
  };
}

/**
 * Extends a column snapshot with values appended since it was read.
 * Called by handleLogEvent() and concurrency tests.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Source sheet.
 * @param {Object} snapshot Mutable column snapshot.
 * @param {number} columnIndex One-based column index.
 * @return {Object} Updated snapshot.
 */
function extendColumnSnapshot(sheet, snapshot, columnIndex) {
  const currentLastRow = sheet.getLastRow();
  if (currentLastRow < snapshot.last_row) {
    throw new Error('Managed sheet rows were removed during a live request. Retry the request.');
  }
  if (currentLastRow > snapshot.last_row) {
    const firstNewRow = Math.max(2, snapshot.last_row + 1);
    const count = currentLastRow - firstNewRow + 1;
    const values = sheet
      .getRange(firstNewRow, columnIndex, count, 1)
      .getValues()
      .map(function(row) { return row[0]; });
    snapshot.values = snapshot.values.concat(values);
  }
  snapshot.last_row = currentLastRow;
  return snapshot;
}

/**
 * Appends one row at the next unclaimed physical position and updates the
 * caller's in-memory snapshot to include the write.
 * Called by handleLogEvent() and concurrency tests.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Destination sheet.
 * @param {Object} snapshot Mutable row snapshot.
 * @param {Array<*>} row Row to append.
 * @param {number} width Number of columns to write.
 * @return {number} Physical one-based row index written.
 */
function appendRowToSnapshot(sheet, snapshot, row, width) {
  const rowIndex = Math.max(2, snapshot.last_row + 1);
  sheet.getRange(rowIndex, 1, 1, width).setValues([row]);
  snapshot.rows.push(row);
  snapshot.last_row = rowIndex;
  return rowIndex;
}

/**
 * Finds an event by request_id inside an already-read snapshot while preserving
 * its physical sheet row index.
 * Called by handleLogEvent() and concurrency tests.
 * @param {Array<Array<*>>} eventRows Event snapshot rows.
 * @param {string} requestId Request ID to locate.
 * @return {?Object} Row index and row, or null.
 */
function findEventRowByRequestIdFromRows(eventRows, requestId) {
  const key = String(requestId || '');
  for (let ii = 0; ii < eventRows.length; ii++) {
    if (String(eventRows[ii][3] || '') === key) {
      return { row_index: ii + 2, row: eventRows[ii] };
    }
  }
  return null;
}

/**
 * Finds and parses an assignment by ID inside an already-read snapshot while
 * preserving its physical sheet row index.
 * Called by handleLogEvent(), BankReconciliation.gs, getAssignmentRecordById(),
 * and concurrency tests. Depends on assignmentRowToObject().
 * @param {Array<Array<*>>} assignmentRows Assignment snapshot rows.
 * @param {string} assignmentId Assignment ID to locate.
 * @return {?Object} Row index, raw row, and assignment object; or null.
 */
function getAssignmentRecordByIdFromRows(assignmentRows, assignmentId) {
  const key = String(assignmentId || '');
  for (let ii = 0; ii < assignmentRows.length; ii++) {
    if (String(assignmentRows[ii][0] || '') === key) {
      return {
        row_index: ii + 2,
        row: assignmentRows[ii],
        assignment: assignmentRowToObject(assignmentRows[ii])
      };
    }
  }
  return null;
}

/**
 * Locates a scalar value inside a column snapshot and returns its physical row.
 * Called only by upsertReviewRowFromSnapshot().
 * @param {Object} snapshot Column snapshot.
 * @param {*} value Value to match exactly after string coercion.
 * @return {number} Physical row index, or 0 when absent.
 */
function findRowInColumnSnapshot(snapshot, value) {
  const key = String(value || '');
  for (let ii = 0; ii < snapshot.values.length; ii++) {
    if (String(snapshot.values[ii] || '') === key) return ii + 2;
  }
  return 0;
}

/**
 * Updates an existing compact review row or appends a new one while keeping the
 * assignment-ID index snapshot synchronized with the write.
 * Called only by handleLogEvent(); depends on findRowInColumnSnapshot().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} reviewsSheet Reviews sheet.
 * @param {Object} reviewIndexSnapshot Mutable assignment-ID column snapshot.
 * @param {string} assignmentId Assignment ID key.
 * @param {Array<*>} reviewRow Compact review row to write.
 * @return {number} Physical row index written.
 */
function upsertReviewRowFromSnapshot(
  reviewsSheet,
  reviewIndexSnapshot,
  assignmentId,
  reviewRow
) {
  let rowIndex = findRowInColumnSnapshot(reviewIndexSnapshot, assignmentId);
  if (rowIndex) {
    reviewsSheet
      .getRange(rowIndex, 1, 1, REVIEW_HEADERS.length)
      .setValues([reviewRow]);
    return rowIndex;
  }

  rowIndex = Math.max(2, reviewIndexSnapshot.last_row + 1);
  reviewsSheet
    .getRange(rowIndex, 1, 1, REVIEW_HEADERS.length)
    .setValues([reviewRow]);
  reviewIndexSnapshot.values.push(assignmentId);
  reviewIndexSnapshot.last_row = rowIndex;
  return rowIndex;
}

/**
 * Reconstructs exactly one compact review row for a specified assignment from
 * current assignment/event snapshots.
 * Called by handleLogEvent() and concurrency tests. Depends on
 * compactReviewRowsFromEvents().
 * @param {Array<Array<*>>} assignmentRows Assignment snapshot rows.
 * @param {Array<Array<*>>} eventRows Event snapshot rows.
 * @param {Object} assignment Assignment object identifying the exposure.
 * @return {Array<*>} Compact review row.
 */
function compactReviewRowForAssignment(assignmentRows, eventRows, assignment) {
  const compact = compactReviewRowsFromEvents(
    assignmentRows.filter(function(row) {
      return String(row[0] || '') === String(assignment.assignment_id || '');
    }),
    eventRows
  );
  if (compact.length !== 1) {
    throw new Error(
      'Expected exactly one compact review row for assignment ' +
      assignment.assignment_id + '.'
    );
  }
  return compact[0];
}

/**
 * Rebuilds compact reviews from assignment/event snapshots and filters them to
 * one student's course identity for scheduling.
 * Called by both queue-refilling handlers and concurrency tests. Depends on
 * clean(), compactReviewRowsFromEvents(), and reviewRowToObject().
 * @param {Array<Array<*>>} assignmentRows Assignment snapshot rows.
 * @param {Array<Array<*>>} eventRows Event snapshot rows.
 * @param {string} courseId Course ID.
 * @param {string} studentId Student ID.
 * @return {Object[]} Compact review objects for that student.
 */
function reviewsForStudentFromEvents(assignmentRows, eventRows, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);
  return compactReviewRowsFromEvents(assignmentRows, eventRows)
    .map(reviewRowToObject)
    .filter(function(review) {
      return review.course_id === courseKey && review.student_id === studentKey;
    });
}

/**
 * Applies correct graded events as authoritative logical retirements to a copy
 * of assignment snapshot rows, resolving stale pre-lock assignment state.
 * Called by both mutation handlers and concurrency tests. Depends on
 * eventCorrectBoolean() and assignment-status constants.
 * @param {Array<Array<*>>} assignmentRows Assignment snapshot rows.
 * @param {Array<Array<*>>} eventRows Event snapshot rows.
 * @return {Array<Array<*>>} Copied assignment rows with logical retirements applied.
 */
function applyCorrectEventRetirementsToAssignmentRows(assignmentRows, eventRows) {
  const output = assignmentRows.map(function(row) { return row.slice(); });
  const byId = {};
  output.forEach(function(row) {
    const assignmentId = String(row[0] || '');
    if (assignmentId) byId[assignmentId] = row;
  });

  eventRows.forEach(function(eventRow) {
    if (!GRADED_EVENTS.includes(String(eventRow[9] || ''))) return;
    if (!eventCorrectBoolean(eventRow[13])) return;
    const assignmentId = String(eventRow[21] || '');
    const row = byId[assignmentId];
    if (!row) return;
    if (String(eventRow[4] || '') !== String(row[1] || '')) return;
    if (String(eventRow[7] || '') !== String(row[3] || '')) return;

    row[10] = ASSIGNMENT_STATUS_RETIRED;
    if (!String(row[11] || '')) row[11] = String(eventRow[0] || '');
    if (!String(row[13] || '')) row[13] = String(eventRow[3] || '');
  });

  return output;
}

/**
 * Validates schema_version plus request/course IDs shared by all service calls.
 * Called by validateEventPayload() and validateAssignmentRequest().
 * @param {Object} data Parsed request payload.
 * @return {void}
 */
function validateCommonPayload(data) {
  if (String(data.schema_version) !== '1') {
    throw new Error('Unsupported schema_version.');
  }
  if (!data.request_id) throw new Error('request_id is required.');
  if (!data.course_id) throw new Error('course_id is required.');
}

// Sheet access and row/object conversion -------------------------------------

/**
 * Reads all assignment data rows from a managed sheet.
 * Called by setup/migration, queue, and assignment lookup helpers.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Assignments sheet.
 * @return {Array<Array<*>>} Assignment rows excluding the header.
 */
function getAssignmentRows(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return [];
  return sheet
    .getRange(2, 1, lastRow - 1, ASSIGNMENT_HEADERS.length)
    .getValues();
}

/**
 * Reads all event data rows from a managed sheet.
 * Called by review rebuild and legacy migration helpers.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Events sheet.
 * @return {Array<Array<*>>} Event rows excluding the header.
 */
function getEventRows(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return [];
  return sheet
    .getRange(2, 1, lastRow - 1, EVENT_HEADERS.length)
    .getValues();
}

/**
 * Reads all compact review data rows from a managed sheet.
 * Called only by getReviewsForStudent().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Reviews sheet.
 * @return {Array<Array<*>>} Review rows excluding the header.
 */
function getReviewRows(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return [];
  return sheet
    .getRange(2, 1, lastRow - 1, REVIEW_HEADERS.length)
    .getValues();
}

/**
 * Returns a copy of assignment objects ordered by assigned_at_utc oldest first.
 * Called by activeAssignmentsFromRows(), request handlers, ensureActiveQueue(),
 * and performance tests.
 * @param {Object[]} assignments Assignment objects.
 * @return {Object[]} Sorted copy.
 */
function sortAssignmentsOldestFirst(assignments) {
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

/**
 * Filters assignment rows to one student's active queue and returns parsed
 * assignment objects in oldest-first order.
 * Called by handlers, planners, BankReconciliation.gs, and JS tests. Depends on
 * clean(), assignmentRowToObject(), and sortAssignmentsOldestFirst().
 * @param {Array<Array<*>>} assignmentRows Assignment rows.
 * @param {string} courseId Course ID.
 * @param {string} studentId Student ID.
 * @return {Object[]} Active assignment objects.
 */
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

/**
 * Filters assignment rows to all historical exposures for one student/course.
 * Called by planActiveQueueFromSnapshots(), getAssignmentsForStudentHistory(),
 * and performance tests. Depends on clean() and assignmentRowToObject().
 * @param {Array<Array<*>>} assignmentRows Assignment rows.
 * @param {string} courseId Course ID.
 * @param {string} studentId Student ID.
 * @return {Object[]} Historical assignment objects, active and retired.
 */
function assignmentsForStudentHistoryFromRows(assignmentRows, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return assignmentRows
    .filter(function(row) {
      return row[1] === courseKey && row[3] === studentKey;
    })
    .map(assignmentRowToObject);
}

/**
 * Reads and returns one student's active assignments from the assignments sheet.
 * Called only by handleGetActiveAssignments(); depends on getAssignmentRows()
 * and activeAssignmentsFromRows().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Assignments sheet.
 * @param {string} courseId Course ID.
 * @param {string} studentId Student ID.
 * @return {Object[]} Active assignment objects.
 */
function getActiveAssignmentsForStudent(sheet, courseId, studentId) {
  return activeAssignmentsFromRows(
    getAssignmentRows(sheet),
    courseId,
    studentId
  );
}

/**
 * Reads and returns all historical assignment exposures for one student.
 * No current production or test caller was found. Depends on getAssignmentRows()
 * and assignmentsForStudentHistoryFromRows().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Assignments sheet.
 * @param {string} courseId Course ID.
 * @param {string} studentId Student ID.
 * @return {Object[]} Historical assignment objects.
 */
function getAssignmentsForStudentHistory(sheet, courseId, studentId) {
  return assignmentsForStudentHistoryFromRows(
    getAssignmentRows(sheet),
    courseId,
    studentId
  );
}

/**
 * Reads and returns compact reviews for one student/course.
 * Called by ensureActiveQueue() and progressPayloadForRequest() in Progress.gs.
 * Depends on getReviewRows(), clean(), and reviewRowToObject().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Reviews sheet.
 * @param {string} courseId Course ID.
 * @param {string} studentId Student ID.
 * @return {Object[]} Compact review objects.
 */
function getReviewsForStudent(sheet, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return getReviewRows(sheet)
    .filter(function(row) {
      return row[1] === courseKey && row[3] === studentKey;
    })
    .map(reviewRowToObject);
}

/**
 * Reads all assignments and locates one persisted assignment by ID.
 * No current production or test caller was found. Depends on getAssignmentRows()
 * and getAssignmentRecordByIdFromRows().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Assignments sheet.
 * @param {string} assignmentId Assignment ID.
 * @return {?Object} Assignment record or null.
 */
function getAssignmentRecordById(sheet, assignmentId) {
  return getAssignmentRecordByIdFromRows(getAssignmentRows(sheet), assignmentId);
}

/**
 * Converts one assignment-sheet row to the service's assignment object shape.
 * Called throughout assignment, review, and test helpers.
 * @param {Array<*>} row Assignment row in ASSIGNMENT_HEADERS order.
 * @return {Object} Parsed assignment object.
 */
function assignmentRowToObject(row) {
  return {
    assignment_id: row[0],
    course_id: row[1],
    week_id: row[2],
    student_id: row[3],
    item_label: row[4],
    topic: row[5],
    points: row[6],
    assigned_at_utc: row[8],
    assignment_reason: row[9],
    assignment_status: row[10],
    retired_at_utc: row[11],
    retired_reason: row[12],
    retired_request_id: row[13]
  };
}

/**
 * Converts an assignment object back to ASSIGNMENT_HEADERS row order.
 * Called only by unused refreshReviewForAssignment(); therefore it has no active
 * production path.
 * @param {Object} assignment Assignment object.
 * @return {Array<*>} Assignment-sheet row.
 */
function assignmentObjectToRow(assignment) {
  return [
    assignment.assignment_id,
    assignment.course_id,
    assignment.week_id,
    assignment.student_id,
    assignment.item_label,
    assignment.topic,
    assignment.points,
    '',
    assignment.assigned_at_utc,
    assignment.assignment_reason,
    assignment.assignment_status || '',
    assignment.retired_at_utc || '',
    assignment.retired_reason || '',
    assignment.retired_request_id || ''
  ];
}

/**
 * Parses and validates one reviews-sheet row into typed Date/count fields.
 * Called by live review/scheduling helpers and JavaScript tests. Depends on
 * eventCorrectBoolean().
 * @param {Array<*>} row Review row in REVIEW_HEADERS order.
 * @return {Object} Parsed compact review object.
 */
function reviewRowToObject(row) {
  const firstAttemptAt = new Date(row[6]);
  const lastAttemptAt = new Date(row[9]);
  const attemptCount = Number(row[8]);

  if (isNaN(firstAttemptAt.getTime())) {
    throw new Error('Invalid first_attempt_at_utc in reviews sheet.');
  }
  if (isNaN(lastAttemptAt.getTime())) {
    throw new Error('Invalid last_attempt_at_utc in reviews sheet.');
  }
  if (!Number.isFinite(attemptCount) || attemptCount < 1) {
    throw new Error('Invalid attempt_count in reviews sheet.');
  }

  return {
    assignment_id: row[0],
    course_id: row[1],
    week_id: row[2],
    student_id: row[3],
    item_label: row[4],
    topic: row[5],
    first_attempt_at: firstAttemptAt,
    first_attempt_correct: eventCorrectBoolean(row[7]),
    attempt_count: attemptCount,
    last_attempt_at: lastAttemptAt
  };
}

/**
 * Reads and parses the canonical question_bank sheet, rejecting an empty bank.
 * Called by assignment handlers and ensureActiveQueue(). Depends on
 * questionBankFromRows().
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Question-bank sheet.
 * @return {Object[]} Parsed canonical question metadata.
 */
function getQuestionBank(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) {
    throw new Error(
      'The question_bank sheet is empty. Run scripts/06_sync_question_bank.R first.'
    );
  }
  return questionBankFromRows(
    sheet
      .getRange(2, 1, lastRow - 1, QUESTION_BANK_HEADERS.length)
      .getValues()
  );
}

/**
 * Parses raw question-bank rows, enforcing unique item labels and valid points.
 * Called only by getQuestionBank(); depends on sheetBoolean().
 * @param {Array<Array<*>>} rows Raw question-bank rows.
 * @return {Object[]} Parsed question metadata objects.
 */
function questionBankFromRows(rows) {
  const seen = new Set();
  const bank = [];

  rows.forEach(function(row) {
    const itemLabel = String(row[0] || '');
    if (!itemLabel) return;

    if (seen.has(itemLabel)) {
      throw new Error('Duplicate item_label in question_bank: ' + itemLabel + '.');
    }
    seen.add(itemLabel);

    const points = Number(row[3]);
    if (!Number.isFinite(points) || points < 0) {
      throw new Error('Invalid points value for question_bank item ' + itemLabel + '.');
    }

    bank.push({
      item_label: itemLabel,
      event: String(row[1] || ''),
      topic: String(row[2] || ''),
      points: points,
      starter_question: sheetBoolean(row[4])
    });
  });

  return bank;
}

/**
 * Finds the physical row containing an exact value in one sheet column.
 * Called by refreshReviewForAssignment() and getReviewRecordByAssignmentId(),
 * both currently outside the active production path.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet Sheet to search.
 * @param {number} columnIndex One-based column index.
 * @param {*} value Exact value to match.
 * @return {number} Physical row index, or 0 if absent.
 */
function findSheetRowByValue(sheet, columnIndex, value) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return 0;
  const match = sheet
    .getRange(2, columnIndex, lastRow - 1, 1)
    .createTextFinder(String(value))
    .matchEntireCell(true)
    .findNext();
  return match ? match.getRow() : 0;
}

// Runtime diagnostics ---------------------------------------------------------

/**
 * Checks whether setupGradeSheet() recorded the runtime schema marker expected
 * by this deployed Code.gs version.
 * Called by doPost() and performance tests.
 * @param {Object} runtimeProperties Script properties map.
 * @return {boolean} Whether the runtime schema is current.
 */
function runtimeSchemaIsReady(runtimeProperties) {
  return Boolean(
    runtimeProperties &&
    String(runtimeProperties[RUNTIME_SCHEMA_PROPERTY] || '') === RUNTIME_SCHEMA_VERSION
  );
}

/**
 * Creates a mutable timing accumulator for one service operation.
 * Called by all three request handlers and the service timing test script.
 * @param {string} operation Operation label.
 * @param {string} requestId Request ID.
 * @return {Object} Mutable timer state.
 */
function startServiceTimer(operation, requestId) {
  return {
    operation: operation,
    request_id: String(requestId || ''),
    started_at_ms: Date.now(),
    marks: {}
  };
}

/**
 * Records elapsed milliseconds for a named stage on a service timer.
 * Called repeatedly by request handlers.
 * @param {Object} timer Mutable timer from startServiceTimer().
 * @param {string} label Stage label.
 * @return {void}
 */
function markServiceTimer(timer, label) {
  timer.marks[label] = Date.now() - timer.started_at_ms;
}

/**
 * Enables timing diagnostics only for an explicit boolean include_timing=true.
 * Called by request handlers and FSRS tests.
 * @param {Object} data Request payload.
 * @return {boolean} Whether timing should be included in the response.
 */
function includeServiceTiming(data) {
  return Boolean(data && data.include_timing === true);
}

/**
 * Copies the externally useful fields of a mutable timer into a response-safe
 * diagnostic snapshot.
 * Called by request handlers, logServiceTimer(), scripts, and JS tests.
 * @param {Object} timer Mutable timer state.
 * @return {Object} Timing diagnostic snapshot.
 */
function serviceTimerSnapshot(timer) {
  const output = {
    operation: timer.operation,
    request_id: timer.request_id,
    result: timer.result || '',
    total_ms: Date.now() - timer.started_at_ms,
    marks_ms: Object.assign({}, timer.marks)
  };
  if (typeof timer.assignment_count !== 'undefined') {
    output.assignment_count = timer.assignment_count;
  }
  if (typeof timer.review_count !== 'undefined') {
    output.review_count = timer.review_count;
  }
  if (typeof timer.created_count !== 'undefined') {
    output.created_count = timer.created_count;
  }
  if (typeof timer.lock_wait_ms !== 'undefined') {
    output.lock_wait_ms = timer.lock_wait_ms;
  }
  if (typeof timer.lock_hold_ms !== 'undefined') {
    output.lock_hold_ms = timer.lock_hold_ms;
  }
  return output;
}

/**
 * Emits one completed service timing snapshot to the Apps Script execution log.
 * Called by all request handlers; depends on serviceTimerSnapshot().
 * @param {Object} timer Mutable timer state.
 * @return {void}
 */
function logServiceTimer(timer) {
  console.log('service_timing ' + JSON.stringify(serviceTimerSnapshot(timer)));
}

// Scalar and response utilities ----------------------------------------------

/**
 * Parses a Sheet value as a strict starter-question boolean.
 * Called only by questionBankFromRows().
 * @param {*} value Sheet cell value.
 * @return {boolean} Parsed boolean.
 */
function sheetBoolean(value) {
  if (value === true || value === 1) return true;
  if (value === false || value === 0 || value === '' || value === null) return false;

  const text = String(value).trim().toLowerCase();
  if (text === 'true' || text === '1' || text === 'yes') return true;
  if (text === 'false' || text === '0' || text === 'no') return false;
  throw new Error('Invalid starter_question value in question_bank: ' + String(value));
}

/**
 * Parses a stored/request correctness value into a strict boolean.
 * Called by event/review/migration/FSRS helpers throughout this file.
 * @param {*} value Correctness value.
 * @return {boolean} Parsed boolean.
 */
function eventCorrectBoolean(value) {
  if (value === true || value === 1) return true;
  if (value === false || value === 0 || value === '' || value === null) return false;

  const text = String(value).trim().toLowerCase();
  if (text === 'true' || text === '1' || text === 'yes') return true;
  if (text === 'false' || text === '0' || text === 'no') return false;
  throw new Error('Invalid correct value: ' + String(value));
}

/**
 * Normalizes values before they are written/compared: nulls become empty,
 * strings are length-limited, and spreadsheet-formula prefixes are escaped.
 * Called throughout request, assignment, and review helpers.
 * @param {*} value Value to normalize.
 * @param {number} maxLength Maximum retained string length.
 * @return {*} Boolean/number values unchanged, otherwise a sanitized string.
 */
function clean(value, maxLength) {
  if (value === null || typeof value === 'undefined') return '';
  if (typeof value === 'boolean' || typeof value === 'number') return value;

  let text = String(value);
  if (text.length > maxLength) text = text.substring(0, maxLength);

  if (/^[=+\-@]/.test(text)) text = "'" + text;
  return text;
}

/**
 * Serializes an object as the JSON ContentService response used by all web-app
 * entry points and request handlers.
 * @param {Object} obj Response payload.
 * @return {GoogleAppsScript.Content.TextOutput} JSON text response.
 */
function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
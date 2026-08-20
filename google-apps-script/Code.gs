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
  'question_hash',
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
  'question_hash'
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

function setupGradeSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) throw new Error('Run this from a script bound to the grading spreadsheet.');

  PropertiesService.getScriptProperties().setProperty('SPREADSHEET_ID', ss.getId());

  const eventSheet = ensureManagedSheet(ss, EVENT_SHEET, EVENT_HEADERS);
  const assignmentSheet = ensureManagedSheet(ss, ASSIGNMENT_SHEET, ASSIGNMENT_HEADERS);
  ensureManagedSheet(ss, QUESTION_BANK_SHEET, QUESTION_BANK_HEADERS);
  const reviewSheet = ensureManagedSheet(ss, REVIEW_SHEET, REVIEW_HEADERS);

  // Upgrade existing workbooks without losing the history already collected.
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

  Logger.log('Grade sheet is ready: ' + ss.getId());
}

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

function ensureManagedSheet(ss, sheetName, headers) {
  let sheet = ss.getSheetByName(sheetName);
  if (!sheet) sheet = ss.insertSheet(sheetName);

  ensureSheetHeaders(sheet, headers, sheetName);

  sheet.setFrozenRows(1);
  sheet.getRange(1, 1, 1, headers.length).setFontWeight('bold');
  sheet.autoResizeColumns(1, headers.length);

  return sheet;
}

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

function doGet() {
  return jsonResponse({
    ok: true,
    service: 'learnr-grade-logger',
    schema_version: '1'
  });
}

function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      throw new Error('Missing JSON request body.');
    }

    const data = JSON.parse(e.postData.contents);
    const spreadsheetId = PropertiesService
      .getScriptProperties()
      .getProperty('SPREADSHEET_ID');
    if (!spreadsheetId) {
      throw new Error('Run setupGradeSheet() before deploying the web app.');
    }

    const ss = SpreadsheetApp.openById(spreadsheetId);
    const requestType = String(data.request_type || 'log_event');

    if (requestType === 'log_event') {
      return handleLogEvent(data, ss);
    }

    if (requestType === 'get_active_assignments' || requestType === 'get_assignments') {
      return handleGetActiveAssignments(data, ss);
    }

    if (
      requestType === 'get_or_create_active_assignments' ||
      requestType === 'get_or_create_dynamic_assignments'
    ) {
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

function handleLogEvent(data, ss) {
  validateEventPayload(data);

  const timer = startServiceTimer('log_event', data.request_id);
  const eventsSheet = ss.getSheetByName(EVENT_SHEET);
  if (!eventsSheet) throw new Error('The events sheet does not exist.');
  ensureSheetHeaders(eventsSheet, EVENT_HEADERS, EVENT_SHEET);

  const isGraded = GRADED_EVENTS.includes(String(data.event));
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
    ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);
    ensureSheetHeaders(reviewsSheet, REVIEW_HEADERS, REVIEW_SHEET);
    ensureSheetHeaders(questionBankSheet, QUESTION_BANK_HEADERS, QUESTION_BANK_SHEET);
  }

  const serverTimestamp = new Date().toISOString();
  const row = [
    serverTimestamp,
    clean(data.client_timestamp_utc, 100),
    clean(data.schema_version, 20),
    clean(data.request_id, 200),
    clean(data.course_id, 200),
    clean(data.week_id, 200),
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

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  markServiceTimer(timer, 'lock_acquired');

  try {
    let assignmentRecord = null;
    if (isGraded) {
      assignmentRecord = getAssignmentRecordById(
        assignmentsSheet,
        clean(data.assignment_id, 300)
      );
      if (!assignmentRecord) {
        throw new Error('Unknown assignment_id for graded event.');
      }
      validateGradedEventAgainstAssignment(data, assignmentRecord.assignment);
      markServiceTimer(timer, 'assignment_validated');
    }

    const existingRequestRow = findSheetRowByValue(
      eventsSheet,
      4,
      clean(data.request_id, 200)
    );
    let duplicate = Boolean(existingRequestRow);
    markServiceTimer(timer, 'idempotency_checked');

    if (existingRequestRow) {
      validateDuplicateEventMatches(
        eventsSheet.getRange(existingRequestRow, 1, 1, EVENT_HEADERS.length).getValues()[0],
        data
      );
    } else {
      eventsSheet
        .getRange(eventsSheet.getLastRow() + 1, 1, 1, EVENT_HEADERS.length)
        .setValues([row]);
      markServiceTimer(timer, 'event_written');
    }

    let activeAssignments = null;
    if (isGraded) {
      // Rebuild this one compact review row from authoritative event rows. This
      // makes a retry safe even if the prior request failed after writing events
      // but before updating the compact index.
      refreshReviewForAssignment(
        eventsSheet,
        reviewsSheet,
        assignmentRecord.assignment
      );
      markServiceTimer(timer, 'review_refreshed');

      if (eventCorrectBoolean(data.correct)) {
        retireAssignmentIfActive(
          assignmentsSheet,
          assignmentRecord.row_index,
          clean(data.request_id, 200),
          serverTimestamp
        );
        markServiceTimer(timer, 'assignment_retired');

        const queueConfig = optionalQueueSelectionConfig(data);
        if (queueConfig) {
          const ensured = ensureActiveQueue(
            assignmentsSheet,
            questionBankSheet,
            reviewsSheet,
            data,
            queueConfig,
            new Date()
          );
          activeAssignments = ensured.assignments;
          timer.created_count = ensured.created_count;
          markServiceTimer(timer, 'queue_refilled');
        }
      }

      if (activeAssignments === null) {
        activeAssignments = getActiveAssignmentsForStudent(
          assignmentsSheet,
          data.course_id,
          data.student_id
        );
      }
      timer.assignment_count = activeAssignments.length;
    }

    timer.result = duplicate ? 'duplicate' : 'written';
    const response = {
      ok: true,
      request_id: data.request_id,
      duplicate: duplicate
    };
    if (activeAssignments !== null) response.assignments = activeAssignments;
    return jsonResponse(response);
  } finally {
    lock.releaseLock();
    logServiceTimer(timer);
  }
}

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

function handleGetActiveAssignments(data, ss) {
  validateAssignmentRequest(data);

  const assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  if (!assignmentsSheet) throw new Error('The assignments sheet does not exist.');
  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);

  const assignments = getActiveAssignmentsForStudent(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );

  return jsonResponse({
    ok: true,
    request_id: data.request_id,
    assignments: assignments
  });
}

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
  if (!assignmentsSheet || !questionBankSheet || !reviewsSheet) {
    throw new Error(
      'assignments, question_bank, and reviews must exist. Run setupGradeSheet() after updating Code.gs.'
    );
  }
  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);
  ensureSheetHeaders(questionBankSheet, QUESTION_BANK_HEADERS, QUESTION_BANK_SHEET);
  ensureSheetHeaders(reviewsSheet, REVIEW_HEADERS, REVIEW_SHEET);

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  markServiceTimer(timer, 'lock_acquired');

  try {
    const ensured = ensureActiveQueue(
      assignmentsSheet,
      questionBankSheet,
      reviewsSheet,
      data,
      queueConfig,
      new Date()
    );

    timer.result = ensured.created_count ? 'filled' : 'existing';
    timer.assignment_count = ensured.assignments.length;
    timer.created_count = ensured.created_count;
    return jsonResponse({
      ok: true,
      request_id: data.request_id,
      created: ensured.created_count > 0,
      created_count: ensured.created_count,
      assignments: ensured.assignments
    });
  } finally {
    lock.releaseLock();
    logServiceTimer(timer);
  }
}

function ensureActiveQueue(
  assignmentsSheet,
  questionBankSheet,
  reviewsSheet,
  data,
  queueConfig,
  asOf
) {
  let active = getActiveAssignmentsForStudent(
    assignmentsSheet,
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
    return { assignments: active, created_count: 0 };
  }

  const bank = getQuestionBank(questionBankSheet);
  const unlocked = new Set(queueConfig.unlocked_topics);
  const knownTopics = new Set(bank.map(function(item) { return item.topic; }));
  const unknownTopics = queueConfig.unlocked_topics.filter(function(topic) {
    return !knownTopics.has(topic);
  });
  if (unknownTopics.length) {
    throw new Error(
      'Unknown unlocked topic(s): ' + unknownTopics.join(', ') +
      '. Sync question_bank and check APP_CONFIG$unlocked_topics.'
    );
  }

  const eligible = bank.filter(function(item) {
    return (
      item.event === 'exercise_result' &&
      item.points > 0 &&
      unlocked.has(item.topic)
    );
  });
  if (eligible.length < queueConfig.queue_size) {
    throw new Error(
      'Only ' + eligible.length +
      ' scored exercise question(s) are available in unlocked topics, but queue_size ' +
      queueConfig.queue_size + ' was requested.'
    );
  }

  const history = getAssignmentsForStudentHistory(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );
  const activeLabels = new Set(active.map(function(item) { return item.item_label; }));
  let candidates = eligible.filter(function(item) {
    return !activeLabels.has(item.item_label);
  });
  const needed = queueConfig.queue_size - active.length;
  if (candidates.length < needed) {
    throw new Error('Not enough distinct eligible questions to fill the active queue.');
  }

  const selected = [];

  if (!history.length) {
    const starters = candidates.filter(function(item) { return item.starter_question; });
    if (!starters.length) {
      throw new Error(
        'No starter questions are eligible. Mark starter_question=TRUE on at least one ' +
        'scored exercise in an unlocked topic and sync question_bank.'
      );
    }
    if (starters.length > queueConfig.queue_size) {
      throw new Error(
        'There are ' + starters.length + ' eligible starter questions but queue_size is only ' +
        queueConfig.queue_size + '. Increase the queue or reduce the starter set.'
      );
    }

    starters.forEach(function(item) {
      selected.push({ item: item, reason: 'starter' });
    });
    const selectedLabels = new Set(starters.map(function(item) { return item.item_label; }));
    candidates = candidates.filter(function(item) {
      return !selectedLabels.has(item.item_label);
    });

    const remaining = needed - selected.length;
    if (remaining > 0) {
      const retrievabilities = {};
      queueConfig.unlocked_topics.forEach(function(topic) {
        retrievabilities[topic] = 0;
      });
      selectAdaptiveQuestions(
        candidates,
        history,
        retrievabilities,
        remaining
      ).forEach(function(item) {
        selected.push({ item: item, reason: 'initial_fill' });
      });
    }
  } else {
    const reviews = getReviewsForStudent(
      reviewsSheet,
      data.course_id,
      data.student_id
    );
    const topicRetrievabilities = topicRetrievabilitiesFromReviews(
      reviews,
      queueConfig.unlocked_topics,
      asOf
    );
    selectAdaptiveQuestions(
      candidates,
      history,
      topicRetrievabilities,
      needed
    ).forEach(function(item) {
      selected.push({ item: item, reason: 'fsrs_retrievability' });
    });
  }

  if (selected.length !== needed) {
    throw new Error(
      'Queue selection produced ' + selected.length + ' replacement(s); expected ' + needed + '.'
    );
  }

  appendActiveAssignments(assignmentsSheet, selected, data, new Date().toISOString());
  active = getActiveAssignmentsForStudent(
    assignmentsSheet,
    data.course_id,
    data.student_id
  );

  if (active.length !== queueConfig.queue_size) {
    throw new Error('Active queue did not reach the requested size after assignment creation.');
  }

  return { assignments: active, created_count: selected.length };
}

function appendActiveAssignments(assignmentsSheet, selected, data, assignedAt) {
  if (!selected.length) return;

  const rows = selected.map(function(selection) {
    const canonical = selection.item;
    return [
      Utilities.getUuid(),
      clean(data.course_id, 200),
      clean(data.week_id, 200),
      clean(data.student_id, 200),
      clean(canonical.item_label, 300),
      clean(canonical.topic, 300),
      canonical.points,
      clean(canonical.question_hash, 100),
      assignedAt,
      selection.reason,
      ASSIGNMENT_STATUS_ACTIVE,
      '',
      '',
      ''
    ];
  });

  assignmentsSheet
    .getRange(
      assignmentsSheet.getLastRow() + 1,
      1,
      rows.length,
      ASSIGNMENT_HEADERS.length
    )
    .setValues(rows);
}

function retireAssignmentIfActive(
  assignmentsSheet,
  rowIndex,
  requestId,
  retiredAt
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
    'correct',
    requestId
  ]]);
  return true;
}

function selectAdaptiveQuestions(
  eligible,
  history,
  topicRetrievabilities,
  questionCount,
  randomFn
) {
  const exposureCounts = {};
  history.forEach(function(assignment) {
    const label = String(assignment.item_label);
    exposureCounts[label] = (exposureCounts[label] || 0) + 1;
  });

  const random = randomFn || Math.random;

  return eligible
    .map(function(item) {
      const retrievability = Object.prototype.hasOwnProperty.call(
        topicRetrievabilities,
        item.topic
      )
        ? topicRetrievabilities[item.topic]
        : 0;

      return {
        item: item,
        topic_retrievability: retrievability,
        exposure_count: exposureCounts[item.item_label] || 0,
        random_key: random()
      };
    })
    .sort(function(aa, bb) {
      if (aa.topic_retrievability !== bb.topic_retrievability) {
        return aa.topic_retrievability - bb.topic_retrievability;
      }
      if (aa.exposure_count !== bb.exposure_count) {
        return aa.exposure_count - bb.exposure_count;
      }
      return aa.random_key - bb.random_key;
    })
    .slice(0, questionCount)
    .map(function(row) { return row.item; });
}

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
}

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

function fsrsElapsedDays(fromTime, toTime) {
  return Math.max(
    0,
    Math.floor((new Date(toTime).getTime() - new Date(fromTime).getTime()) / MILLIS_PER_DAY)
  );
}

function fsrsInitialStability(rating) {
  return fsrsClampStability(FSRS_PARAMETERS[rating - 1]);
}

function fsrsInitialDifficulty(rating) {
  const difficulty =
    FSRS_PARAMETERS[4] -
    Math.pow(Math.E, FSRS_PARAMETERS[5] * (rating - 1)) +
    1;
  return fsrsClampDifficulty(difficulty);
}

function fsrsNextDifficulty(difficulty, rating) {
  const initialEasy = fsrsInitialDifficultyUnclamped(4);
  const deltaDifficulty = -(FSRS_PARAMETERS[6] * (rating - 3));
  const dampedDelta = (10.0 - difficulty) * deltaDifficulty / 9.0;
  const next =
    FSRS_PARAMETERS[7] * initialEasy +
    (1 - FSRS_PARAMETERS[7]) * (difficulty + dampedDelta);
  return fsrsClampDifficulty(next);
}

function fsrsInitialDifficultyUnclamped(rating) {
  return (
    FSRS_PARAMETERS[4] -
    Math.pow(Math.E, FSRS_PARAMETERS[5] * (rating - 1)) +
    1
  );
}

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

function fsrsClampStability(stability) {
  return Math.max(stability, FSRS_STABILITY_MIN);
}

function fsrsClampDifficulty(difficulty) {
  return Math.min(
    Math.max(difficulty, FSRS_DIFFICULTY_MIN),
    FSRS_DIFFICULTY_MAX
  );
}

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

function validateAssignmentRequest(data) {
  validateCommonPayload(data);

  if (!data.student_id) throw new Error('student_id is required.');
  if (!/^[A-Za-z0-9._@-]{2,100}$/.test(String(data.student_id))) {
    throw new Error('student_id has an invalid format.');
  }
}

function validateQueueSelectionConfig(data) {
  let rawSize = data.queue_size;
  if (typeof rawSize === 'undefined' || rawSize === null || rawSize === '') {
    rawSize = data.questions_per_week;
  }
  const queueSize = Number(rawSize);
  if (!Number.isInteger(queueSize) || queueSize < 1 || queueSize > 500) {
    throw new Error('queue_size must be an integer from 1 through 500.');
  }

  if (!Array.isArray(data.unlocked_topics) || !data.unlocked_topics.length) {
    throw new Error('unlocked_topics must be a non-empty array.');
  }

  const topics = data.unlocked_topics.map(function(x) {
    return String(x).trim();
  });
  if (topics.some(function(x) { return !x || x.length > 300; })) {
    throw new Error('Each unlocked topic must be a non-empty string of at most 300 characters.');
  }
  if (new Set(topics).size !== topics.length) {
    throw new Error('unlocked_topics must not contain duplicates.');
  }

  return {
    queue_size: queueSize,
    unlocked_topics: topics
  };
}

function optionalQueueSelectionConfig(data) {
  const hasSize = !(
    typeof data.queue_size === 'undefined' &&
    typeof data.questions_per_week === 'undefined'
  );
  const hasTopics = typeof data.unlocked_topics !== 'undefined';
  if (!hasSize && !hasTopics) return null;
  if (!hasSize || !hasTopics) {
    throw new Error('queue_size and unlocked_topics must be supplied together.');
  }
  return validateQueueSelectionConfig(data);
}

function validateCommonPayload(data) {
  if (String(data.schema_version) !== '1') {
    throw new Error('Unsupported schema_version.');
  }
  if (!data.request_id) throw new Error('request_id is required.');
  if (!data.course_id) throw new Error('course_id is required.');
  // week_id remains as provenance during the transition away from weekly
  // assignment semantics. Active-queue identity no longer depends on it.
  if (!data.week_id) throw new Error('week_id is required.');
}

function getAssignmentRows(sheet) {
  if (sheet.getLastRow() <= 1) return [];
  return sheet
    .getRange(
      2,
      1,
      sheet.getLastRow() - 1,
      ASSIGNMENT_HEADERS.length
    )
    .getValues();
}

function getEventRows(sheet) {
  if (sheet.getLastRow() <= 1) return [];
  return sheet
    .getRange(
      2,
      1,
      sheet.getLastRow() - 1,
      EVENT_HEADERS.length
    )
    .getValues();
}

function getReviewRows(sheet) {
  if (sheet.getLastRow() <= 1) return [];
  return sheet
    .getRange(
      2,
      1,
      sheet.getLastRow() - 1,
      REVIEW_HEADERS.length
    )
    .getValues();
}

function activeAssignmentsFromRows(assignmentRows, courseId, studentId) {
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

function getReviewsForStudent(sheet, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return getReviewRows(sheet)
    .filter(function(row) {
      return row[1] === courseKey && row[3] === studentKey;
    })
    .map(reviewRowToObject);
}

function getAssignmentRecordById(sheet, assignmentId) {
  const rowIndex = findSheetRowByValue(sheet, 1, assignmentId);
  if (!rowIndex) return null;
  const row = sheet
    .getRange(rowIndex, 1, 1, ASSIGNMENT_HEADERS.length)
    .getValues()[0];
  return {
    row_index: rowIndex,
    assignment: assignmentRowToObject(row)
  };
}

function assignmentRowToObject(row) {
  return {
    assignment_id: row[0],
    course_id: row[1],
    week_id: row[2],
    student_id: row[3],
    item_label: row[4],
    topic: row[5],
    points: row[6],
    question_hash: row[7],
    assigned_at_utc: row[8],
    assignment_reason: row[9],
    assignment_status: row[10],
    retired_at_utc: row[11],
    retired_reason: row[12],
    retired_request_id: row[13]
  };
}

function assignmentObjectToRow(assignment) {
  return [
    assignment.assignment_id,
    assignment.course_id,
    assignment.week_id,
    assignment.student_id,
    assignment.item_label,
    assignment.topic,
    assignment.points,
    assignment.question_hash,
    assignment.assigned_at_utc,
    assignment.assignment_reason,
    assignment.assignment_status || '',
    assignment.retired_at_utc || '',
    assignment.retired_reason || '',
    assignment.retired_request_id || ''
  ];
}

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

function getQuestionBank(sheet) {
  if (sheet.getLastRow() <= 1) {
    throw new Error(
      'The question_bank sheet is empty. Run scripts/06_sync_question_bank.R first.'
    );
  }

  const rows = sheet
    .getRange(
      2,
      1,
      sheet.getLastRow() - 1,
      QUESTION_BANK_HEADERS.length
    )
    .getValues();

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
      starter_question: sheetBoolean(row[4]),
      question_hash: String(row[5] || '')
    });
  });

  return bank;
}

function findSheetRowByValue(sheet, columnIndex, value) {
  if (sheet.getLastRow() <= 1) return 0;
  const match = sheet
    .getRange(2, columnIndex, sheet.getLastRow() - 1, 1)
    .createTextFinder(String(value))
    .matchEntireCell(true)
    .findNext();
  return match ? match.getRow() : 0;
}

function startServiceTimer(operation, requestId) {
  return {
    operation: operation,
    request_id: String(requestId || ''),
    started_at_ms: Date.now(),
    marks: {}
  };
}

function markServiceTimer(timer, label) {
  timer.marks[label] = Date.now() - timer.started_at_ms;
}

function logServiceTimer(timer) {
  const output = {
    operation: timer.operation,
    request_id: timer.request_id,
    result: timer.result || '',
    total_ms: Date.now() - timer.started_at_ms,
    marks_ms: timer.marks
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
  console.log('service_timing ' + JSON.stringify(output));
}

function sheetBoolean(value) {
  if (value === true || value === 1) return true;
  if (value === false || value === 0 || value === '' || value === null) return false;

  const text = String(value).trim().toLowerCase();
  if (text === 'true' || text === '1' || text === 'yes') return true;
  if (text === 'false' || text === '0' || text === 'no') return false;
  throw new Error('Invalid starter_question value in question_bank: ' + String(value));
}

function eventCorrectBoolean(value) {
  if (value === true || value === 1) return true;
  if (value === false || value === 0 || value === '' || value === null) return false;

  const text = String(value).trim().toLowerCase();
  if (text === 'true' || text === '1' || text === 'yes') return true;
  if (text === 'false' || text === '0' || text === 'no') return false;
  throw new Error('Invalid correct value: ' + String(value));
}

function clean(value, maxLength) {
  if (value === null || typeof value === 'undefined') return '';
  if (typeof value === 'boolean' || typeof value === 'number') return value;

  let text = String(value);
  if (text.length > maxLength) text = text.substring(0, maxLength);

  // Prevent spreadsheet-formula injection from student-controlled text.
  if (/^[=+\-@]/.test(text)) text = "'" + text;
  return text;
}

function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

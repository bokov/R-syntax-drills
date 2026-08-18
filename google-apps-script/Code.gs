const EVENT_SHEET = 'events';
const ASSIGNMENT_SHEET = 'assignments';
const QUESTION_BANK_SHEET = 'question_bank';

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
  'assignment_reason'
];

const QUESTION_BANK_HEADERS = [
  'item_label',
  'event',
  'topic',
  'points',
  'starter_question',
  'question_hash'
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

  ensureManagedSheet(ss, EVENT_SHEET, EVENT_HEADERS);
  ensureManagedSheet(ss, ASSIGNMENT_SHEET, ASSIGNMENT_HEADERS);
  ensureManagedSheet(ss, QUESTION_BANK_SHEET, QUESTION_BANK_HEADERS);

  Logger.log('Grade sheet is ready: ' + ss.getId());
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

  for (let i = 0; i < currentHeaders.length; i++) {
    if (currentHeaders[i] !== headers[i]) {
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

    if (requestType === 'get_assignments') {
      return handleGetAssignments(data, ss);
    }

    if (requestType === 'get_or_create_dynamic_assignments') {
      return handleGetOrCreateDynamicAssignments(data, ss);
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

  const sheet = ss.getSheetByName(EVENT_SHEET);
  if (!sheet) throw new Error('The events sheet does not exist.');
  ensureSheetHeaders(sheet, EVENT_HEADERS, EVENT_SHEET);

  const row = [
    new Date().toISOString(),
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
  try {
    sheet.appendRow(row);
  } finally {
    lock.releaseLock();
  }

  return jsonResponse({
    ok: true,
    request_id: data.request_id
  });
}

function handleGetAssignments(data, ss) {
  validateAssignmentRequest(data);

  const sheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  if (!sheet) throw new Error('The assignments sheet does not exist.');
  ensureSheetHeaders(sheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);

  const assignments = getAssignmentsForStudent(
    sheet,
    data.course_id,
    data.week_id,
    data.student_id
  );

  return jsonResponse({
    ok: true,
    request_id: data.request_id,
    assignments: assignments
  });
}

function handleGetOrCreateDynamicAssignments(data, ss) {
  validateDynamicAssignmentRequest(data);

  const assignmentsSheet = ss.getSheetByName(ASSIGNMENT_SHEET);
  if (!assignmentsSheet) throw new Error('The assignments sheet does not exist.');
  ensureSheetHeaders(assignmentsSheet, ASSIGNMENT_HEADERS, ASSIGNMENT_SHEET);

  const questionBankSheet = ss.getSheetByName(QUESTION_BANK_SHEET);
  if (!questionBankSheet) throw new Error('The question_bank sheet does not exist.');
  ensureSheetHeaders(questionBankSheet, QUESTION_BANK_HEADERS, QUESTION_BANK_SHEET);

  const eventsSheet = ss.getSheetByName(EVENT_SHEET);
  if (!eventsSheet) throw new Error('The events sheet does not exist.');
  ensureSheetHeaders(eventsSheet, EVENT_HEADERS, EVENT_SHEET);

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);

  try {
    const existing = getAssignmentsForStudent(
      assignmentsSheet,
      data.course_id,
      data.week_id,
      data.student_id
    );

    if (existing.length) {
      return jsonResponse({
        ok: true,
        request_id: data.request_id,
        created: false,
        assignments: existing
      });
    }

    const bank = getQuestionBank(questionBankSheet);
    const unlockedTopics = data.unlocked_topics.map(function(x) { return String(x); });
    const unlocked = new Set(unlockedTopics);
    const knownTopics = new Set(bank.map(function(item) { return item.topic; }));
    const unknownTopics = unlockedTopics.filter(function(topic) {
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

    if (eligible.length < data.questions_per_week) {
      throw new Error(
        'Only ' + eligible.length +
        ' scored exercise question(s) are available in unlocked topics, but ' +
        data.questions_per_week + ' were requested.'
      );
    }

    const history = getAssignmentsForStudentAcrossWeeks(
      assignmentsSheet,
      data.course_id,
      data.student_id
    );

    let selected;
    let assignmentReason;

    if (!history.length) {
      selected = eligible.filter(function(item) {
        return item.starter_question;
      });
      assignmentReason = 'starter';

      if (!selected.length) {
        throw new Error(
          'No starter questions are eligible. Mark starter_question=TRUE on at least one ' +
          'scored exercise in an unlocked topic and sync question_bank.'
        );
      }
    } else {
      const eventRows = getEventRows(eventsSheet);
      const topicRetrievabilities = topicRetrievabilitiesFromHistory(
        history,
        eventRows,
        data.course_id,
        data.student_id,
        unlockedTopics,
        new Date()
      );

      selected = selectAdaptiveQuestions(
        eligible,
        history,
        topicRetrievabilities,
        data.questions_per_week
      );
      assignmentReason = 'fsrs_retrievability';
    }

    const now = new Date().toISOString();
    const rows = selected.map(function(canonical) {
      return [
        Utilities.getUuid(),
        clean(data.course_id, 200),
        clean(data.week_id, 200),
        clean(data.student_id, 200),
        clean(canonical.item_label, 300),
        clean(canonical.topic, 300),
        canonical.points,
        clean(canonical.question_hash, 100),
        now,
        assignmentReason
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

    return jsonResponse({
      ok: true,
      request_id: data.request_id,
      created: true,
      assignment_reason: assignmentReason,
      assignments: rows.map(assignmentRowToObject)
    });
  } finally {
    lock.releaseLock();
  }
}

function selectAdaptiveQuestions(
  eligible,
  history,
  topicRetrievabilities,
  questionsPerWeek,
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
    .slice(0, questionsPerWeek)
    .map(function(row) { return row.item; });
}

function topicRetrievabilitiesFromHistory(
  history,
  eventRows,
  courseId,
  studentId,
  unlockedTopics,
  asOf
) {
  const reviews = firstAttemptReviews(history, eventRows, courseId, studentId);
  const reviewsByTopic = {};

  reviews.forEach(function(review) {
    if (!reviewsByTopic[review.topic]) reviewsByTopic[review.topic] = [];
    reviewsByTopic[review.topic].push(review);
  });

  const output = {};
  unlockedTopics.forEach(function(topic) {
    let state = null;
    const topicReviews = reviewsByTopic[topic] || [];

    topicReviews
      .sort(function(aa, bb) {
        return aa.review_time.getTime() - bb.review_time.getTime();
      })
      .forEach(function(review) {
        state = fsrsReviewMemoryState(state, review.rating, review.review_time);
      });

    output[topic] = fsrsCurrentRetrievability(state, asOf);
  });

  return output;
}

function firstAttemptReviews(history, eventRows, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);
  const assignmentsById = {};

  history.forEach(function(assignment) {
    const assignmentId = String(assignment.assignment_id || '');
    if (!assignmentId) return;
    assignmentsById[assignmentId] = assignment;
  });

  const firstByAssignment = {};

  eventRows.forEach(function(row) {
    if (row[4] !== courseKey || row[7] !== studentKey) return;
    if (!GRADED_EVENTS.includes(String(row[9] || ''))) return;

    const assignmentId = String(row[21] || '');
    const assignment = assignmentsById[assignmentId];
    if (!assignment) return;

    const reviewTime = new Date(row[0]);
    if (isNaN(reviewTime.getTime())) return;

    const existing = firstByAssignment[assignmentId];
    if (existing && existing.review_time.getTime() <= reviewTime.getTime()) return;

    firstByAssignment[assignmentId] = {
      topic: String(assignment.topic),
      review_time: reviewTime,
      rating: eventCorrectBoolean(row[13])
        ? FSRS_RATING_GOOD
        : FSRS_RATING_AGAIN
    };
  });

  return Object.keys(firstByAssignment).map(function(assignmentId) {
    return firstByAssignment[assignmentId];
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
}

function validateAssignmentRequest(data) {
  validateCommonPayload(data);

  if (!data.student_id) throw new Error('student_id is required.');
  if (!/^[A-Za-z0-9._@-]{2,100}$/.test(String(data.student_id))) {
    throw new Error('student_id has an invalid format.');
  }
}

function validateDynamicAssignmentRequest(data) {
  validateAssignmentRequest(data);

  const questionsPerWeek = Number(data.questions_per_week);
  if (
    !Number.isInteger(questionsPerWeek) ||
    questionsPerWeek < 1 ||
    questionsPerWeek > 500
  ) {
    throw new Error('questions_per_week must be an integer from 1 through 500.');
  }
  data.questions_per_week = questionsPerWeek;

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
  data.unlocked_topics = topics;
}

function validateCommonPayload(data) {
  if (String(data.schema_version) !== '1') {
    throw new Error('Unsupported schema_version.');
  }
  if (!data.request_id) throw new Error('request_id is required.');
  if (!data.course_id) throw new Error('course_id is required.');
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

function getAssignmentsForStudent(sheet, courseId, weekId, studentId) {
  const courseKey = clean(courseId, 200);
  const weekKey = clean(weekId, 200);
  const studentKey = clean(studentId, 200);

  return getAssignmentRows(sheet)
    .filter(function(row) {
      return (
        row[1] === courseKey &&
        row[2] === weekKey &&
        row[3] === studentKey
      );
    })
    .map(assignmentRowToObject);
}

function getAssignmentsForStudentAcrossWeeks(sheet, courseId, studentId) {
  const courseKey = clean(courseId, 200);
  const studentKey = clean(studentId, 200);

  return getAssignmentRows(sheet)
    .filter(function(row) {
      return row[1] === courseKey && row[3] === studentKey;
    })
    .map(assignmentRowToObject);
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
    assignment_reason: row[9]
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
  throw new Error('Invalid correct value in events sheet: ' + String(value));
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

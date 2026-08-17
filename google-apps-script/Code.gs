const EVENT_SHEET = 'events';
const HEADERS = [
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
  'error_message'
];

const ALLOWED_EVENTS = [
  'identity_saved',
  'exercise_result',
  'question_submission',
  'logging_test'
];

function setupGradeSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) throw new Error('Run this from a script bound to the grading spreadsheet.');

  PropertiesService.getScriptProperties().setProperty('SPREADSHEET_ID', ss.getId());

  let sheet = ss.getSheetByName(EVENT_SHEET);
  if (!sheet) sheet = ss.insertSheet(EVENT_SHEET);

  if (sheet.getLastRow() === 0) {
    sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]);
  } else {
    const currentHeaders = sheet.getRange(1, 1, 1, HEADERS.length).getValues()[0];
    if (JSON.stringify(currentHeaders) !== JSON.stringify(HEADERS)) {
      throw new Error('The existing events header does not match this logger schema. No data were changed.');
    }
  }

  sheet.setFrozenRows(1);
  sheet.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
  sheet.autoResizeColumns(1, HEADERS.length);

  Logger.log('Grade sheet is ready: ' + ss.getId());
}

function doGet() {
  return jsonResponse({ok: true, service: 'learnr-grade-logger', schema_version: '1'});
}

function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      throw new Error('Missing JSON request body.');
    }

    const data = JSON.parse(e.postData.contents);
    validatePayload(data);

    const spreadsheetId = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');
    if (!spreadsheetId) throw new Error('Run setupGradeSheet() before deploying the web app.');

    const ss = SpreadsheetApp.openById(spreadsheetId);
    const sheet = ss.getSheetByName(EVENT_SHEET);
    if (!sheet) throw new Error('The events sheet does not exist.');

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
      clean(data.error_message, 5000)
    ];

    const lock = LockService.getScriptLock();
    lock.waitLock(10000);
    try {
      sheet.appendRow(row);
    } finally {
      lock.releaseLock();
    }

    return jsonResponse({ok: true, request_id: data.request_id});
  } catch (err) {
    console.error(err);
    return jsonResponse({ok: false, error: String(err && err.message ? err.message : err)});
  }
}

function validatePayload(data) {
  if (String(data.schema_version) !== '1') throw new Error('Unsupported schema_version.');
  if (!data.request_id) throw new Error('request_id is required.');
  if (!data.course_id) throw new Error('course_id is required.');
  if (!data.week_id) throw new Error('week_id is required.');
  if (!data.session_token) throw new Error('session_token is required.');
  if (!ALLOWED_EVENTS.includes(String(data.event))) throw new Error('Unsupported event type.');
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

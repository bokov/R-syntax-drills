const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const source = fs.readFileSync(
  path.join(root, 'google-apps-script', 'Code.gs'),
  'utf8'
);

const context = {
  console,
  Math,
  Date,
  Set,
  Object,
  Number,
  String,
  Array,
  Error,
  JSON,
  isNaN
};
vm.createContext(context);
vm.runInContext(
  source + `
    globalThis.__concurrencyTestApi = {
      readSheetSnapshot,
      extendSheetSnapshot,
      readColumnSnapshot,
      extendColumnSnapshot,
      appendRowToSnapshot,
      findEventRowByRequestIdFromRows,
      getAssignmentRecordByIdFromRows,
      applyCorrectEventRetirementsToAssignmentRows,
      activeAssignmentsFromRows,
      compactReviewRowForAssignment,
      reviewRowToObject,
      reviewsForStudentFromEvents,
      planActiveQueueFromSnapshots,
      ASSIGNMENT_STATUS_ACTIVE,
      ASSIGNMENT_STATUS_RETIRED
    };
  `,
  context
);

const api = context.__concurrencyTestApi;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

class FakeRange {
  constructor(sheet, row, column, numRows, numColumns) {
    this.sheet = sheet;
    this.row = row;
    this.column = column;
    this.numRows = numRows;
    this.numColumns = numColumns;
  }

  getValues() {
    const out = [];
    for (let rr = 0; rr < this.numRows; rr += 1) {
      const values = [];
      for (let cc = 0; cc < this.numColumns; cc += 1) {
        const sourceRow = this.sheet.rows[this.row - 1 + rr] || [];
        values.push(sourceRow[this.column - 1 + cc] || '');
      }
      out.push(values);
    }
    return out;
  }

  setValues(values) {
    for (let rr = 0; rr < values.length; rr += 1) {
      const rowIndex = this.row - 1 + rr;
      while (this.sheet.rows.length <= rowIndex) this.sheet.rows.push([]);
      for (let cc = 0; cc < values[rr].length; cc += 1) {
        this.sheet.rows[rowIndex][this.column - 1 + cc] = values[rr][cc];
      }
    }
    return this;
  }
}

class FakeSheet {
  constructor(rows) {
    this.rows = rows.map(function(row) { return row.slice(); });
  }

  getLastRow() {
    return this.rows.length;
  }

  getRange(row, column, numRows, numColumns) {
    return new FakeRange(this, row, column, numRows, numColumns);
  }
}

function assignmentRow(
  assignmentId,
  itemLabel,
  status,
  assignedAt,
  studentId
) {
  return [
    assignmentId,
    'R101',
    'week-01',
    studentId || 'abc123',
    itemLabel,
    'vectors',
    1,
    'hash-' + itemLabel,
    assignedAt || '2026-01-01T00:00:00Z',
    'test',
    status || api.ASSIGNMENT_STATUS_ACTIVE,
    '',
    '',
    ''
  ];
}

function eventRow(requestId, assignmentId, correct, timestamp, studentId) {
  const row = new Array(22).fill('');
  row[0] = timestamp || '2026-01-01T00:01:00Z';
  row[3] = requestId;
  row[4] = 'R101';
  row[7] = studentId || 'abc123';
  row[9] = 'exercise_result';
  row[13] = correct;
  row[21] = assignmentId;
  return row;
}

// A request reads a stable table once, then reconciles only rows appended while
// it waited for the global write lock.
const fakeSheet = new FakeSheet([
  ['header-a', 'header-b'],
  ['old-1', 'x'],
  ['old-2', 'y']
]);
const snapshot = api.readSheetSnapshot(fakeSheet, 2);
assert(snapshot.last_row === 3 && snapshot.rows.length === 2, 'Initial snapshot is wrong.');
fakeSheet.rows.push(['concurrent-3', 'z']);
api.extendSheetSnapshot(fakeSheet, snapshot, 2);
assert(
  snapshot.last_row === 4 &&
    snapshot.rows.map(function(row) { return row[0]; }).join(',') ===
      'old-1,old-2,concurrent-3',
  'Snapshot reconciliation must append only the concurrent tail.'
);
api.appendRowToSnapshot(fakeSheet, snapshot, ['mine-4', 'w'], 2);
assert(
  snapshot.last_row === 5 && fakeSheet.rows[4][0] === 'mine-4',
  'Appending through a reconciled snapshot must use the next unclaimed row.'
);

const columnSheet = new FakeSheet([
  ['assignment_id'],
  ['a1'],
  ['a2']
]);
const columnSnapshot = api.readColumnSnapshot(columnSheet, 1);
columnSheet.rows.push(['a3']);
api.extendColumnSnapshot(columnSheet, columnSnapshot, 1);
assert(
  columnSnapshot.values.join(',') === 'a1,a2,a3',
  'Column-index reconciliation must include a concurrently appended review row.'
);

// A correct event is authoritative for logical retirement when a request's
// assignment snapshot predates a concurrent retirement write.
let assignmentRows = [
  assignmentRow('a1', 'q1'),
  assignmentRow('a2', 'q2', api.ASSIGNMENT_STATUS_ACTIVE, '2026-01-01T00:00:01Z')
];
let eventRows = [eventRow('r1', 'a1', true)];
let effective = api.applyCorrectEventRetirementsToAssignmentRows(
  assignmentRows,
  eventRows
);
assert(
  effective[0][10] === api.ASSIGNMENT_STATUS_RETIRED,
  'A concurrent correct event must retire a stale active snapshot in memory.'
);
assert(
  effective[1][10] === api.ASSIGNMENT_STATUS_ACTIVE,
  'Retirement reconciliation must not affect unrelated assignments.'
);
assert(
  api.activeAssignmentsFromRows(effective, 'R101', 'abc123')
    .map(function(row) { return row.item_label; })
    .join(',') === 'q2',
  'The reconciled active queue must exclude a logically retired assignment.'
);

const record = api.getAssignmentRecordByIdFromRows(assignmentRows, 'a2');
assert(
  record && record.row_index === 3 && record.assignment.item_label === 'q2',
  'Assignment lookup in a snapshot must preserve the physical sheet row index.'
);
assert(
  api.findEventRowByRequestIdFromRows(eventRows, 'r1').row_index === 2,
  'Event lookup in a snapshot must preserve the physical sheet row index.'
);

const compact = api.compactReviewRowForAssignment(
  assignmentRows,
  eventRows,
  { assignment_id: 'a1' }
);
const review = api.reviewRowToObject(compact);
assert(
  review.first_attempt_correct === true && review.attempt_count === 1,
  'Authoritative review reconstruction must preserve first-attempt correctness.'
);

const bank = ['q1', 'q2', 'q3', 'q4', 'q5'].map(function(label, index) {
  return {
    item_label: label,
    event: 'exercise_result',
    topic: 'vectors',
    points: 1,
    starter_question: index === 0,
    question_hash: 'hash-' + label
  };
});

// Duplicate-tab case: tab A already retired q1 and created q3. A later correct
// submission of stale q1 from tab B must converge on the same full queue and
// must not create a second replacement.
assignmentRows = [
  assignmentRow('a1', 'q1', api.ASSIGNMENT_STATUS_RETIRED),
  assignmentRow('a2', 'q2', api.ASSIGNMENT_STATUS_ACTIVE, '2026-01-01T00:00:01Z'),
  assignmentRow('a3', 'q3', api.ASSIGNMENT_STATUS_ACTIVE, '2026-01-01T00:02:00Z')
];
eventRows = [
  eventRow('r1', 'a1', true),
  eventRow('r2', 'a1', true, '2026-01-01T00:03:00Z')
];
effective = api.applyCorrectEventRetirementsToAssignmentRows(
  assignmentRows,
  eventRows
);
let reviews = api.reviewsForStudentFromEvents(
  effective,
  eventRows,
  'R101',
  'abc123'
);
let plan = api.planActiveQueueFromSnapshots(
  effective,
  bank,
  reviews,
  { course_id: 'R101', student_id: 'abc123' },
  { queue_size: 2, topic_priority: ['vectors'] },
  new Date('2026-01-02T00:00:00Z'),
  {
    retired_assignment: { topic: 'vectors' },
    first_attempt_correct: true
  }
);
assert(
  plan.active.map(function(row) { return row.item_label; }).join(',') === 'q2,q3',
  'A stale duplicate-tab submission must see the already-current active queue.'
);
assert(
  plan.selected.length === 0,
  'A stale duplicate-tab correct submission must not create another replacement.'
);

// Two different correct answers for the same student may arrive from separate
// requests. Once both events are visible, both retirements must be reflected and
// exactly the resulting vacancies should be filled.
assignmentRows = [
  assignmentRow('a1', 'q1'),
  assignmentRow('a2', 'q2', api.ASSIGNMENT_STATUS_ACTIVE, '2026-01-01T00:00:01Z'),
  assignmentRow('a3', 'q3', api.ASSIGNMENT_STATUS_ACTIVE, '2026-01-01T00:00:02Z')
];
eventRows = [
  eventRow('r1', 'a1', true),
  eventRow('r2', 'a2', true, '2026-01-01T00:02:00Z')
];
effective = api.applyCorrectEventRetirementsToAssignmentRows(
  assignmentRows,
  eventRows
);
reviews = api.reviewsForStudentFromEvents(
  effective,
  eventRows,
  'R101',
  'abc123'
);
plan = api.planActiveQueueFromSnapshots(
  effective,
  bank,
  reviews,
  { course_id: 'R101', student_id: 'abc123' },
  { queue_size: 3, topic_priority: ['vectors'] },
  new Date('2026-01-02T00:00:00Z'),
  {
    retired_assignment: { topic: 'vectors' },
    first_attempt_correct: false
  }
);
assert(
  plan.active.map(function(row) { return row.item_label; }).join(',') === 'q3',
  'Both concurrent correct events must retire their corresponding assignments.'
);
assert(
  plan.selected.length === 2,
  'The queue planner must fill exactly the vacancies left by concurrent retirements.'
);
assert(
  plan.selected.every(function(selection) {
    return selection.item.topic === 'vectors';
  }),
  'Same-topic retry routing must remain within the existing topic.'
);

// Another student's event must not change this student's effective queue.
const otherStudentEvent = eventRow(
  'other-r1',
  'other-a1',
  true,
  '2026-01-01T00:04:00Z',
  'other123'
);
const withOtherStudent = api.applyCorrectEventRetirementsToAssignmentRows(
  [assignmentRow('mine', 'q5')],
  [otherStudentEvent]
);
assert(
  withOtherStudent[0][10] === api.ASSIGNMENT_STATUS_ACTIVE,
  'A different student must not affect this student while requests overlap.'
);

const lockTiming = vm.runInContext(`(() => {
  const timer = {
    operation: 'log_event',
    request_id: 'lock-timing',
    started_at_ms: Date.now() - 50,
    marks: {},
    lock_wait_ms: 12,
    lock_hold_ms: 34
  };
  return serviceTimerSnapshot(timer);
})()`, context);
assert(
  lockTiming.lock_wait_ms === 12 && lockTiming.lock_hold_ms === 34,
  'Timing diagnostics must expose total lock wait and lock hold durations.'
);

console.log('Assignment-service concurrency snapshot tests passed.');

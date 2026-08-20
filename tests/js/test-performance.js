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
    globalThis.__performanceTestApi = {
      reviewRowAfterNewEvent,
      reviewRowToObject,
      assignmentsForStudentHistoryFromRows,
      activeAssignmentsFromRows,
      sortAssignmentsOldestFirst,
      runtimeSchemaIsReady,
      RUNTIME_SCHEMA_PROPERTY,
      RUNTIME_SCHEMA_VERSION,
      ASSIGNMENT_STATUS_ACTIVE,
      ASSIGNMENT_STATUS_RETIRED
    };
  `,
  context
);

const api = context.__performanceTestApi;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assignmentRow(
  assignmentId,
  itemLabel,
  topic,
  weekId,
  assignedAt,
  status
) {
  return [
    assignmentId,
    'R101',
    weekId || 'week-01',
    'abc123',
    itemLabel,
    topic,
    1,
    'hash-' + itemLabel,
    assignedAt || '2026-01-01T00:00:00Z',
    'test',
    status || '',
    '',
    '',
    ''
  ];
}

const runtimeProperties = {};
runtimeProperties[api.RUNTIME_SCHEMA_PROPERTY] = api.RUNTIME_SCHEMA_VERSION;
assert(
  api.runtimeSchemaIsReady(runtimeProperties) === true,
  'The current runtime schema marker should be accepted.'
);
assert(
  api.runtimeSchemaIsReady({}) === false,
  'A missing runtime schema marker should require setupGradeSheet().'
);
assert(
  api.runtimeSchemaIsReady({ RUNTIME_SCHEMA_VERSION: 'old-version' }) === false,
  'An obsolete runtime schema marker should require setupGradeSheet().'
);

const assignment = {
  assignment_id: 'incremental-a1',
  course_id: 'R101',
  week_id: 'week-01',
  student_id: 'abc123',
  item_label: 'incremental-q1',
  topic: 'vectors'
};

const firstRow = api.reviewRowAfterNewEvent(
  null,
  assignment,
  '2026-01-01T12:00:00Z',
  false
);
const first = api.reviewRowToObject(firstRow);
assert(
  first.first_attempt_correct === false && first.attempt_count === 1,
  'A first incremental review update should preserve the failed first attempt.'
);

const secondRow = api.reviewRowAfterNewEvent(
  firstRow,
  assignment,
  '2026-01-01T12:01:00Z',
  true
);
const second = api.reviewRowToObject(secondRow);
assert(
  second.first_attempt_correct === false,
  'A later correct retry must not overwrite first-attempt correctness.'
);
assert(
  second.attempt_count === 2,
  'A later retry should increment attempt_count exactly once.'
);
assert(
  second.last_attempt_at.getTime() ===
    new Date('2026-01-01T12:01:00Z').getTime(),
  'A later retry should advance last_attempt_at.'
);

let mismatchRejected = false;
try {
  api.reviewRowAfterNewEvent(
    secondRow,
    Object.assign({}, assignment, { item_label: 'different-question' }),
    '2026-01-01T12:02:00Z',
    true
  );
} catch (err) {
  mismatchRejected = /item_label/.test(String(err.message));
}
assert(
  mismatchRejected,
  'Incremental review updates must reject review/assignment metadata mismatches.'
);

const assignmentRows = [
  assignmentRow(
    'active-new',
    'q-new',
    'vectors',
    'week-02',
    '2026-01-03T00:00:00Z',
    api.ASSIGNMENT_STATUS_ACTIVE
  ),
  assignmentRow(
    'retired-old',
    'q-retired',
    'vectors',
    'week-01',
    '2026-01-01T00:00:00Z',
    api.ASSIGNMENT_STATUS_RETIRED
  ),
  assignmentRow(
    'active-old',
    'q-old',
    'vectors',
    'week-01',
    '2026-01-02T00:00:00Z',
    api.ASSIGNMENT_STATUS_ACTIVE
  ),
  [
    'other-student', 'R101', 'week-01', 'other123', 'q-other', 'vectors',
    1, 'hash-other', '2026-01-01T00:00:00Z', 'test',
    api.ASSIGNMENT_STATUS_ACTIVE, '', '', ''
  ]
];

const history = api.assignmentsForStudentHistoryFromRows(
  assignmentRows,
  'R101',
  'abc123'
);
assert(
  history.length === 3,
  'A single assignment snapshot should retain active and retired history for one student.'
);

const active = api.activeAssignmentsFromRows(
  assignmentRows,
  'R101',
  'abc123'
);
assert(
  active.map(function(row) { return row.item_label; }).join(',') === 'q-old,q-new',
  'Active assignments derived from the snapshot should remain oldest-to-newest.'
);

const reversed = api.sortAssignmentsOldestFirst([active[1], active[0]]);
assert(
  reversed.map(function(row) { return row.item_label; }).join(',') === 'q-old,q-new',
  'In-memory queue reconstruction should preserve oldest-to-newest ordering.'
);

console.log('Assignment-service performance helper tests passed.');

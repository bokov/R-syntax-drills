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
    globalThis.__fsrsTestApi = {
      fsrsReviewMemoryState,
      fsrsCurrentRetrievability,
      compactReviewRowsFromEvents,
      reviewRowToObject,
      topicRetrievabilitiesFromReviews,
      topicMasterySummary,
      selectAdaptiveQuestions,
      activeAssignmentsFromRows,
      legacyAssignmentMigrationValues,
      FSRS_RATING_AGAIN,
      FSRS_RATING_GOOD,
      ASSIGNMENT_STATUS_ACTIVE,
      ASSIGNMENT_STATUS_RETIRED
    };
  `,
  context
);

const api = context.__fsrsTestApi;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function approximatelyEqual(aa, bb, tolerance = 1e-9) {
  return Math.abs(aa - bb) <= tolerance;
}

const firstReview = new Date('2026-01-01T12:00:00Z');
const oneWeekLater = new Date('2026-01-08T12:00:00Z');

const initialGood = api.fsrsReviewMemoryState(
  null,
  api.FSRS_RATING_GOOD,
  firstReview
);
assert(
  approximatelyEqual(initialGood.stability, 2.3065),
  'Initial Good stability should use the FSRS-6 default w[2].'
);
assert(
  api.fsrsCurrentRetrievability(initialGood, firstReview) === 1,
  'Retrievability immediately after review should be 1.'
);
const afterWeek = api.fsrsCurrentRetrievability(initialGood, oneWeekLater);
assert(
  afterWeek > 0 && afterWeek < 1,
  'Retrievability should decay as time passes.'
);

const afterAgain = api.fsrsReviewMemoryState(
  initialGood,
  api.FSRS_RATING_AGAIN,
  oneWeekLater
);
const afterGood = api.fsrsReviewMemoryState(
  initialGood,
  api.FSRS_RATING_GOOD,
  oneWeekLater
);
assert(
  afterAgain.stability < afterGood.stability,
  'Again should produce less stability than Good from the same prior state.'
);

function assignmentRow(
  assignmentId,
  itemLabel,
  topic,
  weekId = 'week-01',
  assignedAt = '2026-01-01T00:00:00Z',
  status = ''
) {
  return [
    assignmentId,
    'R101',
    weekId,
    'abc123',
    itemLabel,
    topic,
    1,
    'hash-' + itemLabel,
    assignedAt,
    'test',
    status,
    '',
    '',
    ''
  ];
}

function eventRow(timestamp, assignmentId, correct, requestId) {
  const row = new Array(22).fill('');
  row[0] = timestamp;
  row[3] = requestId || ('req-' + assignmentId + '-' + timestamp);
  row[4] = 'R101';
  row[7] = 'abc123';
  row[9] = 'exercise_result';
  row[13] = correct;
  row[21] = assignmentId;
  return row;
}

const assignmentRows = [
  assignmentRow('a1', 'q1', 'weak'),
  assignmentRow('a2', 'q2', 'strong')
];
const events = [
  eventRow('2026-01-01T12:00:00Z', 'a1', false),
  eventRow('2026-01-01T12:01:00Z', 'a1', true),
  eventRow('2026-01-01T12:00:00Z', 'a2', true)
];

const compactRows = api.compactReviewRowsFromEvents(assignmentRows, events);
assert(
  compactRows.length === 2,
  'Compaction should create one row per attempted assignment exposure.'
);
const compactReviews = compactRows.map(api.reviewRowToObject);
const weakReview = compactReviews.find(function(review) {
  return review.topic === 'weak';
});
assert(
  weakReview.first_attempt_correct === false,
  'The compact review row should preserve only the first-attempt outcome for FSRS/mastery.'
);
assert(
  weakReview.attempt_count === 2,
  'The compact review row should retain the total number of tries for the exposure.'
);
assert(
  weakReview.last_attempt_at.getTime() ===
    new Date('2026-01-01T12:01:00Z').getTime(),
  'The compact review row should retain the last-attempt timestamp.'
);

const retrievabilities = api.topicRetrievabilitiesFromReviews(
  compactReviews,
  ['weak', 'strong', 'new_topic'],
  oneWeekLater
);
assert(
  retrievabilities.weak < retrievabilities.strong,
  'A failed first attempt should leave lower later retrievability than a successful one.'
);
assert(
  retrievabilities.new_topic === 0,
  'A topic with no review history should have zero retrievability.'
);

function masteryReview(index, correct, topic = 'mastery') {
  return {
    assignment_id: 'm' + index,
    topic: topic,
    first_attempt_at: new Date(Date.UTC(2026, 0, index, 12, 0, 0)),
    first_attempt_correct: correct,
    attempt_count: correct ? 1 : 2
  };
}

const nineOfTen = [];
for (let ii = 1; ii <= 10; ii++) {
  nineOfTen.push(masteryReview(ii, ii !== 1));
}
const mastered = api.topicMasterySummary(nineOfTen, 'mastery');
assert(
  mastered.observations === 10,
  'Mastery should count first-attempt observations by topic.'
);
assert(
  mastered.recent_correct === 9,
  'Mastery should count first-attempt correctness in the recent window.'
);
assert(
  mastered.recent_accuracy === 0.9,
  'Nine of the most recent ten should yield 0.9 mastery.'
);
assert(
  mastered.mastered === true,
  'At least ten observations with 90% recent first-attempt accuracy should master a topic.'
);

const eightOfTen = nineOfTen.map(function(review, index) {
  return Object.assign({}, review, { first_attempt_correct: index >= 2 });
});
assert(
  api.topicMasterySummary(eightOfTen, 'mastery').mastered === false,
  'Eight of the most recent ten should not master a topic.'
);
assert(
  api.topicMasterySummary(nineOfTen.slice(0, 9), 'mastery').mastered === false,
  'Fewer than ten observations should never master a topic.'
);

const movingWindow = [masteryReview(1, false)].concat(
  Array.from({ length: 10 }, function(_, index) {
    return masteryReview(index + 2, true);
  })
);
const movingSummary = api.topicMasterySummary(movingWindow, 'mastery');
assert(
  movingSummary.recent_accuracy === 1,
  'Mastery must use the most recent ten observations rather than lifetime accuracy.'
);

const activeRows = [
  assignmentRow(
    'active-new',
    'q-new',
    'weak',
    'week-02',
    '2026-01-03T00:00:00Z',
    api.ASSIGNMENT_STATUS_ACTIVE
  ),
  assignmentRow(
    'retired-old',
    'q-retired',
    'weak',
    'week-01',
    '2026-01-01T00:00:00Z',
    api.ASSIGNMENT_STATUS_RETIRED
  ),
  assignmentRow(
    'active-old',
    'q-old',
    'weak',
    'week-01',
    '2026-01-02T00:00:00Z',
    api.ASSIGNMENT_STATUS_ACTIVE
  )
];
const active = api.activeAssignmentsFromRows(activeRows, 'R101', 'abc123');
assert(
  active.map(function(row) { return row.item_label; }).join(',') === 'q-old,q-new',
  'Only active assignments should be returned, oldest first across former week boundaries.'
);

const legacyRows = [
  assignmentRow('legacy-old', 'q-old', 'weak', 'week-01', '2026-01-01T00:00:00Z'),
  assignmentRow('legacy-current-open', 'q-open', 'weak', 'week-02', '2026-01-08T00:00:00Z'),
  assignmentRow('legacy-current-done', 'q-done', 'weak', 'week-02', '2026-01-08T00:00:00Z')
];
const legacyEvents = [
  eventRow('2026-01-08T12:00:00Z', 'legacy-current-open', false, 'req-open'),
  eventRow('2026-01-08T12:01:00Z', 'legacy-current-done', true, 'req-done')
];
const migrated = api.legacyAssignmentMigrationValues(
  legacyRows,
  legacyEvents,
  '2026-01-10T00:00:00Z'
);
assert(
  migrated[0][0] === api.ASSIGNMENT_STATUS_RETIRED &&
    migrated[0][2] === 'legacy_previous_queue',
  'Older legacy weekly assignments should retire during rolling migration.'
);
assert(
  migrated[1][0] === api.ASSIGNMENT_STATUS_ACTIVE,
  'An unanswered question in the latest legacy batch should remain active.'
);
assert(
  migrated[2][0] === api.ASSIGNMENT_STATUS_RETIRED &&
    migrated[2][2] === 'legacy_already_correct' &&
    migrated[2][3] === 'req-done',
  'An already-correct question in the latest legacy batch should retire during migration.'
);

const eligible = [
  { item_label: 'weak_used', topic: 'weak' },
  { item_label: 'weak_new', topic: 'weak' },
  { item_label: 'strong_new', topic: 'strong' }
];
const exposureHistory = [
  { item_label: 'weak_used' }
];
const selected = api.selectAdaptiveQuestions(
  eligible,
  exposureHistory,
  { weak: 0.4, strong: 0.8 },
  2,
  function() { return 0.5; }
);
assert(
  selected[0].item_label === 'weak_new',
  'Within a selected topic, the least-exposed literal probe should come first.'
);
assert(
  selected[1].item_label === 'weak_used',
  'Lower topic retrievability should outrank literal exposure count in another topic.'
);

console.log('FSRS, review-history, and rolling-queue helper tests passed.');

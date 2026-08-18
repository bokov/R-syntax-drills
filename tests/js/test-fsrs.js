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
  isNaN
};
vm.createContext(context);
vm.runInContext(
  source + `
    globalThis.__fsrsTestApi = {
      fsrsReviewMemoryState,
      fsrsCurrentRetrievability,
      firstAttemptReviews,
      topicRetrievabilitiesFromHistory,
      literalExposureCountsFromAttempts,
      selectAdaptiveQuestions,
      FSRS_RATING_AGAIN,
      FSRS_RATING_GOOD
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

const history = [
  { assignment_id: 'a1', item_label: 'q1', topic: 'weak' },
  { assignment_id: 'a2', item_label: 'q2', topic: 'strong' }
];

function eventRow(timestamp, assignmentId, correct) {
  const row = new Array(22).fill('');
  row[0] = timestamp;
  row[4] = 'R101';
  row[7] = 'abc123';
  row[9] = 'exercise_result';
  row[13] = correct;
  row[21] = assignmentId;
  return row;
}

const events = [
  eventRow('2026-01-01T12:00:00Z', 'a1', false),
  eventRow('2026-01-01T12:01:00Z', 'a1', true),
  eventRow('2026-01-01T12:00:00Z', 'a2', true)
];

const reviews = api.firstAttemptReviews(history, events, 'R101', 'abc123');
const weakReview = reviews.find(function(review) {
  return review.topic === 'weak';
});
assert(
  weakReview.rating === api.FSRS_RATING_AGAIN,
  'Only the first attempt on one persisted exposure should rate the topic.'
);

const retrievabilities = api.topicRetrievabilitiesFromHistory(
  history,
  events,
  'R101',
  'abc123',
  ['weak', 'strong', 'new_topic'],
  oneWeekLater
);
assert(
  retrievabilities.weak < retrievabilities.strong,
  'A failed first attempt should leave lower later retrievability than a successful one.'
);
assert(
  retrievabilities.new_topic === 0,
  'An unlocked topic with no completed review history should have zero retrievability.'
);

const redundancyHistory = [
  { assignment_id: 'e1', item_label: 'weak_used', topic: 'weak' },
  { assignment_id: 'e2', item_label: 'weak_unattempted', topic: 'weak' },
  { assignment_id: 'e3', item_label: 'weak_used', topic: 'weak' }
];
const redundancyEvents = [
  eventRow('2026-01-01T12:00:00Z', 'e1', false),
  eventRow('2026-01-01T12:01:00Z', 'e1', true),
  eventRow('2026-01-08T12:00:00Z', 'e3', true)
];
const exposureCounts = api.literalExposureCountsFromAttempts(
  redundancyHistory,
  redundancyEvents,
  'R101',
  'abc123'
);
assert(
  exposureCounts.weak_used === 2,
  'The same literal question should gain one exposure for each attempted weekly assignment.'
);
assert(
  !Object.prototype.hasOwnProperty.call(exposureCounts, 'weak_unattempted'),
  'An assigned but never-attempted literal question should not count as exposed.'
);

const eligible = [
  { item_label: 'weak_used', topic: 'weak' },
  { item_label: 'weak_unattempted', topic: 'weak' },
  { item_label: 'strong_new', topic: 'strong' }
];
const selected = api.selectAdaptiveQuestions(
  eligible,
  exposureCounts,
  { weak: 0.4, strong: 0.8 },
  2,
  function() { return 0.5; }
);
assert(
  selected[0].item_label === 'weak_unattempted',
  'Within a selected topic, a never-attempted assigned probe should remain least exposed.'
);
assert(
  selected[1].item_label === 'weak_used',
  'Lower topic retrievability should outrank literal exposure count in another topic.'
);

console.log('FSRS helper tests passed.');

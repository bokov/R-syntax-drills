const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const codeSource = fs.readFileSync(
  path.join(root, 'google-apps-script', 'Code.gs'),
  'utf8'
);
const progressSource = fs.readFileSync(
  path.join(root, 'google-apps-script', 'Progress.gs'),
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
  codeSource + '\n' + progressSource + `
    globalThis.__progressTestApi = {
      validateProgressTopics,
      studentProgressSummary
    };
  `,
  context
);

const api = context.__progressTestApi;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function review(topic, correct, when) {
  return {
    topic: topic,
    first_attempt_correct: correct,
    first_attempt_at: new Date(when)
  };
}

const topics = api.validateProgressTopics(['vectors', 'indexing']);
assert(
  JSON.stringify(topics) === JSON.stringify(['vectors', 'indexing']),
  'Progress topics should preserve curriculum order.'
);

let duplicateFailed = false;
try {
  api.validateProgressTopics({ topic_priority: ['vectors', 'vectors'] });
} catch (err) {
  duplicateFailed = /duplicates/.test(String(err.message));
}
assert(duplicateFailed, 'Duplicate progress topics must be rejected.');

const reviews = [
  review('vectors', true, '2026-08-01T00:00:00Z'),
  review('vectors', false, '2026-08-02T00:00:00Z'),
  review('vectors', true, '2026-08-03T00:00:00Z')
];
const rows = api.studentProgressSummary(
  reviews,
  ['vectors', 'indexing'],
  new Date('2026-08-04T00:00:00Z')
);

assert(rows.length === 2, 'Progress should return one row per current curriculum topic.');
assert(rows[0].topic === 'vectors', 'Progress should preserve curriculum order.');
assert(rows[0].observations === 3, 'Practice count should use assignment exposures with reviews.');
assert(rows[0].recent_count === 3, 'Recent count should reuse mastery-window observations.');
assert(rows[0].recent_correct === 2, 'Recent correct count should use first attempts only.');
assert(
  Math.abs(rows[0].recent_accuracy - (2 / 3)) < 1e-12,
  'Recent accuracy should use first-attempt correctness.'
);
assert(
  rows[0].estimated_recall > 0 && rows[0].estimated_recall <= 1,
  'Practiced topics should expose current FSRS retrievability.'
);
assert(rows[1].observations === 0, 'Unpracticed topics should have zero practice count.');
assert(rows[1].recent_accuracy === null, 'Unpracticed topics should have no recent accuracy.');
assert(rows[1].estimated_recall === null, 'Unpracticed topics should have no recall estimate.');

console.log('Progress tests passed.');

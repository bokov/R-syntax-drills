const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const codeSource = fs.readFileSync(
  path.join(root, 'google-apps-script', 'Code.gs'),
  'utf8'
);
const reconciliationSource = fs.readFileSync(
  path.join(root, 'google-apps-script', 'BankReconciliation.gs'),
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
  codeSource + '\n' + reconciliationSource + `
    globalThis.__bankReconciliationTestApi = {
      requestUsesBankReconciliation,
      requestedAvailableItemLabels,
      bankReconciliationForRequest,
      discontinuedAssignmentReason,
      discontinuedActiveAssignments,
      validateHistoryAgainstCurriculum
    };
  `,
  context
);

const api = context.__bankReconciliationTestApi;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assignment(label, topic, points) {
  return {
    assignment_id: 'a-' + label,
    item_label: label,
    topic: topic,
    points: points
  };
}

assert(
  !api.requestUsesBankReconciliation({ schema_version: '1' }),
  'Ordinary requests should not request reconciliation.'
);
assert(
  api.requestUsesBankReconciliation({ reconcile_bank: true }),
  'reconcile_bank=true should request reconciliation.'
);

const labels = api.requestedAvailableItemLabels({
  available_item_labels: ['q1', 'q2']
});
assert(labels.length === 2 && labels[0] === 'q1' && labels[1] === 'q2',
  'Available item labels should be preserved.');

let duplicateFailed = false;
try {
  api.requestedAvailableItemLabels({ available_item_labels: ['q1', 'q1'] });
} catch (err) {
  duplicateFailed = /must not contain duplicates/.test(String(err.message));
}
assert(duplicateFailed, 'Duplicate available item labels must be rejected.');

const fakeBankSheet = {};
const reconciliation = api.bankReconciliationForRequest(
  {
    reconcile_bank: true,
    available_item_labels: ['q1', 'q3']
  },
  fakeBankSheet
);
assert(reconciliation.compatible, 'ID reconciliation should not block a client.');

const bank = [
  {
    item_label: 'q1',
    event: 'exercise_result',
    topic: 'vectors',
    points: 1
  },
  {
    item_label: 'q2',
    event: 'exercise_result',
    topic: 'vectors',
    points: 1
  },
  {
    item_label: 'q3',
    event: 'exercise_result',
    topic: 'lists',
    points: 1
  }
];

assert(
  api.discontinuedAssignmentReason(
    assignment('q1', 'vectors', 1),
    bank,
    ['vectors', 'lists']
  ) === '',
  'An available assignment with matching ID and metadata should remain active.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('q2', 'vectors', 1),
    bank,
    ['vectors', 'lists']
  ) === 'client_content_unavailable',
  'An assignment absent from the client content should be retired.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('missing', 'vectors', 1),
    bank,
    ['vectors', 'lists']
  ) === 'client_content_unavailable',
  'A missing client ID should be retired before it can reach the player.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('q3', 'lists', 2),
    bank,
    ['vectors', 'lists']
  ) === 'question_updated',
  'Changed structural metadata should retire the stale assignment.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('q1', 'vectors', 1),
    bank,
    ['lists']
  ) === 'topic_discontinued',
  'Assignments from removed topics should be retired.'
);

assert(
  api.discontinuedActiveAssignments(
    [
      assignment('q1', 'vectors', 1),
      assignment('q2', 'vectors', 1)
    ],
    bank,
    ['vectors', 'lists']
  ).length === 1,
  'Only assignments unavailable to the client should be selected for retirement.'
);

api.validateHistoryAgainstCurriculum(
  [assignment('old-q', 'old-topic', 1)],
  ['vectors', 'lists']
);

console.log('Bank reconciliation tests passed.');

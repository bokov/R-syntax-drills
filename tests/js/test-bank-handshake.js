const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const codeSource = fs.readFileSync(
  path.join(root, 'google-apps-script', 'Code.gs'),
  'utf8'
);
const handshakeSource = fs.readFileSync(
  path.join(root, 'google-apps-script', 'BankHandshake.gs'),
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
  codeSource + '\n' + handshakeSource + `
    globalThis.__bankHandshakeTestApi = {
      requestUsesBankHandshake,
      questionBankVersionFromRows,
      bankHandshakeForRequest,
      discontinuedAssignmentReason,
      discontinuedActiveAssignments,
      validateHistoryAgainstCurriculum
    };
  `,
  context
);

const api = context.__bankHandshakeTestApi;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function bankRow(label, topic, hash, bankVersion) {
  return [label, 'exercise_result', topic, 1, false, hash, bankVersion];
}

function assignment(label, topic, hash) {
  return {
    assignment_id: 'a-' + label,
    item_label: label,
    topic: topic,
    points: 1,
    question_hash: hash
  };
}

assert(
  !api.requestUsesBankHandshake({ schema_version: '1' }),
  'Legacy requests must not opt into the bank handshake.'
);
assert(
  api.requestUsesBankHandshake({ bank_version: 'md5-abc' }),
  'A non-empty bank_version must opt into the handshake.'
);

const rows = [
  bankRow('q1', 'vectors', 'h1', 'md5-current'),
  bankRow('q2', 'vectors', 'h2', 'md5-current')
];
assert(
  api.questionBankVersionFromRows(rows) === 'md5-current',
  'One synchronized bank version should be returned.'
);

let mixedVersionFailed = false;
try {
  api.questionBankVersionFromRows([
    bankRow('q1', 'vectors', 'h1', 'md5-a'),
    bankRow('q2', 'vectors', 'h2', 'md5-b')
  ]);
} catch (err) {
  mixedVersionFailed = /multiple bank_version/.test(String(err.message));
}
assert(mixedVersionFailed, 'Mixed bank versions must be rejected.');

const fakeBankSheet = {
  getLastRow: function() { return 3; },
  getRange: function() {
    return { getValues: function() { return rows; } };
  }
};

const legacyHandshake = api.bankHandshakeForRequest(
  { package_version: '0.1.0.9000' },
  fakeBankSheet
);
assert(legacyHandshake === null, 'Legacy requests must remain untouched.');

const matching = api.bankHandshakeForRequest(
  { bank_version: 'md5-current', package_version: '0.1.0.9000' },
  fakeBankSheet
);
assert(matching.compatible, 'Matching bank versions should be compatible.');
assert(
  matching.current_bank_version === 'md5-current',
  'Matching handshake should expose the current bank version.'
);

const mismatch = api.bankHandshakeForRequest(
  { bank_version: 'md5-old', package_version: '0.1.0.9000' },
  fakeBankSheet
);
assert(!mismatch.compatible, 'Mismatched bank versions must not be compatible.');
assert(
  mismatch.response.code === 'bank_update_required',
  'Mismatch should return a structured bank_update_required response.'
);
assert(
  mismatch.response.current_bank_version === 'md5-current',
  'Mismatch response should identify the current bank version.'
);

const bank = [
  {
    item_label: 'q1',
    event: 'exercise_result',
    topic: 'vectors',
    points: 1,
    question_hash: 'h1'
  },
  {
    item_label: 'q3',
    event: 'exercise_result',
    topic: 'lists',
    points: 1,
    question_hash: 'h3-new'
  }
];

assert(
  api.discontinuedAssignmentReason(
    assignment('q1', 'vectors', 'h1'),
    bank,
    ['vectors', 'lists']
  ) === '',
  'Current active assignments should remain active.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('q2', 'vectors', 'h2'),
    bank,
    ['vectors', 'lists']
  ) === 'question_discontinued',
  'Missing item labels should be treated as discontinued questions.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('q3', 'lists', 'h3-old'),
    bank,
    ['vectors', 'lists']
  ) === 'question_updated',
  'Changed canonical metadata should retire the stale active assignment.'
);
assert(
  api.discontinuedAssignmentReason(
    assignment('q1', 'vectors', 'h1'),
    bank,
    ['lists']
  ) === 'topic_discontinued',
  'Active assignments from removed topics should be retired.'
);

assert(
  api.discontinuedActiveAssignments(
    [
      assignment('q1', 'vectors', 'h1'),
      assignment('q2', 'vectors', 'h2')
    ],
    bank,
    ['vectors', 'lists']
  ).length === 1,
  'Only stale active assignments should be selected for retirement.'
);

// Historical assignments from a removed topic must remain valid history rather
// than making the current curriculum unusable.
api.validateHistoryAgainstCurriculum(
  [assignment('old-q', 'old-topic', 'old-hash')],
  ['vectors', 'lists']
);

console.log('Bank handshake tests passed.');

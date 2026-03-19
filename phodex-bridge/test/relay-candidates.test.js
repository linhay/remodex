const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildRelayCandidateList,
  createRelayCandidateRotator,
} = require('../src/relay-candidates');

test('buildRelayCandidateList preserves explicit candidate priority and deduplicates', () => {
  const candidates = buildRelayCandidateList('wss://relay.section.trade/relay/', [
    'ws://linhey.local:8788/relay',
    'wss://relay.section.trade/relay',
    'ws://192.168.204.175:8788/relay/',
  ]);

  assert.deepEqual(candidates, [
    'ws://linhey.local:8788/relay',
    'wss://relay.section.trade/relay',
    'ws://192.168.204.175:8788/relay',
  ]);
});

test('rotator returns current session url and advances in round-robin order', () => {
  const rotator = createRelayCandidateRotator(
    ['ws://linhey.local:8788/relay', 'ws://192.168.204.175:8788/relay', 'wss://relay.section.trade/relay'],
    '85d358c0-611f-4ba5-8668-4351206f70da'
  );

  assert.equal(rotator.currentSessionUrl(), 'ws://linhey.local:8788/relay/85d358c0-611f-4ba5-8668-4351206f70da');
  assert.equal(rotator.advance(), 'ws://192.168.204.175:8788/relay');
  assert.equal(rotator.currentSessionUrl(), 'ws://192.168.204.175:8788/relay/85d358c0-611f-4ba5-8668-4351206f70da');
  assert.equal(rotator.advance(), 'wss://relay.section.trade/relay');
  assert.equal(rotator.advance(), 'ws://linhey.local:8788/relay');
});

test('rotator does not advance when only one candidate exists', () => {
  const rotator = createRelayCandidateRotator(['ws://192.168.204.175:8788/relay'], 'session-1');
  assert.equal(rotator.advance(), 'ws://192.168.204.175:8788/relay');
  assert.equal(rotator.currentSessionUrl(), 'ws://192.168.204.175:8788/relay/session-1');
});

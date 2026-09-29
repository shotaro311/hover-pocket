import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../Sources/HoverPocket/Voice/CodexVoiceWebRTCTransport.swift', import.meta.url), 'utf8');
const start = source.indexOf('  function observeAudioActivity(');
const end = source.indexOf('  async function acceptAnswer', start);
assert(start > 0 && end > start);
const code = source.slice(start, end);
const flush = () => new Promise(resolve => setImmediate(resolve));
function harness() {
  const messages = [];
  let scheduled;
  const state = {
    muted: false, current: true, clock: 1000, audioActivityTimer: null,
    report: { type: 'inbound-rtp', kind: 'audio', id: 'audio', audioLevel: 0 },
    performance: { now: () => state.clock },
    post: message => messages.push(message),
    window: { setTimeout: callback => { scheduled = callback; return 1; } },
    isCurrentOperation: () => state.current,
    peer: { getStats: async () => new Map([['audio', state.report]]) },
  };
  vm.createContext(state);
  vm.runInContext(`${code}\nobserveAudioActivity(peer, 1, 'session-1');`, state);
  return { state, messages, sample: async () => { const callback = scheduled; scheduled = null; await callback(); await flush(); }, hasTimer: () => !!scheduled };
}
let h = harness(); await flush();
assert.equal(h.messages.at(-1).activity, 'listening');
h.state.report.audioLevel = 0.2; await h.sample();
assert.equal(h.messages.at(-1).activity, 'speaking');
let count = h.messages.length; await h.sample();
assert.equal(h.messages.length, count, 'unchanged activity must not flood the bridge');
h.state.report.audioLevel = 0; h.state.clock += 160; await h.sample();
assert.equal(h.messages.at(-1).activity, 'speaking', 'short word pauses stay smooth');
h.state.clock += 200; await h.sample();
assert.equal(h.messages.at(-1).activity, 'listening');
h.state.muted = true; h.state.report.audioLevel = 0.8; await h.sample();
assert.equal(h.messages.at(-1).activity, 'listening');
h.state.muted = false; await h.sample();
assert.equal(h.messages.at(-1).activity, 'speaking');
h.state.current = false; count = h.messages.length; await h.sample();
assert.equal(h.messages.length, count); assert(!h.hasTimer(), 'stale session must stop polling');

h = harness(); await flush();
h.state.report = { type: 'inbound-rtp', kind: 'audio', id: 'audio', totalAudioEnergy: 1, totalSamplesDuration: 10 };
await h.sample();
h.state.report = { ...h.state.report, totalAudioEnergy: 1.02, totalSamplesDuration: 10.2 };
await h.sample(); assert.equal(h.messages.at(-1).activity, 'speaking', 'energy works when audioLevel is absent');
h.state.peer.getStats = async () => { throw new Error('unsupported'); };
h.state.clock += 500; await h.sample();
assert.equal(h.messages.at(-1).activity, 'listening'); assert(h.hasTimer());

h = harness(); await flush();
let resolveStats;
h.state.peer.getStats = () => new Promise(resolve => { resolveStats = resolve; });
const pending = h.sample(); h.state.current = false; count = h.messages.length;
resolveStats(new Map([['audio', { type: 'inbound-rtp', kind: 'audio', id: 'audio', audioLevel: 0.5 }]]));
await pending; assert.equal(h.messages.length, count); assert(!h.hasTimer());
assert(source.includes('window.clearTimeout(audioActivityTimer);'), 'teardown clears the pending timer');
console.log('PASS voice audio activity: silence, speaking, debounce, mute, resume, energy, missing stats, stale and in-flight shutdown');

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');

function fixture(options = {}) {
  let elements = [];
  let listener;
  const reports = [];
  const events = {};
  const document = {
    title: 'A paused tab',
    querySelectorAll: selector => selector === 'audio, video' ? elements : [],
    addEventListener(type, listener) { events[type] = listener; },
    removeEventListener(type) { delete events[type]; }
  };
  const context = vm.createContext({
    document, navigator: options.navigator, location: { hostname: 'example.test' }, crypto: { randomUUID },
    chrome: { runtime: {
      sendMessage: async message => { reports.push(structuredClone(message)); if (options.sendMessage) return options.sendMessage(message); },
      onMessage: { addListener: callback => { listener = callback; } }
    } },
    MutationObserver: class { observe() {} disconnect() {} }, setInterval() {}, clearInterval() {}, setTimeout, clearTimeout
  });
  if (options.microphone) context.__soundShelfMic = options.microphone;
  vm.runInContext(fs.readFileSync('BrowserExtension/content.js', 'utf8'), context);
  const media = overrides => ({
    src: 'data:audio/wav;base64,AAAA', paused: true, ended: false, currentTime: 0,
    volume: 0.5, muted: false, readyState: 4, seeking: false, controls: true,
    getAttribute() { return null; }, querySelector() { return null; },
    getBoundingClientRect: () => ({ width: 300, height: 54 }), getClientRects: () => [1],
    async play() { this.paused = false; }, pause() { this.paused = true; },
    ...overrides
  });
  return {
    reports, media, document,
    emit(type, target) { events[type]?.({ type, target }); },
    setMedia(value) { elements = value; },
    async report() { await new Promise(setImmediate); await context.__soundShelf.report(); return reports.at(-1).sources; },
    command(message) { return new Promise(resolve => listener({ type: 'control', ...message }, {}, resolve)); }
  };
}

test('loaded and paused players are listed before they play, with stable IDs', async () => {
  const f = fixture();
  const paused = f.media({ currentTime: 15 });
  const ready = f.media({});
  f.setMedia([paused, ready]);
  const sources = await f.report();
  assert.equal(sources.length, 2);
  assert.equal(sources[0].playing, false);
  assert.equal(sources[0].ready, false);
  assert.equal(sources[1].ready, true);
  assert.equal((await f.report())[0].id, sources[0].id);
});

test('play, pause, mute, and volume target only the selected media element', async () => {
  const f = fixture();
  const first = f.media({}), second = f.media({});
  f.setMedia([first, second]);
  const [{ id }] = await f.report();
  assert.equal((await f.command({ id, action: 'play' })).ok, true);
  assert.equal(first.paused, false);
  assert.equal(second.paused, true);
  await f.command({ id, action: 'pause' });
  assert.equal(first.paused, true);
  await f.command({ id, action: 'volume', value: 2 });
  assert.equal(first.volume, 1);
  assert.equal(second.volume, 0.5);
  await f.command({ id, action: 'mute', value: 1 });
  assert.equal(first.muted, true);
  assert.equal(second.muted, false);
});

test('removed players disappear and stale commands return an error', async () => {
  const f = fixture();
  f.setMedia([f.media({})]);
  const [{ id }] = await f.report();
  f.setMedia([]);
  assert.equal((await f.report()).length, 0);
  assert.match((await f.command({ id, action: 'play' })).error, /no longer available/);
});

test('autoplay failures are returned to the app instead of reported as playing', async () => {
  const f = fixture();
  f.setMedia([f.media({ play: async () => { throw new Error('NotAllowedError'); } })]);
  const [{ id }] = await f.report();
  assert.equal((await f.command({ id, action: 'play' })).error, 'NotAllowedError');
  assert.equal((await f.report())[0].playing, false);
});

test('unloaded elements are excluded, ended media can be replayed', async () => {
  const f = fixture();
  const ended = f.media({ ended: true, currentTime: 9 });
  f.setMedia([f.media({ src: '' }), ended]);
  const sources = await f.report();
  assert.equal(sources.length, 1);
  await f.command({ id: sources[0].id, action: 'play' });
  assert.equal(ended.currentTime, 0);
});

test('an update during an in-flight report is flushed before a command is acknowledged', async () => {
  let release;
  const f = fixture({ sendMessage: () => new Promise(resolve => { release = resolve; }) });
  const media = f.media({});
  f.setMedia([media]);
  // Initial empty report is held; a command changes state while it is in flight.
  let acknowledged = false;
  const command = f.command({ id: 'not-yet-known', action: 'play' });
  // Capture the actual ID in a first queued media report.
  release();
  await new Promise(setImmediate);
  // The rejected stale command deliberately creates no state change.
  assert.match((await command).error, /no longer available/);
  const report = f.report();
  await new Promise(setImmediate);
  const id = f.reports.at(-1).sources[0].id;
  const play = f.command({ id, action: 'play' }).then(result => { acknowledged = true; return result; });
  assert.equal(media.paused, false);
  assert.equal(acknowledged, false);
  release();
  await new Promise(setImmediate);
  assert.equal(f.reports.at(-1).sources[0].playing, true);
  assert.equal(acknowledged, false);
  release();
  await report;
  assert.equal((await play).ok, true);
  assert.equal(acknowledged, true);
});

test('command replies include fresh state and a monotonically increasing sequence', async () => {
  const f = fixture();
  f.setMedia([f.media({})]);
  const [{ id }] = await f.report();
  const before = f.reports.at(-1).sequence;
  const result = await f.command({ id, action: 'play' });
  assert.equal(result.sources[0].playing, true);
  assert.ok(result.sequence > before);
});

function worker(options = {}) {
  const workerOptions = options;
  const callbacks = {}, sent = [], controls = [], inspections = [], focused = [], calls = [];
  const event = name => ({ addListener(fn) { callbacks[name] = fn; } });
  const tabs = new Map([[10, { id: 10, windowId: 3, url: 'https://example.test', mutedInfo: { muted: false } }]]);
  const docs = new Map([[10, [
    { frameId: 0, parentFrameId: -1, documentId: 'top-10', documentLifecycle: 'active' },
    { frameId: 7, parentFrameId: 0, documentId: 'child-10', documentLifecycle: 'active' }
  ]]]);
  const media = new Map();
  const native = {
    postMessage(message) { sent.push(structuredClone(message)); },
    onMessage: event('nativeMessage'), onDisconnect: event('disconnect')
  };
  const chrome = {
    runtime: { id: 'extension', connectNative: () => native, onMessage: event('message') },
    storage: { session: { get: async () => options.initialState || {}, set: async () => {} } },
    tabs: {
      query: async () => { calls.push({ api: 'query' }); return [...tabs.values()]; },
      get: async id => { calls.push({ api: 'get', tabId: id }); if (!tabs.has(id)) throw new Error('Tab closed'); return structuredClone(tabs.get(id)); },
      onRemoved: event('removed'), onUpdated: event('updated'),
      update: async (id, options) => {
        focused.push({ tabId: id, ...options });
        const tab = tabs.get(id);
        if ('muted' in options) tab.mutedInfo = { muted: options.muted };
        return structuredClone(tab);
      },
      sendMessage: async (tab, message, options) => {
        if (message.type === 'inspect') inspections.push({ tab, options: structuredClone(options) });
        else controls.push({ tab, message: structuredClone(message), options: structuredClone(options) });
        const frame = docs.get(tab)?.find(frame => frame.frameId === options.frameId && frame.documentId === options.documentId);
        if (!frame) throw new Error('Document closed');
        const state = media.get(`${tab}:${options.frameId}`);
        if (message.type === 'inspect') return { ok: true, sources: structuredClone(state.sources), microphone: state.microphone, sequence: ++state.sequence };
        if (message.action === 'microphone') {
          if (workerOptions.failMicrophone) return { error: 'Call rejected microphone change' };
          state.microphone.state = message.value === 1 ? 'disabled' : 'enabled';
          return { ok: true, sources: structuredClone(state.sources), microphone: state.microphone, sequence: ++state.sequence };
        }
        const player = state.sources.find(source => source.id === message.id);
        if (!player) return { error: 'Player closed' };
        if (message.action === 'pause' || message.action === 'play') player.playing = message.action === 'play';
        if (message.action === 'mute') { player.muted = Boolean(message.value); if (!message.value && player.volume === 0) player.volume = 0.5; }
        return { ok: true, sources: structuredClone(state.sources), sequence: ++state.sequence };
      }
    },
    windows: { update: async (id, properties) => { focused.push({ windowId: id, ...properties }); options.onFocus?.(media); } },
    webNavigation: {
      onCommitted: event('navigate'),
      getFrame: async ({ tabId, frameId }) => structuredClone(docs.get(tabId)?.find(frame => frame.frameId === frameId)),
      getAllFrames: async ({ tabId }) => {
        calls.push({ api: 'getAllFrames', tabId });
        const result = structuredClone(docs.get(tabId) || []);
        await options.onGetAllFrames?.(tabId);
        return result;
      }
    },
    scripting: { executeScript: async () => {} },
    alarms: { create() {}, onAlarm: event('alarm') }
  };
  vm.runInNewContext(fs.readFileSync('BrowserExtension/background.js', 'utf8'), { chrome, URL });
  const settle = async () => { for (let i = 0; i < 5; i++) await new Promise(setImmediate); };
  const message = (body, sender = {}) => new Promise(resolve => callbacks.message(body, sender, resolve));
  const element = (id, overrides = {}) => ({ id, title: 'Same title', site: 'example.test', playing: false, ready: false,
    muted: false, volume: 1, visible: false, area: 0, userFacing: true, ...overrides });
  return {
    sent, controls, inspections, focused, calls, callbacks, tabs, docs, element, message, settle,
    microphoneRows: () => sent.filter(item => item.type === 'snapshot').at(-1)?.microphones || [],
    snapshots: () => sent.filter(item => item.type === 'snapshot'),
    rows: () => sent.filter(item => item.type === 'snapshot').at(-1)?.sources || [],
    async report(sources, { tabId = 10, frameId = 0, documentId, sequence, microphone, siteName } = {}) {
      await settle();
      documentId = documentId || docs.get(tabId)?.find(frame => frame.frameId === frameId)?.documentId;
      const key = `${tabId}:${frameId}`, previous = media.get(key);
      const state = { sources: structuredClone(sources), microphone, siteName, sequence: sequence ?? (previous?.sequence || 0) + 1 };
      media.set(key, state);
      return message({ type: 'media', ...state }, { id: 'extension', tab: structuredClone(tabs.get(tabId)), frameId, documentId });
    },
    async command(action, { row, value, tabOnly, microphoneSource, requestId = 'request' } = {}) {
      row = row || this.rows()[0];
      callbacks.nativeMessage({ type: 'command', id: row.id, tabId: row.tabId, frameId: row.frameId, action, value, tabOnly, microphoneSource, requestId });
      await settle();
      return sent.findLast(item => item.type === 'result' && item.requestId === requestId);
    },
    async refresh() { callbacks.nativeMessage({ type: 'refresh' }); await settle(); }
  };
}

test('multiple elements in one YouTube-like tab produce one stable row retaining the paused primary', async () => {
  const w = worker();
  const hidden = w.element('hidden-preload'), main = w.element('main', { playing: true, visible: true, area: 1000 });
  await w.report([hidden, main]);
  assert.equal(w.rows().length, 1);
  assert.equal(w.rows()[0].playing, true);
  const id = w.rows()[0].id;
  assert.equal((await w.command('pause')).ok, true);
  assert.equal(w.controls[0].message.id, 'main');
  assert.equal(w.rows().length, 1);
  assert.equal(w.rows()[0].playing, false);
  assert.equal(w.rows()[0].id, id);
  assert.equal((await w.command('play')).ok, true);
  assert.equal(w.controls.at(-1).message.id, 'main');
});

test('identical titles in different tabs remain separate', async () => {
  const w = worker();
  w.tabs.set(11, { id: 11, url: 'https://example.test', mutedInfo: { muted: false } });
  w.docs.set(11, [{ frameId: 0, parentFrameId: -1, documentId: 'top-11' }]);
  await w.report([w.element('a')]);
  await w.report([w.element('b')], { tabId: 11 });
  assert.equal(w.rows().length, 2);
  assert.notEqual(w.rows()[0].id, w.rows()[1].id);
});

test('pause stops all active elements across frames; play resumes only the primary', async () => {
  const w = worker();
  await w.report([w.element('main', { playing: true })]);
  await w.report([w.element('embedded', { playing: true })], { frameId: 7 });
  assert.equal(w.rows().length, 1);
  assert.equal((await w.command('pause')).ok, true);
  assert.equal(w.controls.length, 2);
  assert.deepEqual(w.controls.map(control => control.options.documentId).sort(), ['child-10', 'top-10']);
  assert.equal(w.rows()[0].playing, false);
});

test('mute affects the entire tab; unmute clears both tab and element-level silence', async () => {
  const w = worker();
  await w.report([w.element('main', { playing: true }), w.element('silent', { muted: true, volume: 0 })]);
  assert.equal((await w.command('mute', { value: 1 })).ok, true);
  assert.equal(w.tabs.get(10).mutedInfo.muted, true);
  assert.equal(w.rows()[0].muted, true);
  assert.equal((await w.command('mute', { value: 0, requestId: 'unmute' })).ok, true);
  assert.equal(w.tabs.get(10).mutedInfo.muted, false);
  assert.equal(w.rows()[0].muted, false);
  assert.equal(w.controls.at(-1).message.id, 'silent');
});

test('late reports from a replaced document and out-of-order sequences are rejected', async () => {
  const w = worker();
  await w.report([w.element('old')]);
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'new-document' }]);
  await w.callbacks.navigate({ tabId: 10, frameId: 0, documentId: 'new-document' });
  assert.equal(w.rows().length, 0);
  assert.equal((await w.report([w.element('old')], { documentId: 'top-10', sequence: 5 })).ok, false);
  assert.equal(w.rows().length, 0);
  await w.report([w.element('new', { playing: true })], { documentId: 'new-document', sequence: 10 });
  assert.equal((await w.report([w.element('new', { playing: false })], { documentId: 'new-document', sequence: 9 })).ok, false);
  assert.equal(w.rows()[0].playing, true);
});

test('removed embedded frames disappear on refresh, while valid paused frames remain', async () => {
  const w = worker();
  await w.report([w.element('embedded')], { frameId: 7 });
  await w.refresh();
  assert.equal(w.rows().length, 1);
  w.docs.get(10).splice(1, 1);
  await w.refresh();
  assert.equal(w.rows().length, 0);
});

test('navigating an embedded parent removes its descendant players', async () => {
  const w = worker();
  w.docs.get(10).push({ frameId: 8, parentFrameId: 7, documentId: 'grandchild' });
  await w.report([], { frameId: 7 });
  await w.report([w.element('nested')], { frameId: 8 });
  assert.equal(w.rows().length, 1);
  await w.callbacks.navigate({ tabId: 10, frameId: 7, documentId: 'replacement' });
  assert.equal(w.rows().length, 0);
});

test('discarded and closed tabs are removed, and stale commands do not reach a replacement page', async () => {
  const w = worker();
  await w.report([w.element('old')]);
  const oldRow = structuredClone(w.rows()[0]);
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'replacement' }]);
  await w.report([w.element('new')]);
  assert.match((await w.command('play', { row: oldRow })).error, /closed/);
  assert.equal(w.controls.length, 0);
  w.tabs.get(10).discarded = true;
  await w.refresh();
  assert.equal(w.rows().length, 0);
  w.tabs.get(10).discarded = false;
  await w.report([w.element('new')]);
  w.tabs.delete(10);
  await w.callbacks.removed(10);
  assert.equal(w.rows().length, 0);
});

test('a worker restart ignores the unversioned stale cache', async () => {
  const w = worker({ initialState: { frames: { '10:0': [{ id: 'ghost', playing: true }] } } });
  await w.settle();
  assert.equal(w.rows().length, 0);
});

test('opening a row focuses its tab and window without playback commands', async () => {
  const w = worker();
  await w.report([w.element('target')], { frameId: 7 });
  const result = await w.command('focus');
  assert.equal(result.ok, true);
  assert.deepEqual(w.focused, [{ tabId: 10, active: true }, { windowId: 3, focused: true }]);
  assert.equal(w.controls.length, 0);
  assert.equal(result.source.id, w.rows()[0].id);
  assert.ok(Number.isInteger(result.revision));
});

test('connection status requires a host handshake and clears on disconnect', async () => {
  const w = worker();
  await w.settle();
  assert.equal((await w.message({ type: 'status' })).connected, false);
  await w.refresh();
  assert.equal((await w.message({ type: 'status' })).connected, true);
  w.callbacks.disconnect();
  assert.equal((await w.message({ type: 'status' })).connected, false);
});


test('buffering and seeking do not report playing even when paused is false', async () => {
  const f = fixture();
  const media = f.media({ paused: false, readyState: 1 });
  f.setMedia([media]);
  assert.equal((await f.report())[0].playing, false);
  media.readyState = 4;
  media.seeking = true;
  assert.equal((await f.report())[0].playing, false);
  media.seeking = false;
  assert.equal((await f.report())[0].playing, true);
  f.emit('waiting', media);
  assert.equal((await f.report())[0].playing, false);
  f.emit('playing', media);
  assert.equal((await f.report())[0].playing, true);
});

test('inspecting a paused player never calls play or pause', async () => {
  const f = fixture();
  let controls = 0;
  const media = f.media({ play() { controls++; }, pause() { controls++; } });
  f.setMedia([media]);
  await f.report();
  const response = await f.command({ type: 'inspect' });
  assert.equal(response.ok, true);
  assert.equal(response.sources[0].playing, false);
  assert.equal(controls, 0);
});

test('a silent preview cannot mark a paused main player as playing on tab focus', async () => {
  const w = worker({ onFocus: media => {
    const preview = media.get('10:0').sources.find(source => source.id === 'preview');
    preview.playing = true;
  } });
  await w.report([w.element('main', { visible: true, area: 100000 }), w.element('preview', { muted: true })]);
  assert.equal(w.rows()[0].playing, false);
  const result = await w.command('focus');
  assert.equal(result.ok, true);
  assert.equal(result.source.playing, false);
  assert.equal(w.rows()[0].playing, false);
  assert.equal(w.controls.length, 0);
  assert.equal(w.inspections.length, 1);
});

test('focusing a tab refreshes stale playing state without a playback command', async () => {
  const w = worker({ onFocus: media => { media.get('10:0').sources[0].playing = false; } });
  await w.report([w.element('main', { playing: true })]);
  assert.equal(w.rows()[0].playing, true);
  const result = await w.command('focus');
  assert.equal(result.source.playing, false);
  assert.equal(w.controls.length, 0);
});

test('a muted selected player stays playing and real background audio can take over', async () => {
  const w = worker();
  await w.report([w.element('main', { playing: true, visible: true, area: 100000 })]);
  await w.report([w.element('main', { playing: true, muted: true, visible: true, area: 100000 })]);
  assert.equal(w.rows()[0].playing, true);
  assert.equal(w.rows()[0].muted, true);
  await w.report([w.element('main', { muted: true, visible: true, area: 100000 }), w.element('background', { playing: true })]);
  assert.equal(w.rows()[0].playing, true);
  assert.equal(w.rows()[0].muted, false);
});


test('SoundShelf master unmute preserves pre-existing element mute and zero volume', async () => {
  const w = worker();
  await w.report([w.element('main', { playing: true }), w.element('silent', { muted: true, volume: 0 })]);
  await w.command('mute', { value: 1, tabOnly: true });
  assert.equal(w.tabs.get(10).mutedInfo.muted, true);
  await w.command('mute', { value: 0, tabOnly: true, requestId: 'restore' });
  assert.equal(w.tabs.get(10).mutedInfo.muted, false);
  assert.equal(w.controls.length, 0);
});

test('commands validate only the target tab, without querying unrelated tabs', async () => {
  const w = worker();
  w.tabs.set(11, { id: 11, mutedInfo: { muted: false } });
  w.docs.set(11, [{ frameId: 0, parentFrameId: -1, documentId: 'top-11' }]);
  await w.report([w.element('target')]);
  await w.report([w.element('other')], { tabId: 11 });
  w.calls.length = 0;
  assert.equal((await w.command('play')).ok, true);
  assert.ok(w.calls.some(call => call.api === 'getAllFrames' && call.tabId === 10));
  assert.equal(w.calls.some(call => call.api === 'query' || call.tabId === 11), false);
});

test('target validation rejects navigation even before its event is delivered', async () => {
  const w = worker();
  await w.report([w.element('old')]);
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'replacement' }]);
  assert.match((await w.command('play')).error, /closed/);
  assert.equal(w.controls.length, 0);
  assert.equal(w.rows().length, 0);
});

test('a slow maintenance scan cannot block controls on a different tab', async () => {
  let release;
  const w = worker({ onGetAllFrames: tabId => tabId === 11 ? new Promise(resolve => { release = resolve; }) : undefined });
  w.tabs.set(11, { id: 11, mutedInfo: { muted: false } });
  w.docs.set(11, [{ frameId: 0, parentFrameId: -1, documentId: 'top-11' }]);
  await w.report([w.element('target')]);
  await w.report([w.element('other')], { tabId: 11 });
  await w.refresh();
  assert.equal(typeof release, 'function');
  // Repeated refresh messages must share the in-progress sweep.
  await w.refresh();
  await w.refresh();
  assert.equal((await w.command('play')).ok, true);
  assert.equal(w.controls.length, 1);
  assert.equal(w.calls.filter(call => call.api === 'getAllFrames' && call.tabId === 11).length, 1);
  release();
  await w.settle();
});

test('a maintenance scan cannot overwrite a newer report or resurrect a closed tab', async () => {
  let release;
  let block = false;
  const w = worker({ onGetAllFrames: () => block ? new Promise(resolve => { release = resolve; }) : undefined });
  await w.report([w.element('old')]);
  block = true;
  await w.refresh();
  assert.equal(typeof release, 'function');
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'replacement' }]);
  await w.report([w.element('new')]);
  release();
  await w.settle();
  assert.equal(w.rows()[0].id, 'tab:10:replacement');

  await w.refresh();
  w.tabs.delete(10);
  await w.callbacks.removed(10);
  await w.settle();
  release();
  await w.settle();
  assert.equal(w.rows().length, 0);
});

const mic = (state = 'enabled') => ({ title: 'Google Meet', state, capability: 'app-control', controllable: true });
function meetWorker(options) {
  const w = worker(options);
  w.tabs.get(10).url = 'https://meet.google.com/abc-defg-hij';
  return w;
}
test('Meet calls get independent sound and mic rows without an HTML player; focus sends no control commands', async () => {
  const w = meetWorker();
  await w.report([], { microphone: mic() });
  assert.equal(w.rows().length, 1);
  assert.equal(w.rows()[0].supportsPlayback, false);
  assert.equal(w.microphoneRows().length, 1);
  const row = w.microphoneRows()[0];
  assert.equal(row.state, 'enabled');
  assert.equal((await w.command('focus', { row, microphoneSource: true })).ok, true);
  assert.equal(w.controls.length, 0);
  assert.equal(w.microphoneRows()[0].state, 'enabled');
});
test('microphone commands use call control, confirm state, and leave sound untouched', async () => {
  const w = meetWorker();
  w.tabs.get(10).audible = true;
  await w.report([w.element('player', { playing: true })], { microphone: mic() });
  const row = w.microphoneRows()[0];
  assert.equal((await w.command('microphone', { row, value: 1 })).ok, true);
  assert.equal(w.microphoneRows()[0].state, 'disabled');
  assert.equal(w.rows()[0].playing, true);
  assert.equal(w.rows()[0].muted, false);
  assert.equal(w.focused.length, 0);
  assert.equal((await w.command('microphone', { row, value: 0, requestId: 'unmute' })).ok, true);
  assert.equal(w.microphoneRows()[0].state, 'enabled');
});
test('unknown, incomplete and foreign-site microphone reports cannot authorize control', async () => {
  const w = meetWorker();
  await w.report([], { microphone: { ...mic(), state: 'unknown' } });
  assert.equal(w.microphoneRows()[0].state, 'unknown');
  assert.match((await w.command('microphone', { row: w.microphoneRows()[0], value: 1 })).error, /unavailable/);
  assert.equal(w.controls.length, 0);
  await w.report([], { microphone: mic() });
  await w.report([], { frameId: 7, microphone: mic('disabled') });
  assert.equal(w.microphoneRows().length, 1);
  assert.equal(w.microphoneRows()[0].state, 'unknown');
  const foreign = worker();
  await foreign.report([], { microphone: mic() });
  assert.equal(foreign.microphoneRows().length, 0);
});
test('app-side mute, unavailable integration, navigation and closed tabs update mic rows', async () => {
  const w = meetWorker();
  await w.report([], { microphone: mic() });
  const row = w.microphoneRows()[0];
  await w.report([], { microphone: mic('disabled') });
  assert.equal(w.microphoneRows()[0].state, 'disabled');
  await w.report([]);
  assert.equal(w.microphoneRows()[0].state, 'unknown');
  w.docs.get(10)[0].documentId = 'replacement';
  assert.match((await w.command('microphone', { row, value: 1 })).error, /closed/);
  assert.equal(w.controls.length, 0);
  await w.report([], { microphone: mic() });
  w.tabs.delete(10);
  w.callbacks.removed(10);
  await w.settle();
  assert.equal(w.microphoneRows().length, 0);
});
test('failed microphone commands return an error and refresh the observed state', async () => {
  const w = meetWorker({ failMicrophone: true });
  await w.report([], { microphone: mic() });
  const result = await w.command('microphone', { row: w.microphoneRows()[0], value: 1 });
  assert.match(result.error, /rejected/);
  assert.equal(w.microphoneRows()[0].state, 'enabled');
  assert.ok(w.inspections.length >= 2);
});

function microphoneFixture({ host = 'meet.google.com', path = '/abc-defg-hij', muted = false,
  call = true, duplicate = false, click = true, disabled = false } = {}) {
  let current = muted;
  let label = null;
  let present = true;
  let clicks = 0;
  const makeButton = attrs => ({ isConnected: true, disabled: false,
    getClientRects: () => [1], closest: () => null,
    hasAttribute: key => attrs[key] !== undefined,
    getAttribute: key => attrs[key] ?? null });
  const button = makeButton({ 'data-is-muted': 'false' });
  button.disabled = disabled;
  button.getAttribute = key => key === 'data-is-muted' ? String(current) : key === 'aria-label' ?
    label ?? `Turn ${current ? 'on' : 'off'} microphone (⌘ + d)` : null;
  button.click = () => { clicks++; if (click) current = !current; };
  const leave = makeButton({ 'aria-label': 'Leave call' });
  const context = vm.createContext({ location: { hostname: host, pathname: path }, Date, setTimeout,
    document: { querySelectorAll: () => [...(present ? [button] : []), ...(call ? [leave] : []), ...(duplicate ? [button] : [])] } });
  vm.runInContext(fs.readFileSync('BrowserExtension/microphone.js', 'utf8'), context);
  return { api: context.__soundShelfMic, button, clicks: () => clicks,
    setMuted(value) { current = value; }, setLabel(value) { label = value; }, remove() { present = false; } };
}
test('Meet adapter verifies two state signals and uses only the app mute control', async () => {
  const f = microphoneFixture();
  assert.equal(f.api.inspect().state, 'enabled');
  await f.api.setMuted(true);
  assert.equal(f.api.inspect().state, 'disabled');
  await f.api.setMuted(true);
  assert.equal(f.clicks(), 1);
  await f.api.setMuted(false);
  assert.equal(f.api.inspect().state, 'enabled');
  f.setMuted(true);
  assert.equal(f.api.inspect().state, 'disabled');
  f.setLabel('Turn off microphone');
  assert.equal(f.api.inspect().state, 'unknown');
  await assert.rejects(f.api.setMuted(false), /unavailable/);
});
test('Meet requires a live call, unambiguous controls, enabled button and known locale', async () => {
  for (const options of [{ call: false }, { duplicate: true }, { disabled: true }]) {
    const f = microphoneFixture(options);
    assert.equal(f.api.inspect().state, 'unknown');
    await assert.rejects(f.api.setMuted(true), /unavailable/);
    assert.equal(f.clicks(), 0);
  }
  const f = microphoneFixture();
  f.setLabel('Microphone');
  assert.equal(f.api.inspect().controllable, false);
  f.remove();
  assert.equal(f.api.inspect().state, 'unknown');
  const d = microphoneFixture({ host: 'discord.com', path: '/channels/@me' });
  assert.equal(d.api.inspect().state, 'unknown');
  await assert.rejects(d.api.setMuted(true), /unavailable/);
});
test('microphone adapter rejects rapid commands and times out without inventing success', async () => {
  const f = microphoneFixture({ click: false });
  const pending = f.api.setMuted(true);
  await assert.rejects(f.api.setMuted(true), /pending/);
  await assert.rejects(pending, /did not confirm/);
  assert.equal(f.api.inspect().state, 'enabled');
  assert.equal(f.clicks(), 1);
});

test('cached microphone observations expire and never authorize a command after restart', async () => {
  const w = meetWorker({ initialState: { mediaStateV4: {
    frames: { '10:0': { tabId: 10, frameId: 0, parentFrameId: -1, documentId: 'top-10', topDocumentId: 'top-10',
      sequence: 3, sources: [], microphone: mic(), observedAt: Date.now() - 20000 } },
    tabInfo: { 10: { documentId: 'top-10', muted: false } }
  } } });
  await w.settle();
  assert.equal(w.microphoneRows()[0].state, 'unknown');
  assert.equal(w.microphoneRows()[0].controllable, false);
  assert.match((await w.command('microphone', { row: w.microphoneRows()[0], value: 1 })).error, /unavailable/);
  assert.equal(w.controls.length, 0);
});

test('content script routes mic-only commands independently and returns observed microphone state', async () => {
  let state = 'enabled', commands = 0;
  const f = fixture({ microphone: {
    inspect: () => mic(state),
    async setMuted(muted) { commands++; state = muted ? 'disabled' : 'enabled'; }
  } });
  await f.report();
  assert.equal(f.reports.at(-1).microphone.state, 'enabled');
  const result = await f.command({ action: 'microphone', value: 1 });
  assert.equal(result.ok, true);
  assert.equal(result.microphone.state, 'disabled');
  assert.equal(result.sources.length, 0);
  const invalid = await f.command({ action: 'microphone', value: 7 });
  assert.match(invalid.error, /Invalid/);
  assert.equal(commands, 1);
});

test('Chrome title changes update row details immediately without a new media report', async () => {
  const w = worker();
  w.tabs.get(10).title = 'First product';
  w.tabs.get(10).url = 'https://www.amazon.in/product/one';
  await w.report([w.element('player', { title: 'Old embedded player label', site: 'video-cdn.test' })]);
  const original = w.rows()[0];
  assert.equal(original.tabTitle, 'First product');
  assert.equal(original.site, 'www.amazon.in');
  w.tabs.get(10).title = 'Second product';
  w.callbacks.updated(10, { title: 'Second product' }, structuredClone(w.tabs.get(10)));
  await w.settle();
  assert.equal(w.rows()[0].tabTitle, 'Second product');
  assert.equal(w.rows()[0].id, original.id);
  assert.equal(w.rows()[0].playing, original.playing);
  assert.equal(w.controls.length, 0);
});
test('top-page site names survive iframe reports and tabs with identical labels stay distinct', async () => {
  const w = worker();
  await w.report([w.element('main')], { siteName: '  Fresh   Store  ' });
  await w.report([w.element('embedded', { playing: true })], { frameId: 7, siteName: 'Video CDN' });
  assert.equal(w.rows()[0].siteName, 'Fresh Store');
  w.tabs.set(11, { id: 11, windowId: 3, url: 'https://fresh.example', title: 'Another item', mutedInfo: { muted: false } });
  w.docs.set(11, [{ frameId: 0, parentFrameId: -1, documentId: 'top-11', documentLifecycle: 'active' }]);
  await w.report([w.element('other')], { tabId: 11, siteName: 'Fresh Store' });
  assert.equal(w.rows().length, 2);
  assert.notEqual(w.rows()[0].id, w.rows()[1].id);
});
test('content reports refresh page titles and site metadata for newly loaded media', async () => {
  const f = fixture();
  f.document.title = 'New product tab';
  f.document.querySelector = () => ({ getAttribute: () => '  New   Shop  ' });
  f.setMedia([f.media({})]);
  await f.report();
  assert.equal(f.reports.at(-1).sources[0].title, 'New product tab');
  assert.equal(f.reports.at(-1).siteName, 'New Shop');
  f.document.title = 'Product tab after navigation';
  await f.report();
  assert.equal(f.reports.at(-1).sources[0].title, 'Product tab after navigation');
});

test('YouTube to a silent shopping page in the same tab removes the row instead of renaming it', async () => {
  const w = worker();
  Object.assign(w.tabs.get(10), { url: 'https://www.youtube.com/watch?v=one', title: 'A video', audible: true });
  const youtube = fixture({ sendMessage: message => w.report(message.sources, { sequence: message.sequence }) });
  youtube.setMedia([youtube.media({ controls: false, paused: false })]);
  await youtube.report();
  assert.equal(w.rows().length, 1);
  const oldRow = w.rows()[0];
  const oldDocument = 'top-10';
  Object.assign(w.tabs.get(10), { url: 'https://www.amazon.in', title: 'Online Shopping', audible: false });
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'amazon-document', documentLifecycle: 'active' }]);
  w.callbacks.navigate({ tabId: 10, frameId: 0, documentId: 'amazon-document' });
  await w.settle();
  assert.equal(w.rows().length, 0);
  const shopping = fixture({ sendMessage: message => w.report(message.sources, { sequence: message.sequence }) });
  shopping.setMedia([
    shopping.media({ controls: false, readyState: 0 }),
    shopping.media({ controls: false, paused: true, currentTime: 10 }),
    shopping.media({ controls: false, paused: false, muted: true })
  ]);
  await shopping.report();
  assert.equal(w.rows().length, 0);
  assert.equal((await w.report([w.element('old-youtube', { playing: true })], { documentId: oldDocument })).ok, false);
  assert.equal(w.rows().length, 0);
  assert.match((await w.command('play', { row: oldRow })).error, /closed/);
  assert.equal(w.controls.length, 0);
});
test('a custom player is admitted on sound, stays when paused, and does not carry over to the next document', async () => {
  const w = worker();
  await w.report([w.element('custom', { userFacing: false, playing: true })]);
  assert.equal(w.rows().length, 0);
  w.tabs.get(10).audible = true;
  w.callbacks.updated(10, { audible: true }, structuredClone(w.tabs.get(10)));
  await w.settle();
  assert.equal(w.rows().length, 1);
  w.tabs.get(10).audible = false;
  await w.report([w.element('custom', { userFacing: false, playing: false })]);
  assert.equal(w.rows().length, 1);
  assert.equal(w.rows()[0].playing, false);
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'next-page' }]);
  // A new document must not inherit admission even with a reused element ID.
  await w.report([w.element('custom', { userFacing: false, playing: false })]);
  assert.equal(w.rows().length, 0);
});
test('the previous page sound indicator cannot immediately admit a silent video after navigation', async () => {
  const w = worker();
  w.tabs.get(10).audible = true;
  await w.report([w.element('music', { playing: true, userFacing: false })]);
  assert.equal(w.rows().length, 1);
  w.docs.set(10, [{ frameId: 0, parentFrameId: -1, documentId: 'new-store' }]);
  w.callbacks.navigate({ tabId: 10, frameId: 0, documentId: 'new-store' });
  await w.settle();
  await w.report([w.element('silent-banner', { playing: true, userFacing: false })]);
  assert.equal(w.rows().length, 0);
  w.tabs.get(10).audible = false;
  w.callbacks.updated(10, { audible: false }, structuredClone(w.tabs.get(10)));
  await w.settle();
  assert.equal(w.rows().length, 0);
});
test('unloaded and failed resources are excluded; hidden/silent background media is not an explicit player', async () => {
  const f = fixture();
  f.setMedia([f.media({ readyState: 0 }), f.media({ error: { code: 4 } })]);
  assert.equal((await f.report()).length, 0);
  f.setMedia([
    f.media({ controls: false, paused: false, muted: true }),
    f.media({ controls: true, getClientRects: () => [] }),
    f.media({ controls: true })
  ]);
  const sources = await f.report();
  assert.equal(sources[0].userFacing, false);
  assert.equal(sources[1].userFacing, false);
  assert.equal(sources[2].userFacing, true);
});
test('replacing a resource in the same media element rotates its identity', async () => {
  const f = fixture();
  const media = f.media({ controls: false, src: 'https://example.test/song.mp3' });
  f.setMedia([media]);
  const oldID = (await f.report())[0].id;
  media.src = 'https://example.test/silent-banner.mp4';
  const newID = (await f.report())[0].id;
  assert.notEqual(newID, oldID);
  assert.equal((await f.report())[0].id, newID);
});

test('a loaded custom Media Session player remains discoverable before playback', async () => {
  const f = fixture({ navigator: { mediaSession: { metadata: { title: 'An album' } } } });
  f.setMedia([f.media({ controls: false, paused: true })]);
  const sources = await f.report();
  assert.equal(sources.length, 1);
  assert.equal(sources[0].userFacing, true);
  assert.equal(sources[0].playing, false);
});
test('old admission-free caches cannot resurrect a silent page after an extension update', async () => {
  const w = worker({ initialState: { mediaStateV3: {
    frames: { '10:0': { tabId: 10, frameId: 0, documentId: 'top-10', sequence: 5,
      sources: [{ id: 'silent-video', title: 'Shopping', site: 'example.test', playing: false, ready: false, volume: 1, muted: false }] } },
    tabInfo: { 10: { documentId: 'top-10', muted: false } }
  } } });
  await w.settle();
  assert.equal(w.rows().length, 0);
});

test('Meet sound silence and restore work without a media element and leave the mic unchanged', async () => {
  const w = meetWorker();
  await w.report([], { microphone: mic('disabled') });
  assert.equal(w.rows().length, 1);
  assert.equal(w.rows()[0].supportsPlayback, false);
  assert.equal((await w.command('mute', { value: 1 })).ok, true);
  assert.equal(w.rows()[0].muted, true);
  assert.equal(w.microphoneRows()[0].state, 'disabled');
  assert.equal((await w.command('mute', { value: 0, requestId: 'restore-call' })).ok, true);
  assert.equal(w.rows()[0].muted, false);
  assert.equal(w.microphoneRows()[0].state, 'disabled');
  assert.equal(w.controls.length, 0);
});
test('Meet sound restore preserves its muted local camera preview and rejects playback commands', async () => {
  const w = meetWorker();
  await w.report([w.element('self-preview', { muted: true, volume: 0 })], { microphone: mic() });
  // A muted preview is not evidence that incoming call sound is silenced.
  assert.equal(w.rows()[0].muted, false);
  assert.equal((await w.command('mute', { value: 1 })).ok, true);
  assert.equal((await w.command('mute', { value: 0, requestId: 'restore' })).ok, true);
  assert.equal(w.controls.length, 0);
  assert.equal(w.microphoneRows()[0].state, 'enabled');
  for (const action of ['play', 'pause', 'volume']) {
    assert.match((await w.command(action, { requestId: action })).error, /silencing only/);
  }
  assert.equal(w.controls.length, 0);
});
test('Meet call sound remains controllable when mic state is unknown, and disappears after the call ends', async () => {
  const w = meetWorker();
  const unknown = { title: 'Google Meet', state: 'unknown', capability: 'unavailable', controllable: false, callActive: true };
  await w.report([], { microphone: unknown });
  assert.equal(w.rows().length, 1);
  assert.equal(w.microphoneRows()[0].state, 'unknown');
  assert.equal((await w.command('mute', { value: 1 })).ok, true);
  assert.equal(w.microphoneRows()[0].state, 'unknown');
  await w.report([], { microphone: { ...unknown, callActive: false } });
  assert.equal(w.rows().length, 0);
});

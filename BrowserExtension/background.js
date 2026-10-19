const HOST = 'com.soundshelf.bridge';
let port = null;
let bridgeReady = false;
let connectionError = 'Not connected. Install the native bridge, then reconnect.';
let frames = {};
let tabInfo = {};
let soundEpochs = {};
let revision = 0;
const tabVersions = new Map();
// Old caches predate sound-source admission and top-document provenance.
const loaded = chrome.storage.session.get('mediaStateV4').then(state => {
  frames = state.mediaStateV4?.frames || {};
  tabInfo = state.mediaStateV4?.tabInfo || {};
  soundEpochs = state.mediaStateV4?.soundEpochs || {};
});
let queue = Promise.resolve();
function enqueue(work) {
  const result = queue.then(() => loaded).then(work);
  queue = result.catch(() => {});
  return result;
}
// Chrome's audible indicator can briefly outlive navigation. A new document
// must either observe quiet first or sustain sound beyond that trailing window.
function currentSound(tab, documentId) {
  let epoch = soundEpochs[tab.id];
  if (!epoch || epoch.documentId !== documentId) {
    const replacing = Boolean(epoch || tabInfo[tab.id]);
    epoch = soundEpochs[tab.id] = { documentId, settleUntil: replacing ? Date.now() + 4000 : 0, quiet: false };
  }
  if (!tab.audible) epoch.quiet = true;
  return tab.audible === true && (epoch.quiet || Date.now() >= epoch.settleUntil);
}
function candidates(tabId) {
  return Object.values(frames).filter(frame => frame.tabId === tabId).flatMap(frame =>
    frame.sources.map(source => ({ ...source, frameId: frame.frameId, documentId: frame.documentId })));
}
function primary(tabId) {
  const preferred = tabInfo[tabId]?.preferredId;
  return candidates(tabId).filter(source => source.admitted === true).sort((a, b) =>
    // Silent preview videos must not displace the paused player the user chose.
    Number(b.playing && !b.muted && b.volume > 0) - Number(a.playing && !a.muted && a.volume > 0) ||
    Number(b.id === preferred) - Number(a.id === preferred) ||
    Number(b.visible) - Number(a.visible) || (b.area || 0) - (a.area || 0) ||
    Number(b.playing) - Number(a.playing) ||
    Number(!b.ready) - Number(!a.ready) || a.id.localeCompare(b.id))[0];
}
function tabHostname(url) {
  try { return new URL(url).hostname; } catch { return undefined; }
}
function sourceForTab(tabId) {
  const player = primary(tabId), info = tabInfo[tabId];
  if (!info?.documentId) return undefined;
  const callFrame = frames[`${tabId}:0`];
  const call = tabHostname(info.url) === 'meet.google.com' && callFrame?.microphone?.callActive === true &&
    Date.now() - callFrame.observedAt < 12000;
  if (call) {
    // Meet owns its audio pipeline. Tab silence covers all frames and Web Audio
    // without touching microphone controls or the muted local camera preview.
    return { id: `tab:${tabId}:${info.documentId}`, tabId, frameId: 0,
      title: info.title || 'Google Meet', tabTitle: info.title || 'Google Meet', site: 'meet.google.com',
      siteName: 'Google Meet', playing: Boolean(info.audible), ready: false,
      supportsPlayback: false, volume: 1, muted: Boolean(info.muted) };
  }
  if (!player) return undefined;
  return {
    id: `tab:${tabId}:${info.documentId}`, tabId, frameId: player.frameId,
    title: player.title, tabTitle: info.title || player.title,
    site: tabHostname(info.url) || player.site,
    siteName: frames[`${tabId}:0`]?.siteName || undefined,
    playing: player.playing, ready: player.ready,
    supportsPlayback: !/^https:\/\/(meet\.google\.com|discord\.com)\//.test(info.url || ''),
    volume: player.volume,
    // Tab mute includes future elements and Web Audio, not just today's primary element.
    muted: Boolean(info.muted) || player.muted || player.volume === 0
  };
}
function sources() {
  return Object.keys(tabInfo).map(Number).sort((a, b) => a - b).map(sourceForTab).filter(Boolean);
}
// Mic rows do not require an HTML media player. Only the top-document call
// adapter owns tab-wide control; embedded/unknown sources make coverage unknown.
function microphoneForTab(tabId) {
  const info = tabInfo[tabId];
  if (!info?.documentId) return undefined;
  const all = Object.values(frames).filter(frame => frame.tabId === tabId && frame.microphone);
  if (!all.length) return undefined;
  const top = all.find(frame => frame.frameId === 0);
  const verified = all.length === 1 && top && top.microphone.capability === 'app-control' &&
    top.microphone.controllable && Date.now() - top.observedAt < 12000;
  const microphone = top?.microphone || all[0].microphone;
  return { id: `tab:${tabId}:${info.documentId}`, tabId, frameId: top?.frameId ?? all[0].frameId,
    title: microphone.title, subtitle: info.title || microphone.title,
    capability: verified ? 'app-control' : 'unavailable',
    state: verified ? microphone.state : 'unknown', controllable: Boolean(verified) };
}
function microphones() {
  return Object.keys(tabInfo).map(Number).sort((a, b) => a - b).map(microphoneForTab).filter(Boolean);
}
function publish() {
  if (!port) return;
  try { port.postMessage({ type: 'snapshot', revision, sources: sources(), microphones: microphones() }); }
  catch { port = null; bridgeReady = false; }
}
async function changed(tabId) {
  revision += 1;
  tabVersions.set(tabId, (tabVersions.get(tabId) || 0) + 1);
  const player = primary(tabId);
  if (player) tabInfo[tabId].preferredId = player.id;
  await chrome.storage.session.set({ mediaStateV4: { frames, tabInfo, soundEpochs } });
  publish();
}
function removeFrames(tabId, frameId = 0) {
  const removed = new Set([frameId]);
  let count;
  do {
    count = removed.size;
    for (const frame of Object.values(frames)) {
      if (frame.tabId === tabId && removed.has(frame.parentFrameId)) removed.add(frame.frameId);
    }
  } while (count !== removed.size);
  for (const [key, frame] of Object.entries(frames)) {
    if (frame.tabId === tabId && (frameId === 0 || removed.has(frame.frameId))) delete frames[key];
  }
}
async function readTab(tabId) {
  let tab, current;
  try {
    [tab, current] = await Promise.all([
      chrome.tabs.get(tabId), chrome.webNavigation.getAllFrames({ tabId })
    ]);
  } catch { current = []; }
  return { tab, current };
}
async function applyTab(tabId, { tab, current }) {
  let dirty = false;
  const docs = new Map((current || []).filter(frame => !frame.errorOccurred &&
    (!frame.documentLifecycle || frame.documentLifecycle === 'active')).map(frame => [frame.frameId, frame]));
  const top = docs.get(0);
  if (!tab || tab.discarded || !top) {
    dirty = Boolean(tabInfo[tabId]) || Object.values(frames).some(frame => frame.tabId === tabId);
    removeFrames(tabId); delete tabInfo[tabId];
  } else {
    for (const [key, frame] of Object.entries(frames)) {
      if (frame.tabId === tabId && (docs.get(frame.frameId)?.documentId !== frame.documentId ||
          frame.topDocumentId !== top.documentId)) {
        delete frames[key]; dirty = true;
      }
    }
    // Chrome's sound indicator is independent of DOM play/pause. A silent
    // autoplay video is not evidence that this new page is an audio source.
    if (currentSound(tab, top.documentId)) {
      for (const frame of Object.values(frames).filter(frame => frame.tabId === tabId)) {
        for (const source of frame.sources) {
          if (!source.admitted && source.playing && !source.muted && source.volume > 0) {
            source.admitted = true;
            dirty = true;
          }
        }
      }
    }
    if (tabInfo[tabId]?.documentId !== top.documentId || tabInfo[tabId]?.muted !== Boolean(tab.mutedInfo?.muted) ||
        tabInfo[tabId]?.audible !== Boolean(tab.audible) || tabInfo[tabId]?.title !== tab.title || tabInfo[tabId]?.url !== tab.url) dirty = true;
    tabInfo[tabId] = { ...tabInfo[tabId], documentId: top.documentId, muted: Boolean(tab.mutedInfo?.muted), audible: Boolean(tab.audible), title: tab.title, url: tab.url };
  }
  if (dirty) await changed(tabId);
}
// Called within the state queue. A command validates only its own tab and frames.
async function reconcileTab(tabId) {
  await applyTab(tabId, await readTab(tabId));
}
let reconciliation = null;
function reconcile() {
  // Browser I/O for maintenance happens outside the state queue. Version checks
  // prevent a scan from overwriting reports or navigation that arrived meanwhile.
  if (!reconciliation) {
    reconciliation = (async () => {
      const ids = await enqueue(() => Object.keys(tabInfo).map(Number));
      for (const id of ids) {
        const version = await enqueue(() => tabVersions.get(id) || 0);
        const state = await readTab(id);
        await enqueue(() => {
          if ((tabVersions.get(id) || 0) === version) return applyTab(id, state);
        });
      }
      await enqueue(publish);  // Also heartbeat an empty connection.
    })().finally(() => { reconciliation = null; });
  }
  return reconciliation;
}
function sanitizeMicrophone(value, url) {
  if (!value || !['Google Meet', 'Discord'].includes(value.title)) return null;
  if (value.title === 'Google Meet' && !/^https:\/\/meet\.google\.com\//.test(url || '')) return null;
  if (value.title === 'Discord' && !/^https:\/\/discord\.com\//.test(url || '')) return null;
  const verified = value.capability === 'app-control' && value.controllable === true &&
    ['enabled', 'disabled'].includes(value.state);
  return { title: value.title, capability: verified ? 'app-control' : 'unavailable',
    state: verified ? value.state : 'unknown', controllable: verified,
    callActive: value.title === 'Google Meet' && (value.callActive === true || verified) };
}
async function acceptReport(message, sender) {
  if (!sender.documentId || (sender.documentLifecycle && sender.documentLifecycle !== 'active')) return false;
  // A late report must never recreate a document that has navigated or detached.
  let current, top, tab;
  try {
    current = await chrome.webNavigation.getFrame({ tabId: sender.tab.id, frameId: sender.frameId });
    top = sender.frameId === 0 ? current : await chrome.webNavigation.getFrame({ tabId: sender.tab.id, frameId: 0 });
    tab = await chrome.tabs.get(sender.tab.id);
  } catch { return false; }
  if (tab.discarded || !current || current.documentId !== sender.documentId || !top ||
      (current.documentLifecycle && current.documentLifecycle !== 'active')) return false;
  const key = `${sender.tab.id}:${sender.frameId}`, previous = frames[key];
  const sequence = Number(message.sequence);
  if (!Number.isSafeInteger(sequence) || sequence < 1) return false;
  if (previous?.documentId === current.documentId && sequence <= previous.sequence) return false;
  if (tabInfo[sender.tab.id]?.documentId !== top.documentId) removeFrames(sender.tab.id);
  const sound = currentSound(tab, top.documentId);
  const unique = new Map();
  for (const source of (Array.isArray(message.sources) ? message.sources : []).slice(0, 100)) {
    if (typeof source.id !== 'string' || typeof source.title !== 'string' || typeof source.site !== 'string' ||
        typeof source.playing !== 'boolean' || typeof source.ready !== 'boolean' ||
        typeof source.muted !== 'boolean' || !Number.isFinite(source.volume)) continue;
    const known = previous?.documentId === current.documentId && previous.topDocumentId === top.documentId &&
      previous.sources.some(item => item.id === source.id && item.admitted === true);
    const audible = sound && source.playing && !source.muted && source.volume > 0;
    unique.set(source.id, { ...source, admitted: source.userFacing === true || Boolean(known) || audible });
  }
  frames[key] = { tabId: sender.tab.id, frameId: sender.frameId, parentFrameId: current.parentFrameId,
    documentId: current.documentId, topDocumentId: top.documentId, sequence, sources: [...unique.values()], observedAt: Date.now(),
    siteName: typeof message.siteName === 'string' ? message.siteName.replace(/\s+/g, ' ').trim().slice(0, 80) : undefined,
    microphone: sanitizeMicrophone(message.microphone, tab.url) ||
      (previous?.documentId === current.documentId && previous.microphone ?
        { ...previous.microphone, state: 'unknown', capability: 'unavailable', controllable: false, callActive: false } : null) };
  tabInfo[sender.tab.id] = { ...tabInfo[sender.tab.id], documentId: top.documentId,
    muted: Boolean(tab.mutedInfo?.muted), audible: Boolean(tab.audible), title: tab.title, url: tab.url };
  await changed(sender.tab.id);
  return true;
}
async function sendControl(tabId, target, command) {
  const response = await chrome.tabs.sendMessage(tabId, { ...command, type: 'control', id: target.id },
    { frameId: target.frameId, documentId: target.documentId });
  if (!response?.ok) throw new Error(response?.error || 'Player did not respond.');
  await enqueue(async () => {
    const tab = await chrome.tabs.get(tabId);
    const accepted = await acceptReport(response, { tab, frameId: target.frameId, documentId: target.documentId });
    if (!accepted) {
      await reconcileTab(tabId);
      if (frames[`${tabId}:${target.frameId}`]?.documentId !== target.documentId) {
        throw new Error('The page changed. Please try again.');
      }
    }
  });
}
async function inspectPlayers(tabId) {
  const targets = await enqueue(() => Object.values(frames).filter(frame => frame.tabId === tabId));
  for (const target of targets) {
    try {
      const response = await chrome.tabs.sendMessage(tabId, { type: 'inspect' },
        { frameId: target.frameId, documentId: target.documentId });
      if (response?.ok) await enqueue(async () => {
        const tab = await chrome.tabs.get(tabId);
        await acceptReport(response, { tab, frameId: target.frameId, documentId: target.documentId });
      });
    } catch {
      await enqueue(async () => {
        const frame = frames[`${tabId}:${target.frameId}`];
        if (frame?.documentId === target.documentId && frame.microphone) {
          frame.microphone = { ...frame.microphone, state: 'unknown', capability: 'unavailable', controllable: false, callActive: false };
          await changed(tabId);
        }
        await reconcileTab(tabId);
      });
    }
  }
}
const controlQueues = new Map();
function control(command, replyPort) {
  const previous = controlQueues.get(command.tabId) || Promise.resolve();
  const work = previous.catch(() => {}).then(async () => {
    try {
      const selected = await enqueue(async () => {
        await reconcileTab(command.tabId);
        const row = command.action === 'microphone' || command.microphoneSource ? microphoneForTab(command.tabId) : sourceForTab(command.tabId);
        if (!row || row.id !== command.id) throw new Error('This tab or player has closed.');
        return { row, player: primary(row.tabId), all: candidates(row.tabId) };
      });
      if (command.action === 'focus') {
        const tab = await chrome.tabs.update(selected.row.tabId, { active: true });
        await chrome.windows.update(tab.windowId, { focused: true });
        // Read state after activation, without ever sending a playback command.
        await inspectPlayers(selected.row.tabId);
      } else if (command.action === 'microphone') {
        if (command.value !== 0 && command.value !== 1) throw new Error('Invalid microphone state.');
        // Refresh before deciding: stale state never authorizes a click.
        await inspectPlayers(command.tabId);
        const target = await enqueue(() => {
          const row = microphoneForTab(command.tabId);
          if (!row || row.id !== command.id || !row.controllable) throw new Error('Microphone control unavailable.');
          const frame = frames[`${command.tabId}:${row.frameId}`];
          return { id: row.id, frameId: row.frameId, documentId: frame.documentId };
        });
        await sendControl(command.tabId, target, command);
        const actual = await enqueue(() => microphoneForTab(command.tabId));
        if (!actual?.controllable || actual.state !== (command.value === 1 ? 'disabled' : 'enabled')) {
          throw new Error('The call did not confirm the microphone change.');
        }
      } else if (command.action === 'mute') {
        // On unmute also clear element-level mute, otherwise the tab can stay silent.
        if (command.value === 0 && !command.tabOnly && selected.row.supportsPlayback !== false) {
          for (const item of selected.all.filter(item => item.muted || item.volume === 0)) {
            await sendControl(selected.row.tabId, item, { action: 'mute', value: 0 });
          }
        }
        const tab = await chrome.tabs.update(selected.row.tabId, { muted: command.value === 1 });
        await enqueue(async () => {
          if (tabInfo[tab.id]) tabInfo[tab.id].muted = Boolean(tab.mutedInfo?.muted);
          await changed(tab.id);
        });
      } else if (command.action === 'pause') {
        if (selected.row.supportsPlayback === false) throw new Error('This call supports sound silencing only.');
        // A single tab can have multiple simultaneous elements or embedded players.
        const playing = selected.all.filter(item => item.playing);
        for (const target of playing) await sendControl(selected.row.tabId, target, { action: 'pause' });
      } else if (command.action === 'play' || command.action === 'volume') {
        if (!selected.player || selected.row.supportsPlayback === false) throw new Error('This call supports sound silencing only.');
        await sendControl(selected.row.tabId, selected.player, command);
      } else { throw new Error('Unsupported player command.'); }
      const result = await enqueue(() => { publish(); return { source: command.action === 'microphone' || command.microphoneSource ? microphoneForTab(command.tabId) : sourceForTab(command.tabId), revision }; });
      if (!result.source || result.source.id !== command.id) throw new Error('The page changed. Please try again.');
      replyPort.postMessage({ type: 'result', requestId: command.requestId, ok: true, ...result });
    } catch (error) {
      if (command.action === 'microphone') await inspectPlayers(command.tabId).catch(() => {});
      try { replyPort.postMessage({ type: 'result', requestId: command.requestId, error: error.message }); }
      catch { /* The originating connection closed. Never acknowledge on a different port. */ }
    }
  });
  controlQueues.set(command.tabId, work);
  work.finally(() => { if (controlQueues.get(command.tabId) === work) controlQueues.delete(command.tabId); });
}
async function connect() {
  await loaded;
  if (port) { publish(); return; }
  try {
    const connected = chrome.runtime.connectNative(HOST);
    port = connected; bridgeReady = false; connectionError = '';
    connected.onMessage.addListener(message => {
      if (port !== connected) return;
      bridgeReady = true;
      if (message.type === 'refresh') reconcile().catch(() => {});
      if (message.type === 'command') control(message, connected);
    });
    connected.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message || 'Bridge disconnected.';
      if (port === connected) { port = null; bridgeReady = false; connectionError = error; }
    });
    publish();
  } catch (error) { port = null; bridgeReady = false; connectionError = error.message; }
}
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message.type === 'reconnect') {
    reconcile().then(connect).then(() => respond({ ok: true }), error => respond({ error: error.message }));
    return true;
  }
  if (message.type === 'status') {
    respond({ connected: bridgeReady, error: connectionError || 'Waiting for the native bridge…', players: sources().length });
    return;
  }
  if (message.type !== 'media' || !sender.tab || sender.id !== chrome.runtime.id) return;
  enqueue(() => acceptReport(message, sender)).then(ok => { if (!port) connect(); respond({ ok }); }, () => respond({ ok: false }));
  return true;
});
chrome.tabs.onRemoved.addListener(tabId => enqueue(async () => {
  removeFrames(tabId); delete tabInfo[tabId]; delete soundEpochs[tabId]; await changed(tabId);
}));
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (!['discarded', 'mutedInfo', 'title', 'url', 'audible'].some(key => key in change)) return;
  // Read current Chrome state and document identity, rather than trusting a
  // possibly delayed event's tab object. Title changes do not need media events.
  enqueue(() => reconcileTab(tabId));
});
chrome.webNavigation.onCommitted.addListener(details => enqueue(async () => {
  removeFrames(details.tabId, details.frameId);
  if (details.frameId === 0) {
    delete tabInfo[details.tabId];
    soundEpochs[details.tabId] = { documentId: details.documentId, settleUntil: Date.now() + 4000, quiet: false };
  }
  await changed(details.tabId);
}));
async function bootstrap() {
  await reconcile();
  await connect();
  for (const tab of await chrome.tabs.query({})) {
    if (!/^https?:/.test(tab.url || '') || tab.discarded) continue;
    try { await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: ['microphone.js', 'content.js'] }); }
    catch { /* Browser-restricted pages cannot be inspected. */ }
  }
}
chrome.alarms.create('reconnect', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(() => reconcile().then(connect).catch(() => {}));
bootstrap().catch(() => {});

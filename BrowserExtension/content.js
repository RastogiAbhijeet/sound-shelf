(() => {
  if (globalThis.__soundShelf?.version === 6) { globalThis.__soundShelf.report(); return; }
  globalThis.__soundShelf?.dispose?.();
  const documentID = crypto.randomUUID();
  const ids = new WeakMap();
  const sourceKeys = new WeakMap();
  let mediaByID = new Map();
  let sequence = 0;
  let reportTask = null;
  let dirty = false;
  let stopped = false;
  let reportSequence = 0;
  const volumesBeforeMute = new WeakMap();
  const buffering = new WeakSet();
  const mediaEvents = ['play', 'playing', 'pause', 'ended', 'waiting', 'seeking', 'seeked', 'loadedmetadata', 'emptied', 'volumechange', 'durationchange'];

  function elements(root = document) {
    const found = [...root.querySelectorAll('audio, video')];
    // Open shadow roots are accessible; closed roots and Web Audio need adapters.
    for (const element of root.querySelectorAll('*')) {
      if (element.shadowRoot) found.push(...elements(element.shadowRoot));
    }
    return found;
  }

  function siteName() {
    return document.querySelector?.('meta[property="og:site_name"]')?.getAttribute('content')?.replace(/\s+/g, ' ').trim().slice(0, 80) || null;
  }

  function discover() {
    mediaByID = new Map();
    const result = [];
    const hasMediaSession = Boolean(globalThis.navigator?.mediaSession?.metadata?.title?.trim());
    for (const media of elements()) {
      const source = media.srcObject || media.src || media.querySelector('source[src]')?.src || media.currentSrc;
      if (!source || media.error || media.readyState < 1) {
        // An unloaded/preload-only element is not a playable source. Preserve its
        // ID through transient buffering, but retire it when the resource changes.
        continue;
      }
      if (!ids.has(media) || sourceKeys.get(media) !== source) {
        ids.set(media, `${documentID}:${++sequence}`);
        sourceKeys.set(media, source);
      }
      const id = ids.get(media);
      mediaByID.set(id, media);
      const rect = media.getBoundingClientRect?.();
      const visible = Boolean(rect && rect.width > 0 && rect.height > 0 && media.getClientRects?.().length);
      result.push({
        id,
        title: media.getAttribute('aria-label') || media.getAttribute('title') || document.title || 'Untitled media',
        site: location.hostname || 'Embedded player',
        playing: !media.paused && !media.ended && !media.seeking && media.readyState >= 3 && !buffering.has(media),
        ready: media.currentTime === 0 && media.paused,
        // Controls and a populated Media Session identify deliberate players.
        // Other media enters the shelf only after Chrome observes sound from
        // this document. The worker remembers that evidence when it is paused.
        userFacing: (media.controls === true && visible && !media.closest?.('[hidden], [inert], [aria-hidden="true"]')) || hasMediaSession,
        visible, area: visible ? rect.width * rect.height : 0,
        volume: media.volume,
        muted: media.muted
      });
    }
    return result;
  }

  function report() {
    dirty = true;
    if (!reportTask) {
      reportTask = (async () => {
        while (dirty && !stopped) {
          dirty = false;
          try {
            await chrome.runtime.sendMessage({ type: 'media', sequence: ++reportSequence, sources: discover(), siteName: siteName(), microphone: globalThis.__soundShelfMic?.inspect() ?? null });
          } catch { break; /* Periodic scans can retry a disconnected extension. */ }
        }
      })().finally(() => {
        reportTask = null;
        if (dirty && !stopped) return report();
      });
    }
    return reportTask;
  }

  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (message.type === 'inspect') {
      respond({ ok: true, sources: discover(), siteName: siteName(), microphone: globalThis.__soundShelfMic?.inspect() ?? null, sequence: ++reportSequence });
      return;
    }
    if (message.type !== 'control') return;
    (async () => {
      if (message.action === 'microphone') {
        if (message.value !== 0 && message.value !== 1) throw new Error('Invalid microphone state.');
        if (!globalThis.__soundShelfMic) throw new Error('Microphone integration unavailable.');
        await globalThis.__soundShelfMic.setMuted(message.value === 1);
        await report();
        return { ok: true, sources: discover(), siteName: siteName(), microphone: globalThis.__soundShelfMic.inspect(), sequence: ++reportSequence };
      }
      discover();
      const media = mediaByID.get(message.id);
      if (!media) throw new Error('This player is no longer available. Open its tab and refresh.');
      switch (message.action) {
        case 'play':
          if (media.ended) media.currentTime = 0;
          await media.play();
          buffering.delete(media);
          break;
        case 'pause': media.pause(); break;
        case 'volume':
          if (!Number.isFinite(message.value)) throw new Error('Invalid volume.');
          media.volume = Math.max(0, Math.min(1, message.value));
          break;
        case 'mute':
          if (message.value) {
            if (media.volume > 0) volumesBeforeMute.set(media, media.volume);
            media.muted = true;
          } else {
            media.muted = false;
            if (media.volume === 0) media.volume = volumesBeforeMute.get(media) ?? 0.5;
          }
          break;
        default: throw new Error('Unsupported player command.');
      }
      await report();
      return { ok: true, sources: discover(), siteName: siteName(), microphone: globalThis.__soundShelfMic?.inspect() ?? null, sequence: ++reportSequence };
    })().then(respond, error => respond({ error: error.message }));
    return true;
  });

  let debounce;
  function scheduleReport() {
    if (debounce) return;
    debounce = setTimeout(() => { debounce = null; report(); }, 120);
  }
  function mediaChanged(event) {
    if (['waiting', 'seeking', 'emptied'].includes(event.type)) buffering.add(event.target);
    if (['playing', 'seeked', 'pause', 'ended'].includes(event.type)) buffering.delete(event.target);
    scheduleReport();
  }
  for (const event of mediaEvents) document.addEventListener(event, mediaChanged, true);
  const observer = new MutationObserver(scheduleReport);
  observer.observe(document, { childList: true, subtree: true, attributes: true, characterData: true, attributeFilter: ['src', 'title', 'content', 'property', 'aria-label', 'data-is-muted', 'aria-disabled', 'disabled', 'hidden', 'style', 'class'] });
  document.addEventListener('visibilitychange', report);
  // A periodic scan picks up media in newly attached shadow roots as well.
  const interval = setInterval(report, 5000);
  globalThis.__soundShelf = { version: 6, report, dispose() {
    stopped = true;
    observer.disconnect();
    clearInterval(interval);
    clearTimeout(debounce);
    for (const event of mediaEvents) document.removeEventListener(event, mediaChanged, true);
    document.removeEventListener('visibilitychange', report);
  } };
  report();
})();

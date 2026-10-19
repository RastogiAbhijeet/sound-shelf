// No capture, permission probes, track interception, or synthetic keyboard shortcuts.
// Only the application's own verified call control may change microphone state.
(() => {
  if (globalThis.__soundShelfMic?.version === 2) return;
  const host = location.hostname;
  const meet = host === 'meet.google.com' && /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\/|$)/.test(location.pathname);
  const discord = host === 'discord.com' && location.pathname.startsWith('/channels/');
  if (!meet && !discord) return;
  const title = meet ? 'Google Meet' : 'Discord';
  let pending = false;
  function visible(element) {
    const style = typeof getComputedStyle === 'function' ? getComputedStyle(element) : null;
    return (!style || (style.visibility !== 'hidden' && style.visibility !== 'collapse' && style.opacity !== '0')) &&
      element.isConnected && element.getClientRects().length > 0 &&
      !element.closest('[hidden], [inert], [aria-hidden="true"]');
  }
  function enabled(element) {
    return !element.disabled && element.getAttribute('aria-disabled') !== 'true';
  }
  function read() {
    const unknown = { title, state: 'unknown', capability: 'unavailable', controllable: false, callActive: false };
    // Discord self-mute alone does not establish effective state (server mute,
    // push-to-talk and deafen also matter). Keep it discoverable, never guess.
    if (!meet) return { snapshot: unknown };
    const buttons = [...document.querySelectorAll('button, [role="button"]')].filter(visible);
    const leave = buttons.filter(button => /^Leave call$/i.test(button.getAttribute('aria-label') || ''));
    unknown.callActive = leave.length === 1 && enabled(leave[0]);
    const microphones = buttons.filter(button => button.hasAttribute('data-is-muted') &&
      /^Turn (on|off) microphone(?:\s*\([^)]*\))?$/i.test(button.getAttribute('aria-label') || ''));
    if (leave.length !== 1 || microphones.length !== 1 || !enabled(leave[0])) return { snapshot: unknown };
    const button = microphones[0];
    const muted = button.getAttribute('data-is-muted');
    const labelMuted = /^Turn on microphone/i.test(button.getAttribute('aria-label'));
    if (!enabled(button) || !['true', 'false'].includes(muted) || (muted === 'true') !== labelMuted) return { snapshot: unknown };
    return { button, snapshot: { title, state: labelMuted ? 'disabled' : 'enabled',
      capability: 'app-control', controllable: true, callActive: true } };
  }
  function inspect() {
    return read().snapshot;
  }
  async function setMuted(muted) {
    if (pending) throw new Error('Microphone command already pending.');
    pending = true;
    try {
      const before = read();
      if (!before.button) throw new Error('Microphone control unavailable. Open the call to check its state.');
      const desired = muted ? 'disabled' : 'enabled';
      if (before.snapshot.state === desired) return;
      // Calling the app's own control lets it manage all its tracks and frames.
      // Never modify tracks directly or re-enable independently disabled tracks.
      before.button.click();
      const deadline = Date.now() + 1800;
      while (Date.now() < deadline) {
        const after = read();
        if (!after.button) throw new Error('Microphone state unavailable. Check the call.');
        if (after.snapshot.state === desired) return;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      throw new Error('The call did not confirm the microphone change.');
    } finally { pending = false; }
  }
  globalThis.__soundShelfMic = { version: 2, inspect, setMuted };
})();

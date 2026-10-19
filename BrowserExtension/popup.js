document.getElementById('extension-id').textContent = chrome.runtime.id;
async function refresh() {
  const status = document.getElementById('status');
  try {
    await chrome.runtime.sendMessage({ type: 'reconnect' });
    // A missing native host reports asynchronously via the port disconnect event.
    await new Promise(resolve => setTimeout(resolve, 500));
    const state = await chrome.runtime.sendMessage({ type: 'status' });
    status.textContent = state.connected ? `Connected · ${state.players} media player(s)` : state.error;
  } catch (error) { status.textContent = error.message; }
}
document.getElementById('reconnect').addEventListener('click', refresh);
refresh();

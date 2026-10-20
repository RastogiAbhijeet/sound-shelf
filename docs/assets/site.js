'use strict';
const copy = document.querySelector('#copy-command');
copy.hidden = false;
copy.addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#commands').textContent);
    status.textContent = 'Copied. Paste into Terminal to get started.';
  } catch {
    status.textContent = 'Select and copy the commands above.';
  }
});

const serviceInput = document.querySelector('#service-search');
const webInput = document.querySelector('#web-search');
const groups = [...document.querySelectorAll('#service-links section')];
const results = document.querySelector('#search-results');
const shortcutToggle = document.querySelector('#service-shortcuts');
const searchShortcut = document.querySelector('#search-shortcut');
const shortcutPreference = 'apophis.service-shortcuts';
const shortcuts = new Map();
for (const link of document.querySelectorAll('#service-links a[data-shortcut]')) {
  const key = link.dataset.shortcut;
  const hint = document.createElement('kbd');
  hint.className = 'service-key';
  hint.textContent = key;
  hint.setAttribute('aria-hidden', 'true');
  link.after(hint);
  shortcuts.set(key, { link, hint });
}

function updateShortcuts() {
  const enabled = shortcutToggle.checked;
  searchShortcut.hidden = !enabled;
  if (enabled) webInput.setAttribute('aria-keyshortcuts', '/');
  else webInput.removeAttribute('aria-keyshortcuts');
  for (const [key, { link, hint }] of shortcuts) {
    hint.hidden = !enabled;
    if (enabled) link.setAttribute('aria-keyshortcuts', key.toUpperCase());
    else link.removeAttribute('aria-keyshortcuts');
  }
}

try {
  shortcutToggle.checked = localStorage.getItem(shortcutPreference) !== 'off';
} catch {
  // The toggle still works when browser storage is blocked.
}
shortcutToggle.addEventListener('change', () => {
  updateShortcuts();
  try {
    localStorage.setItem(shortcutPreference, shortcutToggle.checked ? 'on' : 'off');
  } catch {
    // Keep the preference for the current page only.
  }
});
updateShortcuts();

function filter() {
  const query = serviceInput.value.trim().toLowerCase();
  const matches = [];
  for (const group of groups) {
    let visible = 0;
    for (const item of group.querySelectorAll('li')) {
      const link = item.querySelector('a');
      item.hidden = !`${link.textContent} ${new URL(link.href).hostname}`.toLowerCase().includes(query);
      if (!item.hidden) {
        matches.push(link);
        visible++;
      }
    }
    group.hidden = visible === 0;
  }
  results.textContent = query ? (matches.length ? `${matches.length} found` : 'No matching services') : '';
  return matches;
}

serviceInput.addEventListener('input', filter);
serviceInput.addEventListener('keydown', (event) => {
  if (event.isComposing) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    serviceInput.value = '';
    filter();
  } else if (event.key === 'Enter' && serviceInput.value.trim()) {
    event.preventDefault();
    filter()[0]?.click();
  }
});
document.addEventListener('keydown', (event) => {
  if (!shortcutToggle.checked || event.defaultPrevented || event.repeat || event.isComposing ||
      event.altKey || event.ctrlKey || event.metaKey || event.target.isContentEditable ||
      event.target.closest?.('input, textarea, select, [role="textbox"]')) return;

  if (event.key === '/') {
    event.preventDefault();
    webInput.focus();
    return;
  }
  const shortcut = !event.shiftKey && shortcuts.get(event.key.toLowerCase());
  if (!shortcut) return;
  event.preventDefault();
  shortcut.link.click();
});
serviceInput.closest('.service-search').hidden = false;
document.querySelector('#shortcut-setting').hidden = false;

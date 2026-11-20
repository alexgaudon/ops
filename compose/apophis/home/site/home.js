const input = document.querySelector('#service-search');
const groups = [...document.querySelectorAll('#service-links section')];
const results = document.querySelector('#search-results');

function filter() {
  const query = input.value.trim().toLowerCase();
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

input.addEventListener('input', filter);
input.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    input.value = '';
    filter();
  } else if (event.key === 'Enter' && input.value.trim()) {
    event.preventDefault();
    filter()[0]?.click();
  }
});
document.addEventListener('keydown', (event) => {
  if (event.key === '/' && !event.altKey && !event.ctrlKey && !event.metaKey &&
      !event.defaultPrevented && !event.target.closest?.('input, textarea, select, [contenteditable]')) {
    event.preventDefault();
    input.focus();
  }
});
input.closest('.service-search').hidden = false;

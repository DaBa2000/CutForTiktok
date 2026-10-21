// shared by all pages
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// POST JSON, throw the server's error message
async function api(path, body) {
  const r = await fetch(path, { method: 'POST', body: JSON.stringify(body || {}) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
const setStatus = (id, status) => api(`/api/clip/${id}/status`, { status });

// streamer filter of a page (foryou | selector) lives on the server: same on website and iPhone app.
// While a change is being sent, the next load must not put the old state back.
let filterSaving = 0;
async function saveHidden(page, hidden) {
  filterSaving++;
  try { await api('/api/filters', { page, hidden: [...hidden] }); } finally { filterSaving--; }
}
const serverHidden = (j, current) => filterSaving ? current : new Set(j.hidden || []);

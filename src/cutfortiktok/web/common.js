// shared by all list pages (the editor has its own)
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// POST JSON, throw the server's error message
async function api(path, body) {
  const r = await fetch(path, { method: 'POST', body: JSON.stringify(body || {}) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
const setStatus = (id, status) => api(`/api/clip/${id}/status`, { status });

function ago(iso) {
  const m = (Date.now() - new Date(iso)) / 60000;
  if (m < 60) return Math.round(m) + ' min';
  if (m < 1440) return Math.round(m / 60) + ' h';
  return new Date(iso).toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' }) + ' ' + new Date(iso).toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
}
// time windows (minutes, 0 = all) of For You, Discovery and streamer profiles; clips older than a week are deleted
const AGES = [[0, 'Alle'], [5, '5 Min'], [15, '15 Min'], [60, '1 h'], [180, '3 h'], [360, '6 h'], [720, '12 h'], [1440, '24 h'], [4320, '3 Tage'], [10080, '1 Woche']];
const ageChips = (cur, attr = 'data-age') => AGES.map(([m, l]) => `<button ${attr}="${m}" class="${m === cur ? 'on' : ''}">${l}</button>`).join('');

// ---------- nav: pages + active configuration (which streamers are shown, see /settings) ----------
const NAV = [['/foryou', 'For You'], ['/edit', 'Edit'], ['/scheduler', 'Scheduler'], ['/', 'Discovery']];
(function buildNav() {
  const nav = document.querySelector('.nav');
  if (!nav) return;
  const here = location.pathname;
  nav.innerHTML = `<div class="logo">Cut<span>ForTiktok</span></div>
    <nav class="pages">${NAV.map(([h, l]) => `<a href="${h}" class="${h === here ? 'on' : ''}">${l}</a>`).join('')}</nav>
    <select class="cfg" id="cfgSel" title="Konfiguration: welche Streamer überall gezeigt werden"></select>
    <a href="/settings" class="phone ${here === '/settings' ? 'on' : ''}" title="Einstellungen: Konfigurationen">⚙️</a>
    <a href="/pair" class="phone" title="iPhone-App verbinden">📱</a>
    <span id="info"></span>${nav.innerHTML}`;
  loadConfigs();
  $('cfgSel').onchange = async e => {
    if (e.target.value === '+') { location.href = '/settings#neu'; return; }
    await api('/api/configs', { op: 'activate', id: e.target.value });
    location.reload();  // everything (lists, feed, downloads) follows the configuration
  };
})();
async function loadConfigs() {
  const j = await (await fetch('/api/configs')).json();
  $('cfgSel').innerHTML = j.configs.map(c => `<option value="${esc(c.id)}" ${c.id === j.active ? 'selected' : ''}>⚙︎ ${esc(c.name)}
    (${c.streamers ? c.streamers.length : 'alle'})</option>`).join('') + '<option value="+">+ Neue Konfiguration…</option>';
  return j;
}

// ---------- background downloads follow what is being looked at (prefetch.py) ----------
let focusKey = '', focusAt = 0;
function setFocus(view, ids) {
  const key = view + ':' + ids.slice(0, 12).join(',');
  if (key === focusKey && Date.now() - focusAt < 30000) return;  // refreshed while the page stays open
  focusKey = key; focusAt = Date.now();
  api('/api/focus', { view, ids: ids.slice(0, 12) }).catch(() => {});
}

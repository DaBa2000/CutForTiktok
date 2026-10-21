const api = globalThis.browser ?? globalThis.chrome;
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const log = (t, err) => { const l = $('log'); l.textContent += t + '\n'; if (err) l.style.color = '#f85149'; };
window.alert = t => log(String(t), true);  // Safari popups can't show alert()
// never wait forever (fill answers once the video is in the upload field; that may take a while)
const send = (msg, ms = msg.type === 'fill' ? 120000 : 20000) => Promise.race([
  api.runtime.sendMessage(msg).then(r => { if (r?.error) throw new Error(r.error); return r; }),
  new Promise((_, rej) => setTimeout(() => rej(new Error('Keine Antwort von der Extension – Safari neu starten bzw. Extension in den Einstellungen aus- und einschalten')), ms)),
]);

// planned times are entered and shown in German time, whatever the computer's time zone is
const TZ = 'Europe/Berlin';
function berlinParts(ts) {
  return Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit' }).formatToParts(ts).map(p => [p.type, p.value]));
}
const berlinInput = ts => { const p = berlinParts(ts); return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`; };
function berlinToTs(v) {  // "YYYY-MM-DDTHH:MM" German wall time -> epoch ms (handles summer/winter time)
  const [y, mo, d, h, mi] = v.split(/[-T:]/).map(Number);
  const want = Date.UTC(y, mo - 1, d, h, mi);
  let ts = want;
  for (let i = 0; i < 3; i++) { const p = berlinParts(ts); ts += want - Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute); }
  return ts;
}
const fmtBerlin = ts => new Intl.DateTimeFormat('de-DE', { timeZone: TZ, weekday: 'short', day: '2-digit', month: '2-digit',
  hour: '2-digit', minute: '2-digit' }).format(ts) + ' Uhr';

// 24 h time typed as "18:30", "18.30", "1830" or "18" -> "18:30" (native time inputs follow the
// system locale and may silently use AM/PM)
function parseHHMM(t) {
  const m = String(t).trim().match(/^(\d{1,2})(?:[:.,h ]?(\d{2}))?$/);
  if (!m || +m[1] > 23 || +(m[2] || 0) > 59) return null;
  return m[1].padStart(2, '0') + ':' + (m[2] || '00');
}

function planInfo(s) {
  if (!s) return '';
  if (s.state === 'running') return '<div class="m pl">▶ wird gerade gepostet…</div>';
  if (s.state === 'failed') return `<div class="m err" title="${esc(s.error)}">✗ ${esc(fmtBerlin(s.at))}: ${esc(s.error)}</div>`;
  return `<div class="saved">✓ Geplant: ${esc(fmtBerlin(s.at))}</div>${s.error ? `<div class="m">${esc(s.error)}</div>` : ''}`;
}

async function load() {
  $('list').innerHTML = '<div class="msg">Lade…</div>';
  let clips, plans = {};
  try { plans = await send({ type: 'schedules' }); } catch {}
  try { clips = await send({ type: 'queue' }); }
  catch (e) {
    $('list').innerHTML = `<div class="msg err">CutForTiktok-App nicht erreichbar.<br>Starte <b>uv run cutfortiktok review</b>.<br><small>${esc(e.message)}</small></div>`;
    return;
  }
  // planned clips that left the export list (e.g. failed with "nicht mehr in der Liste") stay visible
  for (const s of Object.values(plans)) if (!clips.some(c => c.id === s.id)) clips.push({ id: s.id, title: s.title, streamer: s.streamer, orphan: true });
  if (!clips.length) { $('list').innerHTML = '<div class="msg">Keine exportierten Clips.<br>Im Editor „Exportieren“ klicken.</div>'; return; }
  clips.sort((a, b) => (plans[a.id]?.at ?? Infinity) - (plans[b.id]?.at ?? Infinity));  // planned first, by time
  const hhmm = ts => berlinInput(ts).slice(11);  // planning is time-only: always today (German date)
  const defTime = hhmm(Math.ceil((Date.now() + 30 * 60000) / 3600000) * 3600000);
  $('list').innerHTML = clips.map((c, i) => `<div class="c">
      <img src="${esc(c.thumbnail || '')}" alt="">
      <div class="i"><div class="t" title="${esc(c.title)}">${esc(c.title)}</div>
        <div class="m">@${esc(c.streamer)}</div>${c.orphan ? '' : `<div class="m" title="${esc(c.file)}">${esc(c.filename)}</div>`}
        ${planInfo(plans[c.id])}
        <div class="plan" id="plan${i}" hidden><input type="text" inputmode="numeric" maxlength="5" placeholder="HH:MM" value="${esc(plans[c.id]?.state === 'planned' && plans[c.id].at > Date.now() ? hhmm(plans[c.id].at) : defTime)}">
          <button class="go" data-p="${i}">Speichern</button><div class="m err planerr"></div></div></div>
      <div class="b">${c.orphan ? '' : `<button class="go" data-i="${i}">Einfügen</button>`}
        ${c.orphan ? '' : `<button class="done" data-t="${i}" title="Heute zu einer Uhrzeit (deutsche Zeit) automatisch posten">${
          !plans[c.id] ? '⏰ planen' : plans[c.id].state === 'failed' ? '⏰ neu planen' : '⏰ ändern'}</button>`}
        ${plans[c.id] ? `<button class="done" data-u="${i}" title="Planung entfernen">✕ Plan</button>` : ''}
        ${c.orphan ? '' : `
        <button class="done" data-d="${i}" title="Ohne Extension gepostet">✓ gepostet</button>`}</div>
    </div>`).join('');
  document.querySelectorAll('[data-t]').forEach(b => b.onclick = () => {
    const p = $('plan' + b.dataset.t);
    p.hidden = !p.hidden;
    if (!p.hidden) { const inp = p.querySelector('input'); inp.focus(); inp.select(); }
  });
  document.querySelectorAll('[data-p]').forEach(b => b.onclick = async () => {
    const box = $('plan' + b.dataset.p), err = t => { box.querySelector('.planerr').textContent = t; };
    const v = parseHHMM(box.querySelector('input').value);
    if (!v) return err('Uhrzeit als HH:MM eingeben (24 h, z. B. 18:30)');
    const at = berlinToTs(berlinInput(Date.now()).slice(0, 11) + v);
    if (at <= Date.now()) return err(`${v} Uhr ist heute schon vorbei`);
    b.disabled = true; err('');
    try { await send({ type: 'schedule', clip: clips[b.dataset.p], at }); load(); }
    catch (e) { err(e?.message || String(e)); b.disabled = false; }
  });
  document.querySelectorAll('.plan input').forEach(inp => inp.onkeydown = e => { if (e.key === 'Enter') inp.nextElementSibling.click(); });
  document.querySelectorAll('[data-u]').forEach(b => b.onclick = async () => { await send({ type: 'unschedule', id: clips[b.dataset.u].id }); load(); });
  document.querySelectorAll('[data-i]').forEach(b => b.onclick = async () => {
    b.disabled = true; b.textContent = '…';
    log('Lade Video in die TikTok-Seite… (Fortschritt unten rechts auf der Seite)');
    try { await send({ type: 'fill', clip: clips[b.dataset.i] }); window.close(); }
    catch (e) { b.textContent = 'Fehler'; log(e?.message || String(e), true); b.disabled = false; }
  });
  document.querySelectorAll('[data-d]').forEach(b => b.onclick = async () => {
    await send({ type: 'posted', id: clips[b.dataset.d].id }); load();
  });
}
$('reload').onclick = load;
api.runtime.onMessage.addListener(msg => { if (msg.type === 'progress') log('· ' + msg.text); });
$('test').onclick = async () => {
  $('log').textContent = ''; $('log').style.color = '';
  const step = async (name, fn) => {
    try { log(`✓ ${name}: ${await fn()}`); return true; }
    catch (e) { log(`✗ ${name}: ${e?.message || e}`, true); return false; }
  };
  await step('Hintergrundskript', async () => JSON.stringify(await send({ type: 'ping' })));
  await step('App (localhost:8080)', async () => (await send({ type: 'queue' })).length + ' Clips in der Liste');
  await step('Aktiver Tab', async () => {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    return tab?.url || '(keine URL – Zugriff auf Website nicht erlaubt?)';
  });
  await step('Zugriff auf tiktok.com', async () => {
    try { return (await api.permissions.contains({ origins: ['https://www.tiktok.com/*'] })) ? 'erlaubt' : (() => { throw new Error('NICHT erlaubt – in Safari-Einstellungen → Erweiterungen erlauben'); })(); }
    catch (e) { if (/NICHT/.test(e.message)) throw e; return 'unbekannt (' + e.message + ')'; }
  });
  await step('Extension-Speicher', async () => JSON.stringify(await send({ type: 'storageInfo' })));
  await step('Skript auf TikTok-Seite', async () => JSON.stringify(await send({ type: 'pingTab' })));
};
load();

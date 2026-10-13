// Background: talks to the local CutForTiktok app and routes "fill" requests to the TikTok tab.
const api = globalThis.browser ?? globalThis.chrome;
const SERVER = 'http://localhost:8080';
const UPLOAD_URL = 'https://www.tiktok.com/tiktokstudio/upload';
const CHUNK = 1024 * 1024;
const cache = new Map();  // video url -> Uint8Array (fallback transfer to content script)

const sleep = ms => new Promise(r => setTimeout(r, ms));

// request/response with the content scripts via separate 'result' messages (see content.js)
const waiting = new Map();
const diag = { hello: null, sendError: null, directOk: null, resultMsg: null };
async function askTab(tabId, msg, timeout = 15000) {
  const reqId = Math.random().toString(36).slice(2);
  const result = new Promise((resolve, reject) => {
    const timer = setTimeout(() => { waiting.delete(reqId); reject(new Error('Seite antwortet nicht – Seite neu laden (⌘R) / Website-Zugriff erlauben')); }, timeout);
    waiting.set(reqId, r => { clearTimeout(timer); waiting.delete(reqId); r?.error ? reject(new Error(r.error)) : resolve(r); });
  });
  const direct = await api.tabs.sendMessage(tabId, { ...msg, reqId }).catch(e => { diag.sendError = e.message; });
  if (direct?.reqId === reqId) {
    diag.directOk = Date.now();
    if (direct.result) { waiting.get(reqId)?.(direct.result); }
  }
  return result;
}

// Everything kept in extension storage is small and temporary (plans live in the app). Safari sometimes
// reports "Exceeded storage quota" anyway -> drop unknown keys, and on a quota error clear and retry once.
const KEYS = ['schedules', 'autopostJob', 'pending'];
async function store(obj) {
  try { await api.storage.local.set(obj); }
  catch (e) {
    if (!/quota/i.test(e?.message || '')) throw e;
    const keep = await api.storage.local.get(KEYS).catch(() => ({}));
    await api.storage.local.clear();
    await api.storage.local.set({ ...keep, ...obj }).catch(() => api.storage.local.set(obj));
  }
}
async function cleanStorage() {
  const all = await api.storage.local.get(null).catch(() => ({}));
  const junk = Object.keys(all).filter(k => !KEYS.includes(k));
  if (junk.length) await api.storage.local.remove(junk);
}
cleanStorage();

async function markPosted(id) {
  const r = await fetch(`${SERVER}/api/clip/${id}/status`, { method: 'POST', body: JSON.stringify({ status: 'uploaded' }) });
  if (!r.ok) throw new Error('Server: ' + r.status);
  await api.storage.local.remove('pending');
  await updateSchedules(s => { delete s[id]; });
  return { ok: true };
}

// ---------- scheduled posts: alarms wake the extension, which opens the upload page and posts itself ----------
const MISSED_AFTER = 60 * 60 * 1000;   // still not started an hour late (Mac asleep, app down) -> give up
const RUN_TIMEOUT = 20 * 60 * 1000;    // started but no posted confirmation within this -> failed
const JOB_PICKUP = 3 * 60 * 1000;      // upload page must take over the job within this

// The app (data/schedules.json) is the main store: survives extension reinstalls (Safari rebuilds wipe
// extension storage) and the clip list shows it. Local storage is the fallback while the app is down.
async function getSchedules() {
  try {
    const r = await fetch(`${SERVER}/api/schedules`);
    if (r.ok) {
      const s = await r.json();
      if (s === null) return (await api.storage.local.get('schedules')).schedules || {};  // app has none yet
      await store({ schedules: s });
      return s;
    }
  } catch {}
  return (await api.storage.local.get('schedules')).schedules || {};
}

let writing = Promise.resolve();  // serialize read-modify-write (popup + alarms + page messages)
function updateSchedules(fn) {
  return writing = writing.catch(() => {}).then(async () => {
    const s = await getSchedules();
    fn(s);
    await store({ schedules: s });
    await fetch(`${SERVER}/api/schedules`, { method: 'POST', body: JSON.stringify({ schedules: s }) }).catch(() => {});
    ensureAlarms(s);
    return s;
  });
}

function ensureAlarms(s) {
  const planned = Object.values(s).filter(x => x.state === 'planned');
  // always tick: plans can also be made in the app's Scheduler page, the tick fetches them from there
  api.alarms.get('tick').then(a => { if (!a) api.alarms.create('tick', { periodInMinutes: 1 }); }).catch(() => {});
  for (const x of planned) if (x.at > Date.now()) api.alarms.create('at:' + x.id, { when: x.at });
}

async function schedule(clip, at) {
  if (!(at > Date.now())) throw new Error('Zeitpunkt liegt in der Vergangenheit');
  await updateSchedules(s => { s[clip.id] = { id: clip.id, title: clip.title, streamer: clip.streamer, at, state: 'planned' }; });
  api.alarms.create('at:' + clip.id, { when: at });
  return { ok: true };
}

async function unschedule(id) {
  await updateSchedules(s => { delete s[id]; });
  api.alarms.clear('at:' + id);
  return { ok: true };
}

async function setState(id, patch) {
  await updateSchedules(s => { if (s[id]) Object.assign(s[id], patch); });
}

let ticking = null;
function tick() { return ticking ??= doTick().finally(() => { ticking = null; }); }

async function doTick() {
  const s = await getSchedules(), now = Date.now();
  const items = Object.values(s);
  const { autopostJob } = await api.storage.local.get('autopostJob');
  if (autopostJob && now - autopostJob.t > JOB_PICKUP) {  // page never took the job
    await api.storage.local.remove('autopostJob');
    const id = autopostJob.clip.id;
    if (s[id]?.state === 'running') {
      await setState(id, { state: 'failed', error: 'TikTok-Seite hat nicht reagiert – tiktok.com in Safari erlaubt? Eingeloggt?' });
      s[id].state = 'failed';
    }
  }
  for (const x of items.filter(x => x.state === 'running' && now - x.started > RUN_TIMEOUT))
    await setState(x.id, { state: 'failed', error: 'Keine Bestätigung von TikTok (Zeitüberschreitung)' });
  if (items.some(x => x.state === 'running' && now - x.started <= RUN_TIMEOUT)) return;  // one post at a time
  const due = items.filter(x => x.state === 'planned' && x.at <= now).sort((a, b) => a.at - b.at)[0];
  if (!due) return;
  if (now - due.at > MISSED_AFTER) return setState(due.id, { state: 'failed', error: 'Verpasst – Mac/Browser/App war zur geplanten Zeit nicht aktiv' });
  let clip;
  try {
    const r = await fetch(`${SERVER}/api/queue`);
    clip = (await r.json()).find(c => c.id === due.id);
  } catch {
    return setState(due.id, { error: 'App nicht erreichbar – neuer Versuch jede Minute' });  // stays planned
  }
  if (!clip) return setState(due.id, { state: 'failed', error: 'Clip nicht mehr in der Export-Liste' });
  await setState(due.id, { state: 'running', started: now, error: null });
  try {
    await autoPost(clip);
  } catch (e) {
    await setState(due.id, { state: 'failed', error: e.message });
  }
}

// Hand the clip to the page instead of driving it from here (Safari may stop this background script
// any time): store a job, (re)load the TikTok tab on the upload page, content.js picks the job up on load
// and runs the same fill as "Einfügen", then clicks Post.
async function autoPost(clip) {
  await store({ autopostJob: { clip: { ...clip, autopost: true }, t: Date.now() } });
  const tabs = (await api.tabs.query({})).filter(t => /^https:\/\/www\.tiktok\.com\//.test(t.url || ''));
  const tab = tabs.find(t => isUploadPage(t.url)) || tabs[0];
  let tabId;
  if (!tab) {  // no TikTok tab open
    try { tabId = (await api.tabs.create({ url: UPLOAD_URL, active: true })).id; }
    catch { tabId = (await api.windows.create({ url: UPLOAD_URL, focused: true })).tabs[0].id; }  // no browser window
  } else {
    tabId = tab.id;
    await api.tabs.update(tabId, { url: UPLOAD_URL, active: true });
    await api.windows.update(tab.windowId, { focused: true }).catch(() => {});
  }
  // page script not started by Safari on its own (seen before) -> inject it; it then takes the job
  await sleep(15000);
  if ((await api.storage.local.get('autopostJob')).autopostJob) await ensureContentScript(tabId).catch(() => {});
}

api.alarms.onAlarm.addListener(() => { tick(); });
api.alarms.get('tick').then(a => { if (!a) api.alarms.create('tick', { periodInMinutes: 1 }); }).catch(() => {});
// browser start / (re)install: restore plans from the app and recreate their alarms
const restore = () => updateSchedules(() => {}).then(tick);
api.runtime.onStartup.addListener(restore);
api.runtime.onInstalled.addListener(restore);

function isUploadPage(url) { return /^https:\/\/www\.tiktok\.com\/(tiktokstudio|creator-center)\/upload/.test(url || ''); }

async function waitTabComplete(tabId, timeout = 30000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const t = await api.tabs.get(tabId);
    if (t.status === 'complete') return t;
    await sleep(300);
  }
}

async function fill(clip) {
  if (!clip?.id) throw new Error('Kein Clip übergeben');
  let [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (!tab || !isUploadPage(tab.url)) {
    tab = tab && /tiktok\.com/.test(tab.url || '')
      ? await api.tabs.update(tab.id, { url: UPLOAD_URL })
      : await api.tabs.create({ url: UPLOAD_URL });
    await sleep(800);
    await waitTabComplete(tab.id);
  }
  await ensureContentScript(tab.id);
  // answers as soon as the video is handed to the upload field; the rest runs on the page (see toast there)
  return askTab(tab.id, { type: 'fill', clip }, 60000);
}

const NO_ACCESS = 'Die Extension hat keinen Zugriff auf tiktok.com. Safari → Einstellungen → Erweiterungen → TikTok Clip Poster → '
  + '„Websites bearbeiten…“ → tiktok.com auf „Erlauben“ (oder Extension-Symbol auf der TikTok-Seite klicken → „Immer erlauben“). Danach Seite neu laden.';

async function hasTikTokAccess() {
  try { return await api.permissions.contains({ origins: ['https://www.tiktok.com/*'] }); } catch { return true; }  // API missing -> unknown
}

// make sure our content script runs in the tab: ping it, otherwise inject it on demand
async function ensureContentScript(tabId) {
  const ping = async (n, wait) => {
    for (let i = 0; i < n; i++) {
      try { await askTab(tabId, { type: 'ping' }, wait); return true; } catch { await sleep(250); }
    }
    return false;
  };
  if (await ping(3, 1000)) return;
  if (!await hasTikTokAccess()) throw new Error(NO_ACCESS);
  try {
    await api.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['content.js'] });
  } catch (e) {
    throw new Error(NO_ACCESS + ' (' + e.message + ')');
  }
  if (await ping(5, 1200)) return;
  // last resort: a fresh page load gets a fresh content script (e.g. tab open since an extension update)
  await api.tabs.reload(tabId);
  await sleep(800);
  await waitTabComplete(tabId, 60000);
  if (!await ping(8, 1500)) throw new Error('TikTok-Seite antwortet nicht – Safari → Einstellungen → Erweiterungen → TikTok Clip Poster → '
    + 'Websites: tiktok.com auf „Erlauben“. Diagnose: ' + JSON.stringify({ tab: tabId, ...diag }));
}

function b64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

async function chunk(url, i) {
  if (!cache.has(url)) {
    const r = await fetch(url);
    if (!r.ok) throw new Error('Video nicht gefunden: ' + r.status);
    cache.clear();
    cache.set(url, new Uint8Array(await r.arrayBuffer()));
  }
  const all = cache.get(url);
  return { data: b64(all.subarray(i * CHUNK, (i + 1) * CHUNK)), total: Math.ceil(all.length / CHUNK) };
}

async function handle(msg) {
  switch (msg.type) {
    case 'fill': return fill(msg.clip);
    case 'chunk': return chunk(msg.url, msg.i);
    case 'posted': return markPosted(msg.id);
    case 'schedule': return schedule(msg.clip, msg.at);
    case 'unschedule': return unschedule(msg.id);
    case 'schedules': { const s = await getSchedules(); ensureAlarms(s); tick(); return s; }
    case 'autopostFailed': {
      const s = await getSchedules();
      if (s[msg.id]?.state === 'running') await setState(msg.id, { state: 'failed', error: msg.error });
      return { ok: true };
    }
    case 'ping': return { ok: true };
    case 'storageInfo': {
      const all = await api.storage.local.get(null);
      return Object.fromEntries(Object.entries(all).map(([k, v]) => [k, JSON.stringify(v).length + ' B']));
    }
    case 'pingTab': {
      const [tab] = await api.tabs.query({ active: true, currentWindow: true });
      await ensureContentScript(tab.id);
      return askTab(tab.id, { type: 'ping' }, 5000);
    }
    case 'dump': {  // ask every frame of the active TikTok tab to report its structure
      const [tab] = await api.tabs.query({ active: true, currentWindow: true });
      if (!/tiktok\.com/.test(tab?.url || '')) throw new Error('Bitte zuerst die TikTok-Upload-Seite öffnen');
      await ensureContentScript(tab.id);
      return askTab(tab.id, { type: 'dump', stage: msg.stage }, 60000);
    }
    case 'saveDump': {
      let r;
      try { r = await fetch(`${SERVER}/api/debug-dump`, { method: 'POST', body: JSON.stringify(msg.data) }); }
      catch (e) { throw new Error('App auf localhost:8080 nicht erreichbar (' + e.message + ')'); }
      if (!r.ok) throw new Error('Server-Fehler ' + r.status + ' – App neu starten?');
      return r.json();
    }
    case 'queue': {
      const r = await fetch(`${SERVER}/api/queue`);
      if (!r.ok) throw new Error('Server: ' + r.status);
      return r.json();
    }
  }
}

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === 'result') { diag.resultMsg = Date.now(); waiting.get(msg.reqId)?.(msg.result); return false; }
  if (msg.type === 'hello') { diag.hello = { url: msg.url, tab: sender.tab?.id, t: new Date().toLocaleTimeString() }; return false; }
  handle(msg).then(sendResponse, e => sendResponse({ error: e.message }));
  return true;  // async response (works in Safari + Chrome)
});

// Runs on tiktok.com: puts the selected clip into the upload form, fills the description,
// and marks the clip as posted once TikTok confirms the post.
(() => {
  // may be injected twice (manifest + on-demand injection). An instance left over from before an
  // extension update/rebuild is cut off from the extension -> don't let it block the new one.
  if (globalThis.__clipPosterAlive?.()) return;
  const api = globalThis.browser ?? globalThis.chrome;
  globalThis.__clipPosterAlive = () => { try { return !!api.runtime?.id; } catch { return false; } };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const PENDING_MAX_AGE = 10 * 60 * 1000;

  // ---------- small on-page status toast ----------
  let toastEl;
  function toast(text, { error = false, action } = {}) {
    if (!error) api.runtime.sendMessage({ type: 'progress', text }).catch(() => {});  // popup step log
    if (window !== window.top && !document.querySelector('input[type=file]')) return;
    if (!toastEl) {
      toastEl = document.createElement('div');
      Object.assign(toastEl.style, {
        position: 'fixed', right: '20px', bottom: '20px', zIndex: 2147483647, maxWidth: '340px',
        background: '#161616', color: '#fff', font: '14px -apple-system, system-ui, sans-serif',
        padding: '12px 14px', borderRadius: '10px', boxShadow: '0 6px 24px rgba(0,0,0,.35)',
        display: 'flex', gap: '10px', alignItems: 'center',
      });
      document.body.appendChild(toastEl);
    }
    toastEl.style.borderLeft = `4px solid ${error ? '#f85149' : '#25f4ee'}`;
    toastEl.textContent = '🎬 ' + text;
    if (action) {
      const b = document.createElement('button');
      b.textContent = action.label;
      Object.assign(b.style, { background: '#fe2c55', color: '#fff', border: 0, borderRadius: '6px', padding: '6px 10px', cursor: 'pointer', font: 'inherit', whiteSpace: 'nowrap' });
      b.onclick = action.onClick;
      toastEl.appendChild(b);
    }
  }
  const hideToast = (ms = 4000) => setTimeout(() => { toastEl?.remove(); toastEl = null; }, ms);

  async function waitFor(fn, timeout = 20000, every = 250) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      const v = fn();
      if (v) return v;
      await sleep(every);
    }
    return null;
  }

  // every step that talks to the app or the background gets a deadline: a stalled request must end in an
  // error (and the fallback), never in an endless "Lade …"
  const withTimeout = (p, ms, what) => Promise.race([p, sleep(ms).then(() => { throw new Error(what); })]);

  // ---------- video ----------
  async function getFile(clip) {
    let blob;
    try {  // direct (works if Safari allows localhost from https)
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 45000);
      try {
        const r = await fetch(clip.video_url, { signal: ctl.signal });
        if (!r.ok) throw new Error(r.status);
        blob = await r.blob();
      } finally { clearTimeout(timer); }
    } catch {
      // fallback: background fetches and hands over base64 chunks
      toast('Lade Video über die Extension…');
      const parts = [];
      let i = 0, total = 1;
      do {
        const res = await withTimeout(api.runtime.sendMessage({ type: 'chunk', url: clip.video_url, i }), 60000,
          'Video kam nicht an (Extension antwortet nicht) – Safari neu starten und erneut versuchen');
        if (!res || res.error) throw new Error(res?.error || 'Video konnte nicht geladen werden');
        total = res.total;
        const bin = atob(res.data), arr = new Uint8Array(bin.length);
        for (let k = 0; k < bin.length; k++) arr[k] = bin.charCodeAt(k);
        parts.push(arr);
        toast(`Lade Video… ${Math.round(++i / total * 100)}%`);
      } while (i < total);
      blob = new Blob(parts, { type: 'video/mp4' });
    }
    return new File([blob], clip.filename || 'clip.mp4', { type: 'video/mp4', lastModified: Date.now() });
  }

  const fileInput = () =>
    document.querySelector('input[type=file][accept*="video"]') || document.querySelector('input[type=file]');

  // ---------- description (TikTok uses a Draft.js editor) ----------
  // selectors verified against TikTok Studio upload page (2026-10)
  const captionEditor = () =>
    document.querySelector('[data-e2e="caption_container"] .public-DraftEditor-content[contenteditable="true"]') ||
    document.querySelector('.public-DraftEditor-content[contenteditable="true"]');

  const norm = s => (s || '').replace(/\s+/g, ' ').trim();


  // upload finished marker (verified: "Uploaded（15MB）" with .info-progress.success)
  const uploadDone = () => {
    const box = document.querySelector('[data-e2e="upload_status_container"]');
    return box && (box.querySelector('.info-progress.success') || /uploaded|hochgeladen/i.test(box.innerText) && !/\d+\s*%/.test(box.innerText));
  };

  function selectAllIn(ed) {
    ed.focus();
    const r = document.createRange();
    r.selectNodeContents(ed);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    document.dispatchEvent(new Event('selectionchange'));
  }

  // whitespace-insensitive (hashtag decorations may add zero-width chars / spacing)
  const squash = s => (s || '').replace(/[\s\u200b\ufeff]/g, '');
  const captionIs = text => squash(captionEditor()?.innerText) === squash(text);

  // empty the editor through Draft.js' own key handling (select all + Backspace)
  async function clearCaption() {
    for (let i = 0; i < 4 && norm(captionEditor()?.innerText); i++) {
      const ed = captionEditor();
      selectAllIn(ed);
      await sleep(80);
      ed.dispatchEvent(new KeyboardEvent('keydown', { key: 'Backspace', code: 'Backspace', keyCode: 8, which: 8, bubbles: true, cancelable: true }));
      await sleep(250);
      if (norm(captionEditor()?.innerText) && i >= 1) { selectAllIn(captionEditor()); document.execCommand('delete', false); await sleep(250); }
    }
    return !norm(captionEditor()?.innerText);
  }

  // Draft.js keeps its own state: a paste event goes through its state handling,
  // plain DOM edits would only change what is visible (and TikTok would post the old text)
  async function writeCaption(text, method) {
    await clearCaption();
    const ed = captionEditor();
    ed.focus();
    if (method === 'paste') {
      const dt = new DataTransfer();
      dt.setData('text/plain', text);
      ed.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    } else {
      document.execCommand('insertText', false, text);
    }
    await waitFor(() => captionIs(text), 1500, 150);  // Draft re-renders asynchronously
    captionEditor()?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
    await sleep(200);
  }

  async function setCaption(text) {
    if (!await waitFor(captionEditor, 90000)) throw new Error('Beschreibungsfeld nicht gefunden');
    toast('Warte bis der Upload fertig ist…');
    await waitFor(uploadDone, 5 * 60 * 1000, 500);
    await sleep(1500);  // TikTok writes the file name into the caption around upload completion
    for (const method of ['paste', 'paste', 'insertText']) {
      await writeCaption(text, method);
      if (!captionIs(text)) continue;
      // still there a moment later (not overwritten by TikTok)?
      await sleep(1500);
      if (captionIs(text)) return true;
    }
    throw new Error('Beschreibung konnte nicht gesetzt werden – bitte manuell einfügen (in Zwischenablage)');
  }

  // ---------- posted detection ----------
  const isUploadPath = () => /\/(tiktokstudio|creator-center)\/upload/.test(location.pathname);
  const SUCCESS_RE = /(your video (has been|was) (posted|published|uploaded)|video (veröffentlicht|wurde veröffentlicht|wurde hochgeladen)|manage your posts|beiträge verwalten)/i;

  function isPostButton(el) {
    const b = el.closest('button, [role="button"]');
    if (!b) return null;
    if (b.matches('[data-e2e="post_video_button"]')) return b;
    if (b.closest('[data-e2e]') && b.closest('[data-e2e]').getAttribute('data-e2e') !== 'post_video_button') return null;
    const t = norm(b.innerText).toLowerCase();
    return ['post', 'posten', 'veröffentlichen', 'publish', 'jetzt posten'].includes(t) ? b : null;
  }

  async function markPosted(id) {
    const res = await api.runtime.sendMessage({ type: 'posted', id });
    if (res?.error) throw new Error(res.error);
    toast('Als gepostet markiert ✓'); hideToast();
  }

  function manualMarkToast(id, text) {
    toast(text, { action: { label: 'Als gepostet markieren', onClick: () => markPosted(id).catch(e => toast(e.message, { error: true })) } });
  }

  async function watchForSuccess(id) {
    toast('Post erkannt – warte auf Bestätigung von TikTok…');
    const startPath = location.pathname;
    const ok = await waitFor(() => location.pathname !== startPath && !isUploadPath() || SUCCESS_RE.test(document.body.innerText), 180000, 1000);
    if (ok) return markPosted(id);
    manualMarkToast(id, 'Keine Bestätigung erkannt.');
    reportAutoFail(id, 'Keine Bestätigung von TikTok erkannt');
  }

  // ---------- scheduled auto-post ----------
  const autoIds = new Set();
  function reportAutoFail(id, error) {
    if (autoIds.delete(id)) api.runtime.sendMessage({ type: 'autopostFailed', id, error }).catch(() => {});
  }

  const postButtonReady = () => {
    const b = document.querySelector('[data-e2e="post_video_button"]');
    return b && !b.disabled && b.getAttribute('aria-disabled') !== 'true' && b.getAttribute('data-disabled') !== 'true'
      && b.getAttribute('data-loading') !== 'true' ? b : null;
  };

  // confirmations TikTok may show after "Post" (e.g. content check still running) -> confirm, never cancel
  const CONFIRM = ['post now', 'jetzt posten', 'post', 'posten', 'veröffentlichen', 'publish', 'post anyway', 'trotzdem posten',
                   'continue', 'weiter', 'fortfahren', 'confirm', 'bestätigen'];
  function confirmButton() {
    // verified (2026-10): "Continue to post? We're still checking your video…" -> Cancel / Post now
    const known = document.querySelector('.TUXModal.common-modal-confirm-modal .common-modal-footer .TUXButton--primary');
    if (known && /^(post now|jetzt posten)$/i.test(norm(known.innerText))) return known;
    for (const box of document.querySelectorAll('[role="dialog"], [class*="Modal"], [class*="modal"]')) {
      for (const b of box.querySelectorAll('button, [role="button"]')) {
        const r = b.getBoundingClientRect();
        if (r.width && r.height && !b.closest('[data-e2e="post_video_button"]') && CONFIRM.includes(norm(b.innerText).toLowerCase())) return b;
      }
    }
    return null;
  }

  async function autoPost(clip) {
    toast('Geplanter Post: warte bis „Posten“ bereit ist…');
    const btn = await waitFor(postButtonReady, 10 * 60 * 1000, 1000);
    if (!btn) throw new Error('„Posten“-Button blieb deaktiviert');
    await sleep(2000);
    autoIds.add(clip.id);
    toast('Geplanter Post: klicke „Posten“…');
    btn.click();  // goes through the click handler below (caption check + posted detection)
    const clicked = new Set();
    const end = Date.now() + 60000;
    while (Date.now() < end && isUploadPath()) {
      const c = confirmButton();
      if (c && !clicked.has(c)) { clicked.add(c); toast('Bestätige: „' + norm(c.innerText) + '“'); c.click(); }
      await sleep(1000);
    }
  }

  let armedId = null, armedCaption = null, fixing = false;
  document.addEventListener('click', e => {
    if (!armedId || fixing || !isPostButton(e.target)) return;
    // last check before posting: caption must be ours, else fix it and click Post again
    if (armedCaption && !captionIs(armedCaption)) {
      e.preventDefault(); e.stopImmediatePropagation();
      const btn = isPostButton(e.target);
      fixing = true;
      toast('Beschreibung wird vor dem Posten korrigiert…');
      setCaption(armedCaption).then(() => { fixing = false; btn.click(); },
        err => { fixing = false; toast(err.message, { error: true }); });
      return;
    }
    const id = armedId;
    armedId = null;
    // survive a full page navigation after posting
    api.storage.local.set({ pending: { id, t: Date.now() } }).catch(() => {});  // only a fallback for page reloads
    watchForSuccess(id).catch(err => toast(err.message, { error: true }));
  }, true);

  // after navigation: a post was just made from this extension -> mark it
  if (window === window.top) {
    api.storage.local.get('pending').then(({ pending }) => {
      if (!pending || Date.now() - pending.t > PENDING_MAX_AGE || isUploadPath()) return;
      markPosted(pending.id).catch(e => manualMarkToast(pending.id, e.message));
    });
  }

  // ---------- fill ----------
  async function fill(clip, started) {
    toast(`Lade „${clip.title}“…`);
    const file = await getFile(clip);
    const input = await waitFor(fileInput, 30000);
    if (!input) throw new Error('Upload-Feld nicht gefunden');
    const dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    started();
    toast('Video wird hochgeladen… setze Beschreibung');
    try { await navigator.clipboard?.writeText(clip.caption); } catch {}
    await setCaption(clip.caption);
    armedId = clip.id; armedCaption = clip.caption;
    if (clip.autopost) return autoPost(clip);
    toast('Fertig ausgefüllt ✓ – prüfen und „Posten“ klicken');
  }

  // Safari resolves tabs.sendMessage with the first frame's (empty) answer, so results are
  // sent back as separate 'result' messages tagged with the request id.
  const reply = (reqId, result) => api.runtime.sendMessage({ type: 'result', reqId, result });
  const top = window === window.top;

  // tell the background we're alive (diagnostics)
  if (top) api.runtime.sendMessage({ type: 'hello', url: location.href }).catch(() => {});

  // scheduled post: the background stored a job and (re)loaded this tab on the upload page -> run it here,
  // exactly like "Einfügen" from the popup, then click Post (clip.autopost)
  const runAutopost = clip => fill(clip, () => {}).catch(e => {
    toast(e.message, { error: true });
    autoIds.add(clip.id); reportAutoFail(clip.id, e.message);
  });
  if (top && isUploadPath()) {
    api.storage.local.get('autopostJob').then(({ autopostJob: job }) => {
      if (!job || Date.now() - job.t > 3 * 60 * 1000) return;
      api.storage.local.remove('autopostJob');  // claim it (only one tab may run it)
      toast(`Geplanter Post: „${job.clip.title}“`);
      runAutopost(job.clip);
    });
  }

  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    const { reqId } = msg;
    if (msg.type === 'ping') {
      const info = top ? { ok: true, url: location.pathname, fileInputs: document.querySelectorAll('input[type=file]').length,
                           iframes: [...document.querySelectorAll('iframe')].map(f => f.src.slice(0, 80)) }
                       : fileInput() ? { ok: true, frame: location.href.slice(0, 80), fileInputs: 1 } : null;
      if (info) {
        reply(reqId, info);                        // channel 1: separate message
        sendResponse({ reqId, result: info });     // channel 2: direct answer (synchronous)
      }
      return false;
    }
    if (msg.type === 'fill' && top) sendResponse({ reqId, ack: true });
    if (msg.type === 'fill') {
      if (top && !fileInput() && document.querySelector('[data-e2e="discard_post_button"]')) {
        reply(reqId, { error: 'Es ist schon ein Video ausgewählt – erst „Discard“ klicken, dann erneut einfügen' });
        return;
      }
      // every frame looks for the upload form; the one that finds it does the work
      waitFor(fileInput, 20000).then(input => {
        if (!input) { if (top) reply(reqId, { error: 'Upload-Feld nicht gefunden – ist die TikTok-Upload-Seite offen?' }); return; }
        let answered = false;
        const answer = r => { if (!answered) { answered = true; reply(reqId, r); } };
        fill(msg.clip, () => answer({ ok: true }))
          .catch(e => { toast(e.message, { error: true }); answer({ error: e.message }); });
      });
    }
  });
})();

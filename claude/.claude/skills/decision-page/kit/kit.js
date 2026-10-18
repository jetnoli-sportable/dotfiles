/* kit.js: the behaviour decision-page and review-page share. Plain browser JS,
   no module syntax: each page's generator pastes this file verbatim into a
   <script>, ahead of the page's own code. It defines one global, `Kit`; under
   node it is also module.exports, so the DOM-free parts can be tested.

   DOM-free API (callable under node):
     Kit.stops(overview, items, closing) -> [overview, ...items, closing]  the j/k stops, as ids
     Kit.step(stops, cur, dir)           -> next stop for dir +1 / -1, clamped at both ends
     Kit.newKeys()                       -> a key registry {register, get, entries}; Kit.keys is the page's
     Kit.registerKey(key, handler, label)  register on Kit.keys. key is a string or an array of strings
                                         sharing one handler. Throws, naming the key, if it is already
                                         taken. Shared keys are pre-taken: j k Enter e E n [ ? Escape.
                                         handler(e, ctx) runs when the key is pressed outside a text box;
                                         ctx = {cur, isItem}. preventDefault is called unless it returns false.
     Kit.guard(target, key)              -> 'skip' (typing: ignore the key), 'blur' (Escape while typing),
                                         or 'pass'
     Kit.store(storage?)                 -> {get(key, fallback), set(key, value)}. JSON in and out. Never throws:
                                         a missing or throwing localStorage gives the fallback / false.
     Kit.esc(s), Kit.strip(s)            HTML-escape / strip tags and unescape to plain text
     Kit.chip({kind,label,path})         artifact chip HTML (a link when path is absolute or http(s))
     Kit.stageStrip({task,here,stages})  "Where this sits" strip HTML; stages = [{name,state,note?}],
                                         state one of done | current | upcoming | later

   DOM API (browser):
     Kit.copy(text, fallbackEl?)         -> Promise<boolean>. Clipboard write; on failure puts the text in
                                         fallbackEl (a readonly textarea), unhides and selects it; resolves false.
     Kit.init(cfg)                       wires the sidebar, legend and keyboard. Call it after the page
                                         is rendered and its keys are registered. Returns the control object.
       cfg.overview  id of the overview band element            (default 'band')
       cfg.closing   id of the closing block element            (default 'finish')
       cfg.items     () => ids of the navigable items, in order, visible ones only
       cfg.el        id => element for a stop                   (default document.getElementById)
       cfg.wrap      wrapper element selector                   (default '#wrap')
       cfg.toggle    sidebar toggle button selector             (default '.sb-toggle'); its '.tl' child gets
                     "Hide <name>" / "Show <name>"
       cfg.sidebarName  'sidebar' | 'index'                     (default 'sidebar')
       cfg.sidebarKey   localStorage key for the collapsed flag (required to persist)
       cfg.legend    legend element selector                    (default '#legend'); filled from the registry
       cfg.scope     selector bounding the details that E toggles (default 'main')
       cfg.store     a Kit.store() to use                       (default Kit.store())
       cfg.onCur(stop, scroll)   called after the current stop changes (page highlights its own links)
       cfg.enterOverview()       Enter on the overview
       cfg.enterItem(stop)       Enter on an item (optional)
       cfg.enterClosing()        Enter on the closing block (copy or submit)
       cfg.notes(stop)           n on any stop: focus that item's note box, or the global one on the closing block
     Control object: {cur(), setCur(stop, scroll), isItem(), toggleSidebar(), toggleLegend(show?)}
     The kit owns the keys j/k (and the arrows, except on a radio), Enter, e/E, n, [, ?, Escape. The `cur`
     class goes on the current stop's element. Pages register everything else with registerKey. */
const Kit = (() => {
  const SHARED = [
    [['j', 'k'], 'next / previous: overview, then each item, then the closing block'],
    [['Enter'], 'on the overview: first item that needs you; on the closing block: finish (copy or submit)'],
    [['e', 'E'], 'expand / collapse this item\'s evidence; E does every item'],
    [['n'], 'notes box (the global notes on the closing block)'],
    [['['], 'collapse / expand the sidebar'],
    [['?'], 'show / hide this list'],
    [['Escape'], 'leave a text box; close this list'],
  ];

  const stops = (overview, items, closing) => [overview, ...items, closing];
  const step = (s, cur, dir) => s[Math.max(0, Math.min(s.length - 1, s.indexOf(cur) + dir))];

  function newKeys() {
    const taken = new Set(SHARED.flatMap(([ks]) => ks)), page = new Map(), order = [];
    return {
      register(key, handler, label) {
        const ks = Array.isArray(key) ? key : [key];
        for (const k of ks) if (taken.has(k)) throw new Error(`Key "${k}" is already registered`);
        const entry = { keys: ks, handler, label };
        ks.forEach(k => { taken.add(k); page.set(k, entry); });
        order.push(entry);
      },
      get: k => page.get(k),
      entries: () => [...SHARED.map(([keys, label]) => ({ keys, label })), ...order],
    };
  }
  const keys = newKeys();
  const registerKey = (key, handler, label) => keys.register(key, handler, label);

  function guard(t, key) {
    const tag = (t || {}).tagName;
    const typing = tag === 'TEXTAREA' || tag === 'SELECT' || (tag === 'INPUT' && t.type !== 'checkbox' && t.type !== 'radio');
    return !typing ? 'pass' : key === 'Escape' ? 'blur' : 'skip';
  }

  function store(storage) {
    const s = () => { try { return storage || globalThis.localStorage || null; } catch { return null; } };
    return {
      get(key, fallback) {
        try { const raw = s().getItem(key); return raw == null ? fallback : JSON.parse(raw); } catch { return fallback; }
      },
      set(key, value) {
        try { s().setItem(key, JSON.stringify(value)); return true; } catch { return false; }
      },
    };
  }

  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const strip = s => String(s ?? '').replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

  function chip(a) {
    const link = /^(\/|https?:\/\/)/.test(a.path || '');
    const href = a.path && a.path.startsWith('/') ? 'file://' + a.path : a.path;
    const inner = `<span class="kind">${esc(a.kind)}</span><span class="lbl">${esc(a.label)}</span>${a.path && a.path !== a.label ? `<span class="path">${esc(a.path)}</span>` : ''}`;
    return link ? `<a class="chip" href="${esc(href)}" title="${esc(a.path)}">${inner}</a>` : `<span class="chip" title="${esc(a.path || a.label)}">${inner}</span>`;
  }

  function stageStrip(c) {
    const lbl = { done: 'Done', current: 'Current', upcoming: 'Upcoming', later: 'Later' };
    const li = (s, k) => `<li class="${s.state}"${s.state === 'current' ? ' aria-current="step"' : ''}><span class="n">${k + 1} · ${lbl[s.state]}</span><span>${esc(s.name)}${s.note ? ` (${esc(s.note)})` : ''}</span>${s.state === 'current' ? `<span class="here">You are here: ${esc(c.here)}</span>` : ''}</li>`;
    return `<div><h2>Where this sits <span style="text-transform:none;letter-spacing:0;font-weight:400">(${esc(c.task)})</span></h2><ol class="stages">${c.stages.map(li).join('')}</ol></div>`;
  }

  async function copy(text, fallbackEl) {
    try { await navigator.clipboard.writeText(text); return true; } catch {
      if (fallbackEl) { fallbackEl.value = text; fallbackEl.hidden = false; fallbackEl.select(); }
      return false;
    }
  }

  function legendHtml() {
    const kbd = k => `<kbd>${k === 'Escape' ? 'Esc' : esc(k)}</kbd>`;
    const show = ks => ks.length > 2 && ks.every(k => /^\d$/.test(k)) ? `${kbd(ks[0])}&ndash;${kbd(ks[ks.length - 1])}` : ks.map(kbd).join('/');
    return '<b>Keyboard shortcuts</b>' + keys.entries().map(e => `<span>${show(e.keys)} ${esc(e.label)}</span>`).join('');
  }

  function init(cfg) {
    const $ = (s, r = document) => r.querySelector(s);
    const st = cfg.store || store();
    const overview = cfg.overview || 'band', closing = cfg.closing || 'finish';
    const el = cfg.el || (id => document.getElementById(id));
    const wrap = $(cfg.wrap || '#wrap'), btn = $(cfg.toggle || '.sb-toggle'), name = cfg.sidebarName || 'sidebar';
    const legend = $(cfg.legend || '#legend');
    let cur = overview;
    const isItem = () => cur !== overview && cur !== closing;

    function setSidebar(c, persist) {
      wrap.classList.toggle('sb-collapsed', c);
      if (btn) { btn.setAttribute('aria-expanded', String(!c)); const tl = $('.tl', btn); if (tl) tl.textContent = (c ? 'Show ' : 'Hide ') + name; }
      if (persist && cfg.sidebarKey) st.set(cfg.sidebarKey, c);
    }
    const toggleSidebar = () => setSidebar(!wrap.classList.contains('sb-collapsed'), true);
    function toggleLegend(show) {
      if (!legend) return;
      const f = show === undefined ? legend.hidden : show;
      if (f) legend.innerHTML = legendHtml();
      legend.hidden = !f;
    }
    function setCur(stop, scroll) {
      cur = stop;
      document.querySelectorAll('.cur').forEach(a => a.classList.remove('cur'));
      const a = el(stop);
      if (a) { a.classList.add('cur'); if (scroll) a.scrollIntoView({ block: stop === overview ? 'start' : 'center', behavior: 'smooth' }); }
      if (cfg.onCur) cfg.onCur(stop, scroll);
    }
    const toggleDetails = ds => { const open = ds.some(d => !d.open); ds.forEach(d => { d.open = open; }); };
    const stopsNow = () => stops(overview, cfg.items(), closing);

    if (btn) btn.addEventListener('click', toggleSidebar);
    setSidebar(st.get(cfg.sidebarKey, false) === true, false);

    document.addEventListener('keydown', e => {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const t = e.target, k = e.key, g = guard(t, k);
      if (g === 'blur') { t.blur(); return; }
      if (g === 'skip') return;
      if (k === 'Enter' && (e.defaultPrevented || (t && t.tagName === 'BUTTON'))) return;
      const radio = t && t.tagName === 'INPUT';
      if (k === 'Escape') toggleLegend(false);
      else if (k === '?') { e.preventDefault(); toggleLegend(); }
      else if (k === '[') { e.preventDefault(); toggleSidebar(); }
      else if (k === 'j' || (k === 'ArrowDown' && !radio)) { e.preventDefault(); setCur(step(stopsNow(), cur, 1), true); }
      else if (k === 'k' || (k === 'ArrowUp' && !radio)) { e.preventDefault(); setCur(step(stopsNow(), cur, -1), true); }
      else if (k === 'Enter' && cur === overview) { e.preventDefault(); if (cfg.enterOverview) cfg.enterOverview(); }
      else if (k === 'Enter' && cur === closing) { e.preventDefault(); if (cfg.enterClosing) cfg.enterClosing(); }
      else if (k === 'Enter' && isItem()) { if (cfg.enterItem) { e.preventDefault(); cfg.enterItem(cur); } }
      else if (k === 'e' && isItem()) { e.preventDefault(); toggleDetails([...el(cur).querySelectorAll('details')]); }
      else if (k === 'E') { e.preventDefault(); toggleDetails([...document.querySelectorAll((cfg.scope || 'main') + ' details')]); }
      else if (k === 'n') { e.preventDefault(); if (cfg.notes) cfg.notes(cur); }
      else { const r = keys.get(k); if (r && r.handler(e, { cur, isItem: isItem() }) !== false) e.preventDefault(); }
    });

    return { cur: () => cur, setCur, isItem, toggleSidebar, toggleLegend };
  }

  return { stops, step, newKeys, keys, registerKey, guard, store, esc, strip, chip, stageStrip, copy, init };
})();
if (typeof module !== 'undefined') module.exports = Kit;

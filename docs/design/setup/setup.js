/*
 * SpeechText Setup — the behaviour every screen shares.
 * A working prototype of the spec (2026-09-18-onboarding-flow02.md), not the app: key checks,
 * downloads and Ollama are simulated, and "settings" are written to localStorage so Back,
 * reloads and the next screen see them. Review-bar controls drive what the Mac would report.
 */
const Setup = (() => {
  const STORE = "speechtext-setup";
  const PAGES = [
    { file: "01-welcome.html",     name: "Welcome" },
    { file: "02-speech.html",      name: "Speech" },
    { file: "03-ai.html",          name: "AI" },
    { file: "04-permissions.html", name: "Permissions" },
    { file: "05-try.html",         name: "Try it" },
  ];

  // ---- State ------------------------------------------------------------
  const fresh = () => ({
    theme: "light",
    stt: { path: "local", model: "turbo", service: "groq", live: true },
    ai: { path: null, service: "groq", model: "gemma4:12b" },
    keys: {},          // service → { value, status }
    downloads: {},     // "speech" | "ai" → { id, name, bytes, startedAt, status }
    installed: { ai: [] },
    settings: {},      // what the app would write on Continue (spec §7)
    perm: { ax: "idle", login: true },   // ④: what the screen decided (ax: idle | waiting | skipped)
    sim: { network: "online", ollama: "missing", ollamaVersion: "0.34.1", mic: "notAsked", ax: false },
  });
  let state;
  try { state = Object.assign(fresh(), JSON.parse(localStorage.getItem(STORE)) || {}); }
  catch { state = fresh(); }
  const save = () => localStorage.setItem(STORE, JSON.stringify(state));
  const listeners = new Set();
  const changed = () => { save(); listeners.forEach(f => f()); };

  // ---- Theme --------------------------------------------------------------
  function setTheme(theme) {
    state.theme = theme;
    document.documentElement.dataset.theme = theme;
    document.querySelectorAll("[data-theme-set]").forEach(b =>
      b.setAttribute("aria-pressed", String(b.dataset.themeSet === theme)));
    save();
  }

  // ---- Navigation -------------------------------------------------------------
  let toastTimer;
  function toast(text) {
    let el = document.querySelector(".toast");
    if (!el) { el = document.createElement("div"); el.className = "toast"; el.setAttribute("role", "status"); document.body.append(el); }
    el.textContent = text;
    el.classList.add("shown");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("shown"), 2600);
  }
  function go(index) {
    const page = PAGES[index];
    if (page.missing) { toast(`Screen ${"①②③④⑤"[index]} ${page.name} isn't designed yet — it's next.`); return; }
    location.href = page.file + (index === 0 ? `#${state.theme}-c` : "");
  }

  // Completed steps in the capsule are links back (spec §1: "completed steps are clickable")
  function wireSteps(current) {
    document.querySelectorAll(".steps-bar li").forEach((li, i) => {
      if (i < current) {
        li.classList.add("done");
        li.setAttribute("role", "link");
        li.tabIndex = 0;
        li.title = `Back to ${PAGES[i].name}`;
        li.addEventListener("click", () => go(i));
        li.addEventListener("keydown", e => { if (e.key === "Enter") go(i); });
      }
    });
  }

  // Return = primary, ⌘[ = Back (spec §1, Keyboard)
  function wireKeyboard({ primary, back }) {
    addEventListener("keydown", e => {
      if (e.key === "Enter" && !e.metaKey && !(e.target instanceof HTMLButtonElement) && e.target.getAttribute?.("role") !== "link") {
        if (primary && !primary.disabled) { e.preventDefault(); primary.click(); }
      }
      if (e.key === "[" && e.metaKey && back) { e.preventDefault(); back(); }
    });
  }

  // ---- Review bar: theme, network, test keys, reset --------------------------------
  function wireReviewBar() {
    document.querySelectorAll("[data-theme-set]").forEach(b =>
      b.addEventListener("click", () => setTheme(b.dataset.themeSet)));

    const net = document.getElementById("sim-network");
    if (net) {
      const show = () => { net.textContent = state.sim.network === "online" ? "Online" : "Offline"; net.setAttribute("aria-pressed", String(state.sim.network === "offline")); };
      net.addEventListener("click", () => { state.sim.network = state.sim.network === "online" ? "offline" : "online"; show(); changed(); });
      show();
    }

    const copy = document.getElementById("sim-copy-key");
    if (copy) copy.addEventListener("change", async () => {
      const sample = SAMPLE_KEYS[copy.value];
      copy.value = "";
      if (!sample) return;
      try { await navigator.clipboard.writeText(sample); toast("Test key copied — now come back to the window or press Paste."); }
      catch { toast("The browser didn't allow copying: " + sample); }
    });

    const fail = document.getElementById("sim-fail");
    if (fail) fail.addEventListener("click", () => {
      Object.values(state.downloads).forEach(d => { if (d.status === "running") d.status = "failed"; });
      changed();
    });

    const reset = document.getElementById("sim-reset");
    if (reset) reset.addEventListener("click", () => {
      const theme = state.theme;
      localStorage.removeItem(STORE);
      state = fresh();
      state.theme = theme;
      save();
      location.href = PAGES[0].file + `#${theme}-c`;
    });
  }

  // ---- Online services and their keys (spec §3.5, reused on ③) ----------------------
  const SERVICES = {
    // hint: the button that makes a key; setup: what the create dialog needs, or the key won't work (checked 2026-09-19)
    groq:       { name: "Groq",       account: "Groq",       url: "https://console.groq.com/keys",                button: "Get your free key ↗", hint: "Create API Key",        setup: "",                                                                  shape: /^gsk_[A-Za-z0-9]{20,}$/ },
    elevenlabs: { name: "ElevenLabs", account: "ElevenLabs", url: "https://elevenlabs.io/app/developers/api-keys", button: "Get your key ↗",    hint: "Create Key",            setup: "Give it <b>Speech to Text</b> access, then copy the key.",              shape: /^sk_[A-Za-z0-9]{20,}$/ },
    anthropic:  { name: "Claude",     account: "Anthropic",  url: "https://platform.claude.com/settings/keys",   button: "Get your key ↗",      hint: "Create key",            setup: "Pick a workspace, set expiry to <b>Never</b>, then copy the key.",    shape: /^sk-ant-[A-Za-z0-9_-]{20,}$/ },
    openai:     { name: "ChatGPT",    account: "OpenAI",     url: "https://platform.openai.com/api-keys",        button: "Get your key ↗",      hint: "Create new secret key", setup: "Keep permissions on <b>All</b>, then copy the key. Needs credit in Billing.", shape: /^sk-(?!ant-)[A-Za-z0-9_-]{20,}$/ },
  };
  const rand = n => Array.from({ length: n }, () => "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"[Math.floor(Math.random() * 56)]).join("");
  const SAMPLE_KEYS = {
    groq: "gsk_" + rand(48),
    elevenlabs: "sk_" + rand(40),
    anthropic: "sk-ant-api03-" + rand(64),
    openai: "sk-proj-" + rand(48),
    wrong: "gsk_" + rand(12),
  };

  const keyOf = service => (state.keys[service] ??= { value: "", status: "empty" });
  const keyUsable = service => ["valid", "offline"].includes(keyOf(service).status);
  const mask = v => v.length > 12 ? v.slice(0, 4) + "•".repeat(12) + v.slice(-4) : "•".repeat(v.length);

  // One lightweight authenticated request in the app (list models); here, a delay and the key's shape.
  const checks = {};
  function verify(service) {
    const key = keyOf(service);
    if (!key.value) { key.status = "empty"; changed(); return; }
    key.status = "checking";
    changed();
    clearTimeout(checks[service]);
    checks[service] = setTimeout(() => {
      if (state.sim.network === "offline") key.status = "offline";
      else key.status = SERVICES[service].shape.test(key.value.trim()) ? "valid" : "invalid";
      changed();
    }, 1100);
  }
  function setKey(service, value, { found = false } = {}) {
    const key = keyOf(service);
    key.value = value.trim();
    if (found) { key.status = "found"; changed(); setTimeout(() => verify(service), 700); }
    else verify(service);
  }

  // Clipboard pick-up: read once, when the window comes back after "Get your key" (spec §3.5)
  let awaiting = null;
  addEventListener("focus", async () => {
    if (!awaiting) return;
    const service = awaiting;
    awaiting = null;
    try {
      const text = (await navigator.clipboard.readText()).trim();
      if (SERVICES[service].shape.test(text)) setKey(service, text, { found: true });
    } catch { /* no clipboard access: the user presses Paste */ }
  });

  const STATUS = {
    empty:    () => ["", ""],
    waiting:  () => ["", '<span class="spinner"></span><span>Waiting for your key… Copy it on the website and come back.</span>'],
    found:    () => ["", '<span class="spinner"></span><span>Found a key on your clipboard.</span>'],
    checking: () => ["", '<span class="spinner"></span><span>Checking your key…</span>'],
    valid:    () => ["ok", "<span>✓ Your key works.</span>"],
    invalid:  () => ["bad", "<span>✗ This key didn't work. Copy it again from the website — make sure you copied all of it.</span>"],
    offline:  () => ["warn", '<span>⚠︎ Couldn\'t check the key — no internet connection. You can continue and we\'ll try again later. <button type="button" class="inline-link" data-act="again">Try again</button></span>'],
  };

  // Renders the shared key block into `el` for `service`. Re-call on every state change.
  function renderKeyBlock(el, service, { collapsedText } = {}) {
    const svc = SERVICES[service];
    const key = keyOf(service);
    const locked = ["found", "checking", "valid", "offline"].includes(key.status);
    const signature = [service, key.status, key.value, !!collapsedText].join("|");
    if (el.dataset.signature === signature) return;
    el.dataset.signature = signature;
    el.dataset.status = key.status;
    el.classList.toggle("is-collapsed", !!collapsedText);

    const typing = document.activeElement?.closest?.(".key-block") === el && document.activeElement.tagName === "INPUT";
    if (typing && !locked && !collapsedText) {
      // Don't rebuild the field under the user's cursor; only refresh the status line.
      el.querySelector(".status").className = "status " + STATUS[key.status]()[0];
      el.querySelector(".status").innerHTML = STATUS[key.status]()[1];
      return;
    }

    const [cls, statusHTML] = collapsedText ? ["ok", `<span>✓ ${collapsedText}</span>`] : STATUS[key.status]();
    el.innerHTML = `
      <p class="section-title">Connect your ${svc.account} account</p>
      <p class="intro">A key is like a password that lets SpeechText use your account.</p>
      <ol class="how">
        <li><span class="n">1</span><button class="link-btn" type="button" data-act="get">${svc.button}</button><span>sign in, then click <b>${svc.hint}</b>.</span></li>
        <li><span class="n">2</span><span>${svc.setup || "Copy the key."}</span></li>
        <li><span class="n">3</span><span>Come back here — we'll pick it up automatically.</span></li>
      </ol>
      <div class="key-field">
        <label class="input">
          ${locked
            ? `<span>${mask(key.value)}</span>${key.status === "valid" || key.status === "offline" ? '<button type="button" class="inline-link change" data-act="change">Change</button>' : ""}`
            : `<input type="text" spellcheck="false" autocomplete="off" aria-label="${svc.account} key" placeholder="Paste your key here" value="${key.value.replace(/"/g, "&quot;")}">`}
        </label>
        <button class="btn btn-secondary" type="button" data-act="paste">Paste</button>
      </div>
      <div class="status ${cls}" role="status">${statusHTML}</div>`;

    if (key.status === "invalid") el.querySelector("input")?.select();

    el.querySelector('[data-act="get"]').onclick = () => {
      window.open(svc.url, "_blank", "noopener");
      awaiting = service;
      key.status = "waiting";
      changed();
    };
    el.querySelector('[data-act="paste"]').onclick = async () => {
      try {
        const text = (await navigator.clipboard.readText()).trim();
        if (text) setKey(service, text);
        else toast("Your clipboard is empty — copy the key on the website first.");
      }
      catch { const input = el.querySelector("input"); input?.focus(); toast("Press ⌘V to paste your key into the field."); }
    };
    el.querySelector('[data-act="change"]')?.addEventListener("click", () => {
      key.value = ""; key.status = "empty"; changed();
      el.querySelector("input")?.focus();
    });
    el.querySelector('[data-act="again"]')?.addEventListener("click", () => verify(service));
    const input = el.querySelector("input");
    if (input) {
      let timer;
      input.addEventListener("input", () => {
        key.value = input.value.trim();
        clearTimeout(timer);
        if (!key.value) { key.status = "empty"; changed(); return; }
        timer = setTimeout(() => verify(service), 500);   // 0.5 s after the last change
      });
    }
  }

  // ---- Downloads (simulated) and the background task pill (spec §1) --------------------
  // Fast on purpose, so the whole life of a download can be watched in a review.
  const SPEEDS = { speech: 40e6, ai: 900e6 };   // bytes per second
  const PREPARE_MS = 12000;                     // "Getting ready for your Mac" (really up to 10 min)

  function startDownload(kind, { id, name, bytes }) {
    state.downloads[kind] = { id, name, bytes, startedAt: Date.now(), status: "running" };
    changed();
  }
  function cancelDownload(kind) { delete state.downloads[kind]; changed(); }
  function retryDownload(kind) { const d = state.downloads[kind]; if (d) startDownload(kind, d); }

  // Where a download is now: { phase: downloading | preparing | ready | failed, fraction, secondsLeft }
  function progress(kind) {
    const d = state.downloads[kind];
    if (!d) return null;
    if (d.status === "failed") return { phase: "failed" };
    const elapsed = Date.now() - d.startedAt;
    const downloadMs = d.bytes / SPEEDS[kind] * 1000;
    if (elapsed < downloadMs) return { phase: "downloading", fraction: elapsed / downloadMs, secondsLeft: Math.ceil((downloadMs - elapsed) / 1000) };
    const prepareMs = kind === "speech" ? PREPARE_MS : 0;
    if (elapsed < downloadMs + prepareMs) return { phase: "preparing" };
    return { phase: "ready", readyAt: d.startedAt + downloadMs + prepareMs };
  }

  const size = bytes => bytes >= 1e9 ? (bytes / 1e9).toFixed(1).replace(/\.0$/, "") + " GB" : Math.round(bytes / 1e6) + " MB";
  const ring = f => `<span class="ring" style="background: conic-gradient(var(--step-current) ${Math.round(f * 360)}deg, var(--separator) 0)"></span>`;
  const LABEL = { speech: "Speech model", ai: "AI model" };

  function mountPill() {
    const card = document.querySelector(".card");
    const pill = document.createElement("button");
    pill.type = "button";
    pill.className = "task-pill";
    pill.hidden = true;
    pill.setAttribute("aria-haspopup", "dialog");
    const pop = document.createElement("div");
    pop.className = "popover";
    pop.hidden = true;
    pop.setAttribute("role", "dialog");
    card.append(pill, pop);
    pill.addEventListener("click", e => { e.stopPropagation(); pop.hidden = !pop.hidden; draw(); });
    addEventListener("click", e => { if (!pop.contains(e.target)) pop.hidden = true; });
    pop.addEventListener("click", e => {
      const act = e.target.closest("[data-act]");
      if (!act) return;
      if (act.dataset.act === "cancel") cancelDownload(act.dataset.kind);
      if (act.dataset.act === "retry") retryDownload(act.dataset.kind);
    });
    pill.addEventListener("click", e => {
      const retry = e.target.closest(".retry");
      if (retry) { e.stopPropagation(); retryDownload(retry.dataset.kind); }
    });

    function draw() {
      const lines = [], items = [];
      for (const kind of ["speech", "ai"]) {
        const p = progress(kind), d = state.downloads[kind];
        if (!p) continue;
        if (p.phase === "ready" && Date.now() - p.readyAt > 3000) continue;   // "fades out after 3 s"
        if (p.phase === "downloading") {
          lines.push(`<span class="task">${ring(p.fraction)}⬇︎ ${LABEL[kind]} · ${Math.floor(p.fraction * 100)}%</span>`);
          items.push(`<div class="item"><b>${LABEL[kind]} — ${d.name} (${size(d.bytes)})</b><p>Downloading · ${Math.floor(p.fraction * 100)}% · about ${p.secondsLeft} s left</p><button class="btn btn-secondary" type="button" data-act="cancel" data-kind="${kind}">Cancel download</button></div>`);
        } else if (p.phase === "preparing") {
          lines.push(`<span class="task"><span class="spinner"></span>⚙︎ Preparing speech model for your Mac…</span>`);
          items.push(`<div class="item"><b>${LABEL[kind]} — ${d.name} (${size(d.bytes)})</b><p>Getting ready for your Mac. This happens only once and takes about 10 minutes. You can keep going.</p><button class="btn btn-secondary" type="button" data-act="cancel" data-kind="${kind}">Cancel download</button></div>`);
        } else if (p.phase === "ready") {
          lines.push(`<span class="task ok fading">✓ ${LABEL[kind]} ready</span>`);
          items.push(`<div class="item"><b>${LABEL[kind]} — ${d.name}</b><p>Ready.</p></div>`);
        } else {
          lines.push(`<span class="task bad">⚠︎ ${LABEL[kind]} download failed · <span class="retry" data-kind="${kind}">Retry</span></span>`);
          items.push(`<div class="item"><b>${LABEL[kind]} — ${d.name} (${size(d.bytes)})</b><p>The download stopped. Check your internet connection.</p><button class="btn btn-secondary" type="button" data-act="retry" data-kind="${kind}">Retry</button></div>`);
        }
      }
      pill.hidden = !lines.length;
      if (!lines.length) pop.hidden = true;
      const html = lines.join("");
      if (pill.dataset.html !== html) { pill.innerHTML = html; pill.dataset.html = html; }
      if (!pop.hidden) pop.innerHTML = items.join("");
    }
    setInterval(draw, 250);
    listeners.add(draw);
    draw();
  }

  // Other tabs (a second preview) and page loads see the same state
  addEventListener("storage", e => {
    if (e.key !== STORE) return;
    try { state = Object.assign(fresh(), JSON.parse(e.newValue) || {}); listeners.forEach(f => f()); } catch {}
  });

  // ---- Page entry ------------------------------------------------------------------
  function init({ step, primary, back }) {
    const hashTheme = location.hash.slice(1).split("-")[0];
    setTheme(["light", "dark"].includes(hashTheme) ? hashTheme : state.theme);
    wireReviewBar();
    wireSteps(step);
    wireKeyboard({ primary, back });
    if (step > 0) mountPill();
  }

  return {
    get state() { return state; },
    init, go, toast, changed, onChange: f => listeners.add(f),
    setTheme, SERVICES, keyOf, keyUsable, renderKeyBlock,
    startDownload, cancelDownload, retryDownload, progress, size,
  };
})();

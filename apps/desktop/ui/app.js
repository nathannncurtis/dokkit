const invoke = window.__TAURI__.core.invoke;
const $ = (id) => document.getElementById(id);
const NOTIFY = { needs_you: "New things that need you", everything: "Everything new", off: "Off" };
let view = null;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function chip(state) {
  if (!state || !state.level) return el("span", "chip down", "checking");
  if (state.level === "down") return el("span", "chip down", "unreachable");
  if (state.needs > 0) return el("span", "chip needs", state.needs === 1 ? "1 needs you" : `${state.needs} need you`);
  return el("span", "chip fine", "all fine");
}

function renderServers() {
  const list = $("servers");
  list.replaceChildren();
  const states = Object.fromEntries(view.states.map((s) => [s.id, s]));
  for (const s of view.settings.servers) {
    const st = states[s.id];
    const li = el("li");
    const name = el("div", "name", s.name);
    name.append(chip(st));
    const url = el("div", "mono mute url", s.url + (s.pin ? "  (pinned certificate)" : ""));
    const tools = el("div", "tools");
    const open = el("button", "", "Open");
    open.onclick = () => invoke("open_server", { id: s.id });
    const label = el("label", "check");
    const box = el("input");
    box.type = "checkbox";
    box.checked = s.notify;
    box.onchange = async () => { await invoke("set_server_notify", { id: s.id, notify: box.checked }); await load(); };
    label.append(box, "Notify");
    tools.append(open, label);
    if (!s.notify) {
      const reset = el("button", "reset", "Reset");
      reset.title = "Default: on";
      reset.onclick = async () => { await invoke("set_server_notify", { id: s.id, notify: true }); await load(); };
      tools.append(reset);
    }
    const remove = el("button", "danger", "Remove");
    remove.onclick = async () => {
      if (!confirm(`Remove ${s.name}? Its stored token is deleted.`)) return;
      await invoke("remove_server", { id: s.id });
      await load();
    };
    tools.append(remove);
    li.append(name, tools, url);
    if (st && st.error) li.append(el("div", "err", st.error));
    list.append(li);
  }
  $("no-servers").hidden = view.settings.servers.length > 0;
}

function renderLede() {
  const states = view.states;
  const needs = states.reduce((n, s) => n + (s.needs || 0), 0);
  const down = states.filter((s) => s.level === "down").length;
  const parts = [];
  if (!view.settings.servers.length) parts.push("Add a server to start.");
  else {
    parts.push(needs ? `${needs} ${needs === 1 ? "thing needs" : "things need"} you.` : "Nothing needs you right now.");
    if (down) parts.push(`${down} ${down === 1 ? "server is" : "servers are"} unreachable.`);
  }
  if (view.paused) parts.push("Notifications are paused for an hour.");
  $("lede").textContent = parts.join(" ");
}

function renderSettings() {
  const { settings: s, defaults: d } = view;
  $("poll").value = s.poll_secs;
  $("notify").value = s.notify;
  $("autostart").checked = s.autostart;
  $("poll-def").textContent = `Default: ${d.poll_secs} seconds`;
  $("notify-def").textContent = `Default: ${NOTIFY[d.notify]}`;
  $("autostart-def").textContent = `Default: ${d.autostart ? "on" : "off"}`;
  for (const b of document.querySelectorAll("[data-reset]")) b.hidden = s[b.dataset.reset] === d[b.dataset.reset];
}

async function load() {
  view = await invoke("get_state");
  renderLede();
  renderServers();
  renderSettings();
}

async function save(patch) {
  const next = { pollSecs: view.settings.poll_secs, notify: view.settings.notify, autostart: view.settings.autostart, ...patch };
  try {
    await invoke("set_settings", next);
    $("saved").textContent = "Saved.";
  } catch (e) {
    $("saved").textContent = "";
    alert(e);
  }
  await load();
}

$("poll").onchange = () => save({ pollSecs: Number($("poll").value) });
$("notify").onchange = () => save({ notify: $("notify").value });
$("autostart").onchange = () => save({ autostart: $("autostart").checked });
for (const b of document.querySelectorAll("[data-reset]")) {
  b.onclick = () => {
    const key = b.dataset.reset;
    const map = { poll_secs: "pollSecs", notify: "notify", autostart: "autostart" };
    save({ [map[key]]: view.defaults[key] });
  };
}

let pending = null;

async function add(pin) {
  const error = $("add-error");
  error.hidden = true;
  $("add-btn").disabled = $("pin-btn").disabled = true;
  try {
    const args = { name: $("name").value, url: $("url").value, token: $("token").value, allowHttp: $("http").checked, pin: pin || null };
    const res = await invoke("add_server", args);
    if (res.status === "untrusted") {
      pending = res.fingerprint;
      $("fingerprint").textContent = res.fingerprint;
      $("pin-box").hidden = $("pin-btn").hidden = false;
    } else {
      $("add").reset();
      $("pin-box").hidden = $("pin-btn").hidden = true;
      pending = null;
      await load();
    }
  } catch (e) {
    error.textContent = String(e);
    error.hidden = false;
  } finally {
    $("add-btn").disabled = $("pin-btn").disabled = false;
  }
}

$("add").onsubmit = (e) => { e.preventDefault(); $("pin-box").hidden = $("pin-btn").hidden = true; add(null); };
$("pin-btn").onclick = () => add(pending);

load();
setInterval(async () => {
  view = await invoke("get_state");
  renderLede();
  renderServers();
}, 5000);

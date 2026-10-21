// Pieces every direction can use as they are or restyle: the phone chrome, small parts, and the screens
// whose content is the same everywhere (lock, first run, add a server, servers, settings).
window.UI = (function () {
  var C = window.CORE, esc = C.esc, P = C.P;

  function icon(name) { return '<i class="ph ph-' + name + '" aria-hidden="true"></i>'; }
  function ic(tone, name, size) { return '<span class="ic ' + (size || "") + " t-" + tone + '" aria-hidden="true">' + icon(name) + "</span>"; }
  function tag(tone, text) { return '<span class="tag t-' + tone + '">' + esc(text) + "</span>"; }

  function statusbar() {
    var t = new Date(P.now).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return '<div class="statusbar" aria-hidden="true"><span>' + t + '</span><span class="icons">' + icon("wifi-high") + icon("cell-signal-full") + icon("battery-high") + "</span></div>";
  }
  // A phone: status bar, a scrolling screen, optional fixed bits around it, the gesture bar.
  function phone(o) {
    return '<div class="phone">' + statusbar() + (o.top || "") + '<main class="screen" id="screen" tabindex="-1">' + (o.body || "") + "</main>" + (o.bottom || "") + '<div class="gesture" aria-hidden="true"></div>' +
      '<div class="toast" id="toast" role="status" aria-live="polite"></div><div id="layer"></div></div>';
  }

  // ---------- small parts ----------
  function strip(id, small) {
    var cells = P.lastDay(id);
    return '<div class="strip' + (small ? " sm" : "") + '" role="img" aria-label="' + esc(id) + ', the last day">' + cells.map(function (c) { return '<i class="' + c + '"></i>'; }).join("") + "</div>";
  }
  function legend() { return '<div class="legend"><span><b></b>Fine</span><span><b class="warn"></b>Slow</span><span><b class="bad"></b>Down</span><span><b class="off"></b>Not expected</span></div>'; }
  function meter(m) {
    return '<div class="m"><div class="m-top"><span>' + esc(m.label) + (m.subject ? ' <span class="mono">' + esc(m.subject) + "</span>" : "") + '</span><b class="' + (m.hot ? "hot" : "") + '">' + m.percent + '%</b></div>' +
      '<div class="meter" role="meter" aria-label="' + esc(m.label) + '" aria-valuenow="' + m.percent + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (m.hot ? "hot" : "") + '" style="width:' + m.percent + '%"></b></div></div>';
  }
  function ageBanner(f) {
    if (!f.warn && !f.detail) return '<p class="age sub">' + icon("clock") + " " + esc(f.text) + "</p>";
    return '<div class="banner t-' + f.tone + '" role="status">' + icon(f.warn ? "warning" : "info") + "<div><p><b>" + esc(f.text) + "</b></p>" + (f.detail ? "<p>" + esc(f.detail) + "</p>" : "") + "</div></div>";
  }
  function issueCard(i, snap, href) {
    var st = C.issueState(i), lv = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(st);
    var fl = C.flags(i);
    return '<article class="issue ' + st + '">' + ic(lv.tone, lv.icon) +
      "<div><h3>" + esc(i.title) + '</h3><p class="say">' + esc(C.sentence(i, snap)) + "</p></div>" +
      '<p class="meta"><span>' + esc(i.machine) + "</span><span>" + esc(i.short_id) + "</span>" + (i.count > 1 ? "<span>" + i.count + " times</span>" : "") + "</p>" +
      (fl.length ? '<div class="flags">' + fl.map(function (f) { return tag(f.tone, f.text); }).join("") + "</div>" : "") +
      '<div class="act"><a class="btn soft" href="' + href + '">' + esc(C.nextStep(i)) + " " + icon("arrow-right") + "</a></div></article>";
  }
  function chart(values, label) {
    var present = values.filter(function (v) { return v != null; });
    if (!present.length) return "";
    var hi = Math.max.apply(null, present) || 1;
    return '<div class="spark" role="img" aria-label="' + esc(label || "Chart") + ' over the last 24 hours, latest ' + Math.round(present[present.length - 1]) + '">' +
      values.map(function (v) { return v == null ? "<i></i>" : '<i style="height:' + Math.max(6, v / hi * 100) + '%"></i>'; }).join("") + "</div>";
  }
  function logLines(lines) {
    return '<div class="loglines">' + lines.map(function (l) {
      return '<div class="' + (l.level === "error" ? "error" : l.level === "warn" ? "warn" : "") + '"><span class="t">' + esc(l.time) + "</span><span>" + esc(l.level.toUpperCase().slice(0, 5)) + "</span><span>" + esc(l.msg) + "</span></div>";
    }).join("") + "</div>";
  }

  // ---------- layer: toast, dialog, sheet ----------
  var toastTimer;
  function toast(msg) {
    var t = document.getElementById("toast"); if (!t) return;
    t.textContent = msg; t.classList.add("show");
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.classList.remove("show"); }, 2400);
  }
  function closeLayer() {
    var l = document.getElementById("layer"); if (!l) return;
    l.querySelectorAll(".show").forEach(function (e) { e.classList.remove("show"); });
    setTimeout(function () { l.innerHTML = ""; }, C.reduced ? 0 : 220);
  }
  function openLayer(html, kind) {
    var l = document.getElementById("layer");
    l.innerHTML = '<div class="scrim" data-close></div>' + (kind === "sheet" ? '<section class="sheet" role="dialog" aria-modal="true"><div class="grab"></div>' + html + "</section>" : '<section class="dialog" role="alertdialog" aria-modal="true">' + html + "</section>");
    requestAnimationFrame(function () { l.querySelectorAll(".scrim, .sheet, .dialog").forEach(function (e) { e.classList.add("show"); }); });
  }
  document.addEventListener("click", function (e) { if (e.target.closest("[data-close]")) closeLayer(); });
  function confirmRemove(server, onYes) {
    openLayer("<h2>Remove " + esc(server.name) + " from this phone?</h2><p>Its key, its token and its saved snapshot are deleted from this phone. Nothing changes on the server.</p>" +
      '<div class="row"><button class="btn ghost" type="button" data-close>Cancel</button><button class="btn danger" type="button" id="yes-remove">Remove</button></div>');
    setTimeout(function () { var b = document.getElementById("yes-remove"); if (b) b.onclick = function () { closeLayer(); onYes(); }; }, 0);
  }

  // ---------- screens whose content is the same everywhere ----------
  var LOGO = '<svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><circle cx="27.5" cy="30.5" r="5.4"></circle><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"></path></svg>';
  function mark(size) { return '<span class="mark" style="width:' + size + "px;height:" + size + "px;border-radius:" + Math.round(size * .28) + 'px;background:var(--brand);color:var(--brand-ink);display:grid;place-items:center">' + LOGO.replace("<svg ", '<svg style="width:' + Math.round(size * .82) + "px;height:" + Math.round(size * .82) + 'px" ') + "</span>"; }

  function lockScreen() {
    var msg = C.scenario === "nolock" ? "Set a screen lock on this phone to use Dokkit." : C.scenario === "stayed" ? "Dokkit stayed locked." : null;
    return '<div class="center-screen settle">' + ic("brand", "lock-simple", "lg") + '<h1 class="title" style="font-size:26px">Dokkit is locked</h1>' +
      '<p class="lede">' + (msg ? esc(msg) : "Unlock with your fingerprint, face or screen lock.") + "</p>" +
      '<button class="btn primary block" type="button" data-go="#home">' + icon("fingerprint") + " Unlock</button></div>";
  }
  function firstRun() {
    return '<div class="center-screen settle">' + mark(88) + '<h1 class="title">Dokkit</h1>' +
      '<p class="lede">A read-only view of your Dokkit server.<br>Alerts still reach you the usual way.<br>Nothing here can change anything.</p>' +
      '<p class="sub">The code is in the Dokkit web interface: Settings, Phones, Add a phone.</p>' +
      '<a class="btn primary block" href="#add">' + icon("qr-code") + " Scan the code</a>" +
      '<a class="btn ghost block" href="#add/paste">Paste the code instead</a></div>';
  }
  function addServer(mode) {
    var paste = mode === "paste", camOff = C.scenario === "camoff", err = C.scenario === "pairerr" ? C.PAIR_ERRORS.damaged : null;
    return '<div class="pad-screen settle"><p class="lede">' + (paste ? "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone."
      : "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once.") + "</p>" +
      (paste ? "" : camOff
        ? '<div class="panel pad" style="text-align:center;display:grid;justify-items:center">' + ic("quiet", "camera-slash") + '<p class="h2" style="margin-top:10px">The camera is off</p><p class="sub">Allow the camera to scan, or paste the code below.</p><button class="btn" type="button" style="margin-top:12px" data-toast="Android asks for the camera here.">Allow the camera</button></div>'
        : '<div class="camera" role="img" aria-label="Camera view for scanning the QR code"><span class="aim"></span><span class="hint">Point it at the code</span></div>') +
      (err ? '<div class="banner t-degraded" role="alert">' + icon("warning") + "<p>" + esc(err) + "</p></div>" : "") +
      '<label class="h2" for="code" style="font-size:15px">Or paste the code</label><textarea class="field" id="code" placeholder="dokkit-phone:1:..." autocapitalize="off" spellcheck="false"></textarea>' +
      '<button class="btn" type="button" id="add-btn" disabled>Add</button></div>';
  }
  function serverRow(s, current) {
    var f = C.freshness(s.state);
    return '<div class="srv"><button class="srv-main" type="button" data-show="' + s.id + '"><span class="srv-name">' + esc(s.name) + (current ? " " + tag("brand", "Showing") : "") + "</span>" +
      '<span class="sub mono">' + esc(C.host(s.relay)) + '</span><span class="sub' + (f.warn ? " warn" : "") + '">' + esc(f.text) + "</span>" + (f.detail ? '<span class="sub warn">' + esc(f.detail) + "</span>" : "") + "</button>" +
      '<button class="iconbtn danger" type="button" data-remove="' + s.id + '" aria-label="Remove ' + esc(s.name) + '">' + icon("trash") + "</button></div>";
  }
  function serversList() {
    var list = C.servers(), cur = C.selected();
    if (!list.length) return '<div class="panel pad" style="text-align:center;display:grid;justify-items:center">' + ic("quiet", "device-mobile") + '<p class="h2" style="margin-top:10px">No server paired</p><p class="sub">In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.</p></div>' +
      '<a class="btn primary block" href="#add">' + icon("plus") + " Add a server</a>";
    return '<section class="panel"><div class="panel-head"><span class="h2">Paired servers</span><span class="sub">' + list.length + "</span></div>" +
      list.map(function (s) { return serverRow(s, cur && s.id === cur.id); }).join("") + "</section>" +
      '<a class="btn primary block" href="#add">' + icon("plus") + " Add a server</a>";
  }
  function settingRow(s) {
    var v = C.setting(s.key), changed = C.isChanged(s.key), ctl;
    if (s.choices) ctl = '<select data-set="' + s.key + '" aria-label="' + esc(s.title) + '">' + s.choices.map(function (c) { return "<option" + (c === v ? " selected" : "") + ">" + esc(c) + "</option>"; }).join("") + "</select>";
    else ctl = "<span>" + esc(s.words[0]) + '</span><input type="number" inputmode="numeric" data-set="' + s.key + '" value="' + v + '" min="' + s.min + '" max="' + s.max + '" aria-label="' + esc(s.title) + '"><span>' + esc(s.words[1]) + "</span>";
    return '<div class="cfg-row' + (changed ? " changed" : "") + '"><div><h3>' + esc(s.title) + '</h3><p class="sub">' + esc(s.sub) + '</p></div><div class="ctl">' + ctl + "</div>" +
      '<span class="def">Default: ' + esc(C.defaultText(s)) + (changed ? '<button type="button" data-reset="' + s.key + '">Reset</button>' : "") + "</span></div>";
  }
  function settingsGroups() {
    var groups = [
      ["set-look", "palette", "Look", "Theme and accent.", ["theme", "accent"]],
      ["set-fresh", "arrows-clockwise", "Snapshots", "How often the app looks, and when it warns.", ["refresh", "late", "relayWait"]],
      ["set-show", "squares-four", "What the screens show", "Meters and long lists.", ["hot", "fineShown"]],
      ["set-lock", "lock-simple", "Unlock", "When the app asks again.", ["lock"]]
    ];
    return groups.map(function (g, n) {
      return '<details class="panel fold" id="' + g[0] + '"' + (n === 0 ? " open" : "") + "><summary>" + ic("brand", g[1], "sm") + '<div><span class="h2">' + g[2] + '</span><p class="sub">' + g[3] + "</p></div>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</summary>" +
        '<div class="fold-body">' + g[4].map(function (k) { return settingRow(C.SETTINGS.find(function (s) { return s.key === k; })); }).join("") +
        '<div class="save-row"><p class="sub">Applies on this phone only.</p><button class="btn primary" type="button" data-save>' + icon("check") + " Save</button></div></div></details>";
    }).join("");
  }
  function about() {
    return '<section class="panel pad stack" style="gap:6px"><span class="h2">About</span><p class="sub">Dokkit for Android 0.1.0. Read-only: it cannot change anything on a server and sends no notifications. It fetches when opened, when you pull down, and on the schedule above while in front.</p></section>';
  }

  // Wires the shared screens' controls; call after each render.
  function wire(rerender) {
    var code = document.getElementById("code"), add = document.getElementById("add-btn");
    if (code && add) {
      code.oninput = function () { add.disabled = !code.value.trim(); };
      add.onclick = function () {
        var v = code.value.trim();
        if (v.indexOf("dokkit-phone:") !== 0) { toast(C.PAIR_ERRORS.notacode); return; }
        toast("Paired. Fetching the first snapshot…"); setTimeout(function () { location.hash = "#home"; }, 900);
      };
    }
    document.querySelectorAll("[data-show]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.show); toast("Showing " + C.selected().name + "."); rerender(); }; });
    document.querySelectorAll("[data-remove]").forEach(function (b) {
      b.onclick = function () { var s = C.servers().find(function (x) { return x.id === b.dataset.remove; }); confirmRemove(s, function () { C.removeServer(s.id); toast("Removed " + s.name + " from this phone."); rerender(); }); };
    });
    document.querySelectorAll("[data-set]").forEach(function (el) {
      el.onchange = function () { C.setSetting(el.dataset.set, el.type === "number" ? +el.value : el.value); rerender(true); };
    });
    document.querySelectorAll("[data-reset]").forEach(function (b) { b.onclick = function () { C.resetSetting(b.dataset.reset); toast("Back to the default."); rerender(true); }; });
    document.querySelectorAll("[data-save]").forEach(function (b) { b.onclick = function () { var n = C.SETTINGS.filter(function (s) { return C.isChanged(s.key); }).length; toast(n ? "Saved. " + C.plural(n, "setting differs", "settings differ") + " from the default." : "Saved. Everything is on its default."); }; });
    document.querySelectorAll("[data-toast]").forEach(function (b) { b.onclick = function () { toast(b.dataset.toast); }; });
    document.querySelectorAll("[data-go]").forEach(function (b) { b.onclick = function () { location.hash = b.dataset.go; }; });
  }

  // Pull to refresh and the refresh button share one fake fetch.
  function fakeRefresh(done) { toast("Looking for a new snapshot…"); setTimeout(function () { toast("Up to date. Snapshot made just now."); if (done) done(); }, 900); }

  // Where the app starts for the scenario chosen on the review page.
  function startRoute() {
    if (location.hash) return location.hash;
    if (C.scenario === "locked" || C.scenario === "nolock" || C.scenario === "stayed") return "#lock";
    if (C.scenario === "none") return "#first";
    if (C.scenario === "camoff" || C.scenario === "pairerr") return "#add";
    return "#home";
  }

  return { icon: icon, ic: ic, tag: tag, phone: phone, strip: strip, legend: legend, meter: meter, ageBanner: ageBanner, issueCard: issueCard, chart: chart, logLines: logLines,
    toast: toast, openLayer: openLayer, closeLayer: closeLayer, confirmRemove: confirmRemove, mark: mark, lockScreen: lockScreen, firstRun: firstRun, addServer: addServer,
    serversList: serversList, serverRow: serverRow, settingsGroups: settingsGroups, settingRow: settingRow, about: about, wire: wire, fakeRefresh: fakeRefresh, startRoute: startRoute };
})();

// Keep it green: 48 services drift green -> amber -> red; fix them before five are red at once.
window.KeepGreen = (function () {
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  };
  var hosts = ["db-01", "web-02", "nas", "mail", "build", "sql"];
  var parts = ["web", "api", "queue", "disk", "backup", "cert", "dns", "cron"];
  var words = ["up", "slow", "down"];

  var html =
    '<div class="kg-deck"><div class="kg-screen">' +
      '<div class="kg-head"><h2>Keep it green</h2><p class="kg-sub">48 services drift from green to amber to red. Fix them before five go red at once.</p></div>' +
      '<div class="kg-wrap">' +
        '<div class="kg-board idle" data-k="board" role="group" aria-label="Services, 48 squares"></div>' +
        '<div class="kg-cover" data-k="cover"><div class="kg-box">' +
          '<p class="kg-h" data-k="coverH">A quiet half hour, for now</p>' +
          '<p class="kg-p" data-k="coverP">Click or tap an amber or red square to fix it. On a keyboard, arrows move and Enter fixes. P pauses.</p>' +
          '<div class="kg-btns"><button class="btn primary" data-k="start" type="button"><i class="ph ph-play" aria-hidden="true"></i><span data-k="startText">Start</span></button>' +
          '<label class="kg-check"><input type="checkbox" data-k="calm"> Calm mode</label></div>' +
        '</div></div>' +
      '</div>' +
      '<div class="kg-foot"><p class="kg-legend"><span><b></b>Up</span><span><b class="warn"></b>Slow: fix it</span><span><b class="bad"></b>Down: fix it fast</span></p>' +
      '<button class="btn" data-k="pause" type="button" disabled><i class="ph ph-pause" aria-hidden="true"></i><span>Pause</span></button></div>' +
    '</div>' +
    '<dl class="kg-gauges" aria-label="Readouts">' +
      '<div class="kg-gauge"><dt>Uptime kept</dt><dd><span class="mono" data-k="score">0</span><small>min</small></dd></div>' +
      '<div class="kg-gauge"><dt>Fixes</dt><dd><span class="mono" data-k="fixes">0</span></dd></div>' +
      '<div class="kg-gauge"><dt>Red now</dt><dd><span class="mono" data-k="reds">0</span><small>/ 5</small></dd></div>' +
      '<div class="kg-gauge"><dt>Best</dt><dd><span class="mono" data-k="best">0</span><small>min</small></dd></div>' +
    '</dl></div>' +
    '<p class="kg-sr" data-k="say" aria-live="polite"></p>';

  function mount(root) {
    root.classList.add("kg");
    root.innerHTML = html;
    var el = {};
    root.querySelectorAll("[data-k]").forEach(function (e) { el[e.dataset.k] = e; });
    var board = el.board, cells = [];
    hosts.forEach(function (h) {
      parts.forEach(function (p) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "kg-cell";
        b.tabIndex = cells.length ? -1 : 0;
        var c = { el: b, name: h + " " + p, s: 0, t: 0 };
        b.setAttribute("aria-label", c.name + ", up");
        b.onclick = function () { fix(c); };
        board.appendChild(b);
        cells.push(c);
      });
    });

    var fixes = 0, running = false, started = false, over = false, locked = false, score = 0, elapsed = 0, spawnIn = 1, last = 0;
    var best = parseInt(store.get("dokkit-green-best"), 10) || 0;
    el.best.textContent = best;
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) el.calm.checked = true;

    function set(c, s) {
      c.s = s; c.t = 0;
      c.el.className = "kg-cell" + (s === 1 ? " warn" : s === 2 ? " bad" : "");
      c.el.setAttribute("aria-label", c.name + ", " + words[s]);
    }
    function fix(c) {
      if (!running || c.s === 0) return;
      set(c, 0);
      el.fixes.textContent = ++fixes;
      c.el.classList.add("fixed");
      setTimeout(function () { c.el.classList.remove("fixed"); }, 120);
    }
    function reds() { return cells.filter(function (c) { return c.s === 2; }).length; }
    function cover(h, p, btn) {
      el.coverH.textContent = h;
      el.coverP.textContent = p;
      el.startText.textContent = btn;
      el.cover.hidden = false;
    }
    function saveBest() {
      if (Math.floor(score) > best) { best = Math.floor(score); store.set("dokkit-green-best", best); el.best.textContent = best; }
    }

    function start() {
      if (locked) return;
      if (over || !started) {
        cells.forEach(function (c) { set(c, 0); });
        score = 0; elapsed = 0; spawnIn = 1; over = false; fixes = 0; el.fixes.textContent = 0;
      }
      started = true;
      running = true;
      board.classList.remove("idle");
      el.cover.hidden = true;
      el.pause.disabled = false;
      el.pause.querySelector("span").textContent = "Pause";
      el.pause.querySelector("i").className = "ph ph-pause";
      last = performance.now();
      requestAnimationFrame(tick);
      var f = board.querySelector('[tabindex="0"]');
      if (f) f.focus();
    }
    function pause(quiet) {
      if (!running) return;
      running = false;
      board.classList.add("idle");
      el.pause.querySelector("span").textContent = "Resume";
      el.pause.querySelector("i").className = "ph ph-play";
      cover("Paused", "Your services wait for you. " + Math.floor(score) + " min of uptime so far.", "Resume");
      if (quiet !== true) el.start.focus();
    }
    function end() {
      running = false; over = true;
      board.classList.add("idle");
      el.pause.disabled = true;
      var s = Math.floor(score), was = best;
      saveBest();
      cover("Five services are down", "You kept " + s + " min of uptime." + (s > was ? " That's a new best." : " Best: " + best + " min."), "Play again");
      el.say.textContent = "Game over. " + s + " minutes of uptime kept.";
      el.start.focus();
    }

    function tick(now) {
      if (!running) return;
      if (!root.isConnected) return stop();
      var dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      var calm = el.calm.checked ? 0.6 : 1;
      elapsed += dt;
      var rate = (0.7 + elapsed * 0.025) * calm;
      var amberLife = Math.max(2.4, 5.5 - elapsed * 0.03) / calm;
      spawnIn -= dt;
      if (spawnIn <= 0) {
        spawnIn = (0.5 + Math.random()) / rate;
        var green = cells.filter(function (c) { return c.s === 0; });
        if (green.length) set(green[Math.floor(Math.random() * green.length)], 1);
      }
      var up = 0;
      cells.forEach(function (c) {
        c.t += dt;
        if (c.s === 1 && c.t > amberLife) set(c, 2);
        if (c.s === 0) up++;
      });
      // one second of play is five minutes of a busy day
      score += dt * 5 * up / 48;
      var r = reds();
      el.score.textContent = Math.floor(score);
      el.reds.textContent = r;
      el.reds.classList.toggle("hot", r >= 3);
      if (r >= 5) return end();
      requestAnimationFrame(tick);
    }

    function hide() { if (document.hidden) pause(true); }
    function stop() { running = false; document.removeEventListener("visibilitychange", hide); }

    el.start.onclick = start;
    el.pause.onclick = function () { running ? pause() : start(); };
    document.addEventListener("visibilitychange", hide);
    root.addEventListener("keydown", function (e) {
      if ((e.key === "p" || e.key === "P" || e.key === "Escape") && started && !over && !locked) {
        e.preventDefault();
        e.stopPropagation();
        running ? pause() : start();
        return;
      }
      var cols = getComputedStyle(board).gridTemplateColumns.split(" ").length;
      var i = cells.findIndex(function (c) { return c.el === document.activeElement; });
      var to = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: cols, ArrowUp: -cols }[e.key];
      if (i < 0 || to === undefined) return;
      e.preventDefault();
      var j = Math.max(0, Math.min(cells.length - 1, i + to));
      cells[i].el.tabIndex = -1;
      cells[j].el.tabIndex = 0;
      cells[j].el.focus();
    });

    return {
      start: start,
      pause: pause,
      stop: stop,
      // the real line hands over the seat: pause for good and keep the score
      lock: function () { pause(true); locked = true; saveBest(); el.start.disabled = true; el.pause.disabled = true; },
      state: function () { return { running: running, started: started, score: Math.floor(score), best: best, reds: reds(), fixes: fixes }; }
    };
  }

  return { mount: mount };
})();

document.querySelectorAll("[data-keep-green]").forEach(function (el) { KeepGreen.mount(el); });

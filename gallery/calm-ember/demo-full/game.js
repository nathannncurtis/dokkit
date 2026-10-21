(function () {
  var $ = function (id) { return document.getElementById(id); };
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  };
  var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // theme
  var root = document.documentElement;
  function paintTheme() {
    var dark = root.dataset.theme !== "light";
    $("theme").innerHTML = '<i class="ph ph-' + (dark ? "sun" : "moon") + '" aria-hidden="true"></i>';
    $("theme").setAttribute("aria-label", "Switch to " + (dark ? "light" : "dark") + " theme");
  }
  $("theme").onclick = function () {
    root.dataset.theme = root.dataset.theme === "light" ? "dark" : "light";
    store.set("dokkit-theme", root.dataset.theme);
    paintTheme();
  };
  paintTheme();

  // the line (faked)
  var place = 4, freed = 3, ago = 0, turnCome = false;
  var seats = $("seats");
  for (var i = 0; i < 80; i++) seats.appendChild(document.createElement("i"));
  function ordinal(n) { var s = ["th", "st", "nd", "rd"], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); }
  function showPlace() {
    $("place").textContent = place;
    $("placeText").textContent = place === 1 ? "You're next in line" : "You're " + ordinal(place) + " in line";
    $("freed").textContent = freed;
  }
  function nextDrop() { return 20 + Math.random() * 20; }
  var dropIn = nextDrop();
  setInterval(function () {
    if (turnCome) return;
    ago = (ago + 1) % 5;
    $("ago").textContent = ago === 0 ? "just now" : ago + " s ago";
    if (--dropIn <= 0) {
      dropIn = nextDrop();
      freed++;
      var seat = seats.children[Math.floor(Math.random() * 80)];
      seat.className = "free";
      setTimeout(function () { seat.className = ""; }, 1500);
      place--;
      if (place <= 0) return yourTurn();
      showPlace();
    }
  }, 1000);
  $("skip").onclick = yourTurn;

  function yourTurn() {
    if (turnCome) return;
    turnCome = true;
    pause(true);
    saveBest();
    $("place").innerHTML = "<i class=\"ph ph-check-circle\" aria-hidden=\"true\"></i>";
    $("placeText").textContent = "It's your turn";
    document.title = "Your seat is ready · Dokkit";
    $("kept").textContent = started ? "You kept " + Math.floor(score) + " min of uptime. Best: " + best + " min." : "";
    var d = $("turn");
    d.addEventListener("cancel", function (e) { e.preventDefault(); });
    d.showModal();
    $("take").focus();
    var left = 120;
    var t = setInterval(function () {
      left--;
      $("hold").textContent = Math.floor(left / 60) + ":" + String(left % 60).padStart(2, "0");
      if (left <= 0) clearInterval(t);
    }, 1000);
  }
  $("take").onclick = function () { $("take").textContent = "Taking you in…"; $("take").disabled = true; };

  // the game
  var hosts = ["db-01", "web-02", "nas", "mail", "build", "sql"];
  var parts = ["web", "api", "queue", "disk", "backup", "cert", "dns", "cron"];
  var words = ["up", "slow", "down"];
  var board = $("board"), cells = [];
  board.classList.add("idle");
  hosts.forEach(function (h) {
    parts.forEach(function (p) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "cell";
      b.tabIndex = cells.length ? -1 : 0;
      var c = { el: b, name: h + " " + p, s: 0, t: 0 };
      b.setAttribute("aria-label", c.name + ", up");
      b.onclick = function () { fix(c); };
      board.appendChild(b);
      cells.push(c);
    });
  });

  var fixes = 0, running = false, started = false, over = false, score = 0, elapsed = 0, spawnIn = 1, last = 0;
  var best = parseInt(store.get("dokkit-green-best"), 10) || 0;
  $("best").textContent = best;
  if (reduced) $("calm").checked = true;

  function set(c, s) {
    c.s = s; c.t = 0;
    c.el.className = "cell" + (s === 1 ? " warn" : s === 2 ? " bad" : "");
    c.el.setAttribute("aria-label", c.name + ", " + words[s]);
  }
  function fix(c) {
    if (!running || c.s === 0) return;
    set(c, 0);
    $("fixes").textContent = ++fixes;
    c.el.classList.add("fixed");
    setTimeout(function () { c.el.classList.remove("fixed"); }, 120);
  }
  function reds() { return cells.filter(function (c) { return c.s === 2; }).length; }

  function start() {
    if (over || !started) {
      cells.forEach(function (c) { set(c, 0); });
      score = 0; elapsed = 0; spawnIn = 1; over = false; fixes = 0; $("fixes").textContent = 0;
    }
    started = true;
    running = true;
    board.classList.remove("idle");
    $("cover").hidden = true;
    $("pause").disabled = false;
    $("pause").querySelector("span").textContent = "Pause";
    $("pause").querySelector("i").className = "ph ph-pause";
    last = performance.now();
    requestAnimationFrame(tick);
    var f = board.querySelector('[tabindex="0"]');
    if (f) f.focus();
  }
  function pause(quiet) {
    if (!running) return;
    running = false;
    board.classList.add("idle");
    $("pause").querySelector("span").textContent = "Resume";
    $("pause").querySelector("i").className = "ph ph-play";
    cover("Paused", "Your services wait for you. " + Math.floor(score) + " min of uptime so far.", "Resume");
    if (quiet !== true) $("start").focus();
  }
  function cover(h, p, btn) {
    $("coverH").textContent = h;
    $("coverP").textContent = p;
    $("startText").textContent = btn;
    $("cover").hidden = false;
  }
  function saveBest() {
    if (Math.floor(score) > best) { best = Math.floor(score); store.set("dokkit-green-best", best); $("best").textContent = best; }
  }
  function end() {
    running = false; over = true;
    board.classList.add("idle");
    $("pause").disabled = true;
    var s = Math.floor(score), was = best;
    saveBest();
    cover("Five services are down", "You kept " + s + " min of uptime." + (s > was ? " That's a new best." : " Best: " + best + " min."), "Play again");
    $("say").textContent = "Game over. " + s + " minutes of uptime kept.";
    $("start").focus();
  }

  function tick(now) {
    if (!running) return;
    var dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    var calm = $("calm").checked ? 0.6 : 1;
    elapsed += dt;
    var rate = (0.7 + elapsed * 0.025) * calm;        // squares going amber per second
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
      if (c.s === 1 && c.t > amberLife) { set(c, 2); }
      if (c.s === 0) up++;
    });
    score += dt * 5 * up / 48;                          // one second of play is five minutes of a busy day
    var r = reds();
    $("score").textContent = Math.floor(score);
    $("reds").textContent = r;
    $("reds").classList.toggle("hot", r >= 3);
    if (r >= 5) return end();
    requestAnimationFrame(tick);
  }

  $("start").onclick = start;
  $("pause").onclick = function () { running ? pause() : start(); };
  document.addEventListener("visibilitychange", function () { if (document.hidden) pause(true); });
  document.addEventListener("keydown", function (e) {
    if (turnCome) return;
    if ((e.key === "p" || e.key === "P" || e.key === "Escape") && started && !over) {
      e.preventDefault();
      running ? pause() : start();
    }
  });
  board.addEventListener("keydown", function (e) {
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

  window.__game = { start: start, pause: pause, state: function () { return { running: running, score: score, reds: reds(), fixes: fixes, turn: turnCome }; }, cells: cells };
})();

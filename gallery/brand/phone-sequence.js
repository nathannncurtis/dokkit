// The phone step as a pinned sequence: the snapshot reaches an Android phone, which becomes an iPhone, then an
// iPhone Duo that opens on its hinge, turns, and folds shut. Scroll drives every frame, both ways. Stills only.
// It is one device throughout: a panel whose shape morphs from phone to phone to the Duo's cover, and a second panel
// behind it that the cover swings open from. Nothing crossfades; every frame is a single object.
railFor($$(".step"), $$(".rail a"));

(() => {
  // In points. The Duo open: a 951 by 669 screen in a 12-point bezel, two 487.5 by 693 panels, the hinge between.
  const PW = 487.5, PH = 693, SW = 951, SH = 669, HALF = 475.5;
  // The phone screen is laid out at this width and scaled to fit, so text never rewraps as the frame changes.
  const L = 445;

  // ---------- the app, in its own design ----------
  const ic = {
    house: '<path d="M4 11l8-7 8 7v9a1 1 0 0 1-1 1h-5v-6h-4v6H5a1 1 0 0 1-1-1z"/>',
    drives: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><circle cx="17" cy="7.5" r=".6"/><circle cx="17" cy="16.5" r=".6"/>',
    gear: '<path d="M12 2.8l1.6 2.3 2.7-.6.6 2.7 2.3 1.6-1.4 2.4 1.4 2.4-2.3 1.6-.6 2.7-2.7-.6L12 21.2l-1.6-2.3-2.7.6-.6-2.7-2.3-1.6L6.2 12 4.8 9.6l2.3-1.6.6-2.7 2.7.6z"/><circle cx="12" cy="12" r="3"/>',
    swap: '<path d="M4 8h14l-3.5-3.5M20 16H6l3.5 3.5"/>',
    refresh: '<path d="M20 12a8 8 0 1 1-2.4-5.7M20 4v5h-5"/>',
    octagon: '<path d="M8.2 3h7.6L21 8.2v7.6L15.8 21H8.2L3 15.8V8.2z"/><path d="M12 8v4.5M12 16h.01"/>',
    hourglass: '<path d="M6 3h12M6 21h12M7 3c0 5 10 5 10 9s-10 4-10 9M17 3c0 5-10 5-10 9s10 4 10 9"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
    wave: '<path d="M8 13V6.5a1.5 1.5 0 0 1 3 0V12m0-1.5V5a1.5 1.5 0 0 1 3 0v6m0-4.5a1.5 1.5 0 0 1 3 0V14a6 6 0 0 1-6 6h-1a6 6 0 0 1-5-2.7L3.6 14a1.5 1.5 0 0 1 2.4-1.8L8 14"/>',
    wifi: '<path d="M2 9a15 15 0 0 1 20 0M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0"/><circle cx="12" cy="19" r="1" fill="currentColor"/>',
  };
  const svg = (n) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ic[n]}</svg>`;
  // One status cluster for every device. Its pieces move between Android's row, the iPhone's ears and the Duo's corner
  // column; a piece a device does not have shrinks away where it stands.
  // The ring and the Wi-Fi glyph are drawn to the Duo simulator's own status column, measured and fitted in points;
  // the glyph's origin is the ring's centre.
  const sbar = () => `<div class="sb"><b class="sb-t">9:41</b>
    <svg class="sb-r" viewBox="0 0 41 41" aria-hidden="true"><path d="M4.03 29.63A18.83 18.83 0 1 1 36.97 29.63"/></svg>
    <svg class="sb-w" viewBox="-9 -7 18 14" aria-hidden="true"><path d="M-7.68 -2.69A12.60 12.60 0 0 1 7.68 -2.69" fill="none" stroke-width="2.68" stroke-linecap="round"/><path d="M-4.45 0.73A7.94 7.94 0 0 1 4.45 0.73" fill="none" stroke-width="2.64" stroke-linecap="round"/><path d="M0 6.69L-2.46 3.87A3.74 3.74 0 0 1 2.46 3.87Z" stroke-width="0.80" stroke-linejoin="round"/></svg>
    <svg class="sb-g" viewBox="0 0 24 24" aria-hidden="true"><path d="M21 3.5v17H4.5z"/></svg>
    <span class="sb-b"><i></i><i></i><i></i><i></i></span><i class="sb-a"><i></i></i></div>`;
  const title = (cls = "") => `<div class="a-tt ${cls}"><b>Home</b><small>northwind</small></div>`;
  const tools = (cls = "") => `<div class="a-tools ${cls}"><span class="a-ri">${svg("swap")}</span><span class="a-ri">${svg("refresh")}</span></div>`;
  const hero = (c = "") => `<section class="a-hero t-down ${c}"><div class="a-hrow"><span class="a-hic">${svg("octagon")}</span><span class="a-eye">${svg("wave")}Good evening</span></div><h3>3 things need you</h3><p>2 are coming up, and 1 is snoozed.</p><p class="a-age">${svg("clock")}Snapshot made 40 seconds ago</p></section>`;
  const figs = (c = "") => `<section class="a-card a-figs ${c}"><div><b class="c-down">3</b><small>need you</small></div><div><b class="c-soon">2</b><small>coming up</small></div><div><b class="c-ok">37</b><small>fine</small></div></section>`;
  const segc = (c = "") => `<div class="a-seg ${c}"><span class="a-lens"></span><span class="on">Needs you <i>3</i></span><span>Coming up <i>2</i></span></div>`;
  const iss1 = (c = "") => `<section class="a-issue t-down ${c}"><span class="a-tc">${svg("octagon")}</span><div><h4>Nightly purge did not run</h4><p>Something is wrong with nightly-purge on db-01 since 21 h ago.</p><small>db-01 &nbsp; DOK-3</small><span class="a-soft">See the last run ${svg("arrow")}</span></div></section>`;
  const iss2 = (c = "") => `<section class="a-issue t-slow ${c}"><span class="a-tc">${svg("hourglass")}</span><div><h4>Upload portal answers slowly</h4><p>Working, but not as it should: upload-portal on web-02, since 40 min ago.</p><small>web-02 &nbsp; DOK-7 &nbsp; 3 times</small></div></section>`;
  const strip = (runs) => `<div class="a-strip">${runs.map(([w, t]) => `<i class="r-${t}" style="flex:${w}"></i>`).join("")}</div>`;
  const lastDay = () => `<section class="a-card a-day"><h4>The last day</h4><p>The last 24 hours. Now is on the right.</p>
    <small>db-01</small>${strip([[9, "ok"], [1, "down"], [38, "ok"]])}<small>web-02</small>${strip([[40, "ok"], [8, "slow"]])}
    <small>nas</small>${strip([[30, "ok"], [6, "slow"], [12, "ok"]])}<small>front-desk-pc</small>${strip([[10, "ok"], [28, "off"], [10, "ok"]])}</section>`;
  const svcHero = (c = "") => `<section class="a-hero t-down ${c}"><div class="a-hrow"><span class="a-hic">${svg("octagon")}</span><span class="a-tag">Down</span><span class="a-eye">db-01</span></div><h3>nightly-purge</h3><p class="fx">Expected at 01:00. Its last good run was yesterday at 01:04 and took 4 minutes.</p><p class="a-meta">job · production</p><p class="a-age">${svg("clock")}Snapshot made 40 seconds ago</p></section>`;
  const svcBtn = (c = "") => `<span class="a-softb ${c}">Open db-01 ${svg("arrow")}</span>`;
  const svcOpen = (c = "") => `<section class="a-card a-open ${c}"><div class="a-ch"><h4>Open issue</h4><small>DOK-3</small></div><div class="a-inner"><span class="a-tag">Down</span><h4>Nightly purge did not run</h4><p>Expected at 01:00. Its last good run was yesterday at 01:04 and took 4 minutes.</p><small>nightly-purge · db-01 · Open since 21 h</small></div></section>`;
  const tabbar = (c) => `<nav class="a-tabs ${c}"><span class="a-tlens"></span><span class="on">${svg("house")}Home</span><span>${svg("drives")}Servers</span><span>${svg("gear")}Settings</span></nav>`;

  // The phone screen: one status row, one page, one tab bar.
  const phone = () => `<div class="ph"><div class="ph-page"><div class="a-top">${title()}${tools()}</div>
    <div class="a-body">${hero()}${figs()}${segc()}${iss1()}${iss2()}${lastDay()}</div></div>${tabbar("ph-tabs")}</div>`;
  // The open Duo's screen: an upright board whose cards sit in two pages, or, turned, in one tall column.
  const board = () => `<div class="board"><i class="b-bg"></i>${sbar()}${title("b-tt")}${tools("b-tools")}
    ${hero("bc")}${figs("bc")}${segc("bc")}${iss1("bc sel")}${iss2("bc")}${svcHero("bc")}${svcBtn("bc")}${svcOpen("bc")}${tabbar("b-tabs")}</div>`;

  // ---------- the device ----------
  const build = () => {
    const el = document.createElement("div");
    el.className = "dv";
    const edges = '<i class="edge e-t"></i><i class="edge e-b"></i><i class="edge e-h"></i><i class="edge e-o"></i>';
    el.innerHTML = `<i class="dv-shadow"></i><i class="dv-contact"></i><div class="dv-rot">
      <div class="pf"><div class="face pf-front"><div class="scr scr-r"><div class="lay">${board()}</div><i class="crease crease-r"></i><i class="glare"></i></div><i class="shade cast"></i></div>
        <div class="face pf-back"></div>${edges}</div>
      <div class="pm"><div class="face pm-out"><div class="scr scr-c"><div class="app">${phone()}</div>${sbar()}<i class="cut"><i class="lens"></i></i><i class="off"></i><i class="glare"></i></div><i class="hinge-line"></i><i class="shade sh-o"></i><i class="sweep"></i></div>
        <div class="face pm-in"><div class="scr scr-l"><div class="lay">${board()}</div><i class="crease crease-l"></i><i class="glare"></i></div><i class="shade sh-i"></i><i class="sweep"></i></div>${edges}
        <i class="key k-l"></i><i class="key k-l"></i><i class="key k-l"></i><i class="key k-r"></i><i class="key k-r"></i></div>
    </div>`;
    el.querySelector(".scr-r .lay").style.left = `${-HALF}px`;
    const copies = [...el.querySelectorAll(".board")].map((b) => [...b.querySelectorAll(".bc")]);
    const buttons = [...el.querySelectorAll(".pm .key")];
    const bars = (sb) => [...sb.querySelectorAll(".sb-b i")];
    const sbs = [...el.querySelectorAll(".sb")].map((sb) => ({ sb, bars: bars(sb) }));
    // The cover's cluster sits on the screen; the others belong to the two copies of the open screen.
    return { el, copies, buttons, shadow: el.querySelector(".dv-shadow"), contact: el.querySelector(".dv-contact"), layout: null, cover: sbs.find((x) => x.sb.parentElement.classList.contains("scr")), open: sbs.filter((x) => x.sb.parentElement.classList.contains("board")) };
  };

  const mix = (a, b, t) => a + (b - a) * t;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const seg = (p, a, b) => ease(clamp((p - a) / (b - a)));
  const bump = (t) => Math.sin(Math.PI * t);

  // Each phone in points: screen size, corner radius on the hinge side and the far side, bezel, the camera cutout
  // (centre, size, radius), and the status row (left and right inset, top) and where the page starts.
  // Status pieces, each as a centre: time [x, y, size], Wi-Fi [x, y, size], ring [x, y, diameter, presence],
  // signal bars [x, y, bars-to-dots, presence], Android's signal [x, y, presence], battery [x, y, w, h, nub, presence].
  // Also where the page starts and how much of the top bar's right end stays clear. Measured from the simulators.
  // The frame: metal band width, its finish (highlight, mid, shade), side buttons as [top, length, presence] (three on
  // the left, two on the right), whether the camera shows a lens, and whether the hinge line shows.
  const A = { w: 360, h: 780, rh: 38, rf: 38, bz: 9, cut: [180, 24, 24, 24, 12], top: 44, tbr: 16, pad: 4,
    mb: 2.2, m1: [124, 120, 116], m2: [62, 59, 57], m3: [24, 22, 21], lens: 1, hz: 0,
    bl: [[150, 30, 0], [205, 60, 0], [280, 60, 0]], bb: [[190, 50, 1], [270, 90, 1]],
    tm: [46, 27, 15], wf: [284, 27, 16], rg: [284, 27, 20, 0], br: [303, 27, 0, 0], tr: [303, 27, 1], bt: [328, 27, 9, 15, 0, 1] };
  const I = { w: 393, h: 852, rh: 56, rf: 56, bz: 12, cut: [196.5, 29, 122, 36, 18], top: 54, tbr: 16, pad: 4,
    mb: 2.8, m1: [188, 181, 172], m2: [104, 99, 93], m3: [36, 33, 31], lens: 0, hz: 0,
    bl: [[160, 32, 1], [218, 62, 1], [292, 62, 1]], bb: [[245, 98, 1], [330, 90, 0]],
    tm: [72, 31, 17], wf: [312, 31, 17], rg: [312, 31, 20, 0], br: [284, 31, 0, 1], tr: [284, 31, 0], bt: [343, 31, 27, 13, 1, 1] };
  const F = { w: 463.5, h: 669, rh: 4, rf: 40, bz: 12, cut: [415.7, 47.8, 37, 37, 18.5], top: 58, tbr: 92, pad: 66,
    mb: 2.4, m1: [104, 99, 94], m2: [60, 56, 53], m3: [30, 28, 26], lens: 1, hz: 1,
    bl: [[160, 32, 0], [218, 62, 0], [292, 62, 0]], bb: [[150, 52, 1], [222, 72, 1]],
    tm: [415.7, 92.2, 16], wf: [415.7, 130.2, 18], rg: [415.7, 130.2, 41, 1], br: [415.7, 148, 1, 1], tr: [380, 31, 0], bt: [413.5, 31, 27, 13, 1, 0] };
  const lerp = (a, b, t) => {
    const o = {};
    const m = (x, y) => (Array.isArray(x) ? x.map((v, i) => m(v, y[i])) : mix(x, y, t));
    for (const k in a) o[k] = m(a[k], b[k]);
    return o;
  };

  const BARS = [4, 6, 8.5, 11];
  const DOTS = [[-9.87, 15.73], [-3.46, 18.68], [3.46, 18.68], [9.87, 15.73]];
  const setStatus = ({ sb, bars }, q) => {
    const v = (k, x) => sb.style.setProperty(k, x);
    v("--tx", q.tm[0]); v("--ty", q.tm[1]); v("--tf", q.tm[2]); v("--gr", q.grow ?? 1);
    v("--wx", q.wf[0]); v("--wy", q.wf[1]); v("--ws", q.wf[2]);
    v("--rx", q.rg[0]); v("--ry", q.rg[1]); v("--rd", q.rg[2]); v("--ro", q.rg[3]);
    v("--gx", q.tr[0]); v("--gy", q.tr[1]); v("--go", q.tr[2]);
    v("--ax", q.bt[0]); v("--ay", q.bt[1]); v("--aw", q.bt[2]); v("--ah", q.bt[3]); v("--an", q.bt[4]); v("--ao", q.bt[5]);
    // The iPhone's signal bars become the Duo's signal dots, which sit on an arc under the ring.
    const [cx, cy, k, o] = q.br, w = 3, gap = 1.6, total = 4 * w + 3 * gap, base = cy + 5.5;
    bars.forEach((b, i) => {
      const [dx, dy] = DOTS[i], h = mix(BARS[i], 4, k), st = b.style;
      st.width = `${mix(w, 4, k)}px`; st.height = `${h}px`; st.borderRadius = `${mix(1, 2, k)}px`;
      const x = mix(cx - total / 2 + i * (w + gap), q.rg[0] + dx - 2, k), y = mix(base - h, q.rg[1] + dy - 2, k);
      st.transform = `translate(${x}px, ${y}px)`;
    });
    v("--bo", o); v("--bk", k);
  };

  // Where each card of the open screen sits: two pages, or one tall column. Cards keep their height either way.
  const measure = (d) => {
    const cards = d.copies[0], hs = cards.map((c) => c.offsetHeight), gap = 14;
    const book = [], tall = [];
    let y = 128;
    for (let i = 0; i < 5; i++) { book[i] = [12, y, 445.5]; y += hs[i] + gap; }
    y = 128;
    for (let i = 5; i < cards.length; i++) { book[i] = [493.5, y, 445.5]; y += hs[i] + gap; }
    // Turned, the status row and the top bar sit higher up the tall screen, as on the Duo, so the column starts lower.
    y = 146;
    for (let i = 0; i < cards.length; i++) { tall[i] = [12, y, 645]; y += hs[i] + gap; }
    d.layout = { book, tall };
  };

  // q: shape, th: hinge angle (0 shut, 180 flat open), turn: 0 to 1 for a quarter turn, tilt and spin: 3D lean,
  // fixed: whether the back panel exists yet, box: where to fit it.
  const set = (d, q, box) => {
    const { s, th, turn, tilt, spin, fixed } = q;
    if (!d.layout) measure(d);
    const st = d.el.style, v = (k, x) => st.setProperty(k, x);
    const wp = s.w + 2 * s.bz, hp = s.h + 2 * s.bz;
    v("--wp", wp); v("--hp", hp); v("--bz", s.bz);
    v("--rh", s.rh + s.bz); v("--rf", s.rf + s.bz); v("--srh", s.rh); v("--srf", s.rf);
    const as = s.w / L;
    v("--as", as); v("--ah", s.h / as);
    v("--ct", s.top / as); v("--tbr", s.tbr / as); v("--pad", s.pad / as);
    const rgb = (c) => `rgb(${c.map(Math.round).join(",")})`;
    v("--mb", s.mb); v("--m1", rgb(s.m1)); v("--m2", rgb(s.m2)); v("--m3", rgb(s.m3)); v("--lens", s.lens); v("--hz", s.hz);
    [...s.bl, ...s.bb].forEach(([y, len, o], i) => {
      const b = d.buttons[i].style;
      b.top = `${y}px`; b.height = `${len}px`; b.setProperty("--o", o);
    });
    setStatus(d.cover, s);
    // The open screen's cluster: a column in the right page's corner, a row along the top when turned.
    const W = mix(SW, SH, turn);
    for (const o of d.open) setStatus(o, {
      tm: [W - mix(47.8, 99, turn), mix(39.5, 48.4, turn), 16], wf: [W - mix(47.8, 47.5, turn), mix(77.5, 49.1, turn), 18],
      rg: [W - mix(47.8, 47.5, turn), mix(77.5, 49.1, turn), 41, 1], br: [W - 48, mix(95, 68, turn), 1, 1], tr: [W - 48, 40, 0], bt: [W - 48, 40, 27, 13, 1, 0],
    });
    v("--tlx", 20); v("--tly", mix(45, 85, turn)); v("--tor", mix(93, 10, turn)); v("--toy", mix(40, 87, turn));
    const [cx, cy, cw, ch, cr] = s.cut;
    v("--cx", cx); v("--cy", cy); v("--cw", cw); v("--ch", ch); v("--cr", cr);
    v("--th", th); v("--vo", th < 90 ? "visible" : "hidden"); v("--vi", th < 90 ? "hidden" : "visible");
    v("--vf", fixed ? "visible" : "hidden");
    v("--sho", clamp(th / 90) * 0.6); v("--shi", clamp((180 - th) / 90) * 0.6);
    v("--cast", th > 0 && th < 180 ? Math.sin((th * Math.PI) / 180) * 0.5 : 0);
    v("--sweep", th / 180);
    v("--turn", turn); v("--tilt", tilt); v("--spin", spin);
    v("--bw", mix(SW, SH, turn)); v("--bh", mix(SH, SW, turn));
    v("--sel", 1 - turn); v("--crease", 1 - 0.6 * turn);
    // The right page's cards drop below the left page's first, then move across, and only then do the cards widen,
    // so no card ever passes over another.
    const { book, tall } = d.layout;
    const down = ease(clamp(turn / 0.55)), across = ease(clamp((turn - 0.45) / 0.55));
    for (const cards of d.copies) cards.forEach((c, i) => {
      c.style.left = `${mix(book[i][0], tall[i][0], across)}px`;
      c.style.top = `${mix(book[i][1], tall[i][1], down)}px`;
      c.style.width = `${mix(book[i][2], tall[i][2], across)}px`;
    });
    // Fit the visible footprint: the cover alone when shut, both panels when open, its rotated box when turning.
    const o = (1 - Math.cos((th * Math.PI) / 180)) / 2;
    const cxl = mix(wp / 2, 0, o);
    v("--cxl", cxl);
    const bw = mix(wp, 2 * PW, o), bh = mix(hp, PH, o), a = (turn * Math.PI) / 2;
    const FW = bw * Math.abs(Math.cos(a)) + bh * Math.abs(Math.sin(a)), FH = bw * Math.abs(Math.sin(a)) + bh * Math.abs(Math.cos(a));
    const k = Math.min(box.w / FW, box.h / FH) * 0.97;
    d.el.style.transform = `translate3d(${box.x - cxl * k}px, ${box.y}px, 0) scale3d(${k}, ${k}, ${k})`;
    const sh = d.shadow.style;
    sh.left = `${cxl - FW * 0.42}px`; sh.top = `${FH / 2 - 30}px`; sh.width = `${FW * 0.84}px`;
    const ct = d.contact.style;
    ct.left = `${cxl - FW * 0.36}px`; ct.top = `${FH / 2 - 8}px`; ct.width = `${FW * 0.72}px`;
  };

  // ---------- page ----------
  const stage = $("#seqStage"), flow = $("#flow"), slot = $("#seqSlot"), layer = $("#seqLayer");
  if (!stage || !flow || !slot || !layer) return;
  const dev = build();
  layer.append(dev.el);
  const avail = () => parseFloat(getComputedStyle(stage).getPropertyValue("--avail")) || flow.getBoundingClientRect().height;

  let G = null;
  const geo = () => {
    const f = flow.getBoundingClientRect(), s = slot.getBoundingClientRect();
    G = { fh: f.height, slot: { x: s.left - f.left + s.width / 2, y: s.top - f.top + s.height / 2, w: s.width, h: s.height }, mid: { x: f.width / 2, w: f.width * 0.96 } };
  };

  // The whole sequence as a function of scroll progress p, 0 to 1.
  const render = (p) => {
    if (!G) geo();
    const rise = seg(p, 0.17, 0.24) * (1 - seg(p, 0.96, 1));
    stage.style.setProperty("--nodes", 1 - rise);
    // The stage keeps the phone's own footprint, so the step flows on once the pin lets go. While pinned, the device
    // may use the screen below it, until the content after the stage rises into view near the end.
    const room = Math.max(G.fh, Math.min(avail(), G.fh + (1 - p) * innerHeight * 3 - 24));
    const box = { x: mix(G.slot.x, G.mid.x, rise), y: mix(G.slot.y, room / 2, rise), w: mix(G.slot.w, G.mid.w, rise), h: mix(G.slot.h, room * 0.94, rise) };
    const tAI = seg(p, 0.28, 0.35), tIF = seg(p, 0.39, 0.46);
    const s = tIF > 0 ? lerp(I, F, tIF) : lerp(A, I, tAI);
    // Into the Duo, the top bar's buttons step aside first and the time and Wi-Fi drop into the column after, so they
    // never pass over the buttons; out of it, the same in reverse.
    if (tIF > 0) {
      const raw = clamp((p - 0.39) / 0.07);
      s.tbr = mix(I.tbr, F.tbr, ease(clamp(raw / 0.45)));
      // The time and the Wi-Fi shrink away in the iPhone's ears and grow back in the Duo's corner column, so they
      // never travel across the top bar. Positions switch while they are too small to see.
      const out = ease(clamp(raw / 0.4)), back = ease(clamp((raw - 0.5) / 0.5)), there = raw >= 0.45;
      const at = (a, b, size) => [...(there ? b : a).slice(0, 2), ...(there ? b : a).slice(2, size)];
      s.tm = at(I.tm, F.tm, 3); s.wf = at(I.wf, F.wf, 3); s.rg = at(I.rg, F.rg, 4); s.br = at(I.br, F.br, 4);
      s.grow = there ? back : 1 - out;
    }
    const th = 180 * seg(p, 0.48, 0.6) * (1 - seg(p, 0.9, 0.97));
    set(dev, {
      s, th,
      turn: seg(p, 0.63, 0.71) * (1 - seg(p, 0.8, 0.88)),
      tilt: bump(seg(p, 0.63, 0.71)) + bump(seg(p, 0.8, 0.88)),
      spin: tIF > 0 ? bump(tIF) : bump(tAI),
      fixed: tIF >= 1,
    }, box);
  };

  const remeasure = () => { dev.layout = null; G = null; };

  // ---------- reduced motion: no pin, the stills in a row ----------
  if (still || !window.gsap || !window.ScrollTrigger) {
    document.documentElement.classList.add("seq-flat");
    dev.el.querySelector(".off").style.opacity = 0;
    const row = $("#seqRow");
    const stills = [
      ["Android", { s: A, th: 0, fixed: false }],
      ["iPhone", { s: I, th: 0, fixed: false }],
      ["iPhone Duo, folded", { s: F, th: 0, fixed: true }],
      ["iPhone Duo, open", { s: F, th: 180, fixed: true }],
      ["Open and turned", { s: F, th: 180, fixed: true, turn: 1 }],
    ].map(([label, q]) => {
      const f = document.createElement("figure");
      f.innerHTML = '<div class="seq-cell"></div><figcaption></figcaption>';
      f.querySelector("figcaption").textContent = label;
      const d = build();
      d.el.querySelector(".off").style.opacity = 0;
      f.firstChild.append(d.el);
      row.append(f);
      return { d, q: { turn: 0, tilt: 0, spin: 0, ...q }, cell: f.firstChild };
    });
    const all = () => {
      G = null; geo();
      set(dev, { s: A, th: 0, turn: 0, tilt: 0, spin: 0, fixed: false }, G.slot);
      stills.forEach(({ d, q, cell }) => { d.layout = null; set(d, q, { x: cell.clientWidth / 2, y: cell.clientHeight / 2, w: cell.clientWidth, h: cell.clientHeight }); });
    };
    all();
    addEventListener("resize", all);
    document.fonts?.ready.then(all);
    return;
  }

  // ---------- motion: the envelope story, then the device, pinned and scrubbed ----------
  gsap.registerPlugin(ScrollTrigger);
  document.documentElement.classList.add("pinned");
  const env = $("#env"), caps = $$("#pcap span"), off = dev.el.querySelector(".off");
  const at = (node, side) => {
    const f = flow.getBoundingClientRect(), r = $(node).getBoundingClientRect();
    const across = $("#nRelay").getBoundingClientRect().left > $("#nServer").getBoundingClientRect().right;
    let x = r.left + r.width / 2, y = r.top + r.height / 2;
    const gap = across ? 32 : 20;
    if (side === "out") across ? (x = r.right + gap) : (y = r.bottom + gap);
    if (side === "in") across ? (x = r.left - gap) : (y = r.top - gap);
    return { x: x - f.left - 22, y: y - f.top - 22 };
  };
  gsap.set(caps, { opacity: 0, y: 10 });
  gsap.set(off, { opacity: 1 });
  gsap.set(env, { opacity: 0 });
  gsap.set("#nRelay .blind", { opacity: 0, y: 6 });
  const tl = gsap.timeline({ paused: true });
  tl.to(caps[0], { opacity: 1, y: 0, duration: 0.3 })
    .to("#nServer", { borderColor: "#ff9a4d", duration: 0.3 }, "<")
    .fromTo(env, { x: () => at("#nServer", "out").x, y: () => at("#nServer", "out").y, opacity: 0 }, { opacity: 1, duration: 0.3 }, "<0.1")
    .to(env, { "--shut": 1, duration: 0.25 })
    .to({}, { duration: 0.35 })
    .to(caps[0], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[1], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to("#nServer", { borderColor: "", duration: 0.3 }, "<")
    .to(env, { x: () => at("#nRelay", "in").x, y: () => at("#nRelay", "in").y, duration: 0.45, ease: "power2.in" }, "<")
    .to("#nRelay", { borderColor: "#ff9a4d", duration: 0.3 })
    .to("#nRelay .blind", { opacity: 1, y: 0, duration: 0.3 }, "<")
    .to(env, { x: () => at("#nRelay", "out").x, y: () => at("#nRelay", "out").y, duration: 0.7, ease: "none" }, "<")
    .to({}, { duration: 0.2 })
    .to(caps[1], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[2], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to("#nRelay", { borderColor: "", duration: 0.3 }, "<")
    .to(env, { x: () => at("#seqSlot").x, y: () => at("#seqSlot").y, duration: 0.55, ease: "power2.inOut" }, "<")
    .to(env, { "--shut": 0, duration: 0.2 })
    .to(env, { opacity: 0, scale: 1.5, duration: 0.3 })
    .to(off, { opacity: 0, duration: 0.5 }, "<")
    .to(caps[2], { opacity: 0, duration: 0.3 });

  // The stage pins below the header (and the rail, on narrow screens).
  const top = () => {
    const bar = $(".nb")?.getBoundingClientRect().height || 64;
    const rail = $(".rail");
    const r = rail && getComputedStyle(rail).position === "sticky" && innerWidth <= 1000 ? rail.getBoundingClientRect().height : 0;
    return Math.round(bar + r + 8);
  };
  const size = () => {
    const cap = $("#pcap").getBoundingClientRect().height + 20;
    const av = Math.max(380, innerHeight - top() - cap - 16);
    stage.style.setProperty("--avail", `${av}px`);
    stage.style.removeProperty("--slotH");
    if (getComputedStyle(flow).gridTemplateColumns.split(" ").length === 1) {
      const above = slot.getBoundingClientRect().top - flow.getBoundingClientRect().top;
      stage.style.setProperty("--slotH", `${Math.max(180, av - above - 12)}px`);
    }
    G = null;
  };
  size();
  let last = 0;
  const draw = (p) => { last = p; tl.progress(clamp(p / 0.17)); render(p); };
  ScrollTrigger.create({
    trigger: stage, pin: true, start: () => `top ${top()}px`, end: () => `+=${innerHeight * 3}`,
    invalidateOnRefresh: true,
    onRefreshInit: size,
    onRefresh: () => { geo(); draw(last); },
    onUpdate: (self) => draw(self.progress),
  });
  addEventListener("resize", () => { size(); ScrollTrigger.refresh(); });
  document.fonts?.ready.then(() => { remeasure(); ScrollTrigger.refresh(); });
  draw(0);
})();

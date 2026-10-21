// The live phone in "How it reaches you": the app on an Android phone, an iPhone, or the iPhone Duo folded or open.
(() => {
  const host = $("#handset"), flow = $("#flow"), node = $("#nPhone");
  if (!host) return;
  const CAP = { android: [250, 480], iphone: [250, 480], folded: [300, 460], open: [860, 560], tall: [420, 560] };
  let name = "android";
  const room = () => {
    const cs = getComputedStyle(node), avail = node.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    const [w, h] = CAP[name];
    return { w: Math.min(avail, w), h };
  };
  const dev = makeDevice(host, { src: "phone-demo.html?theme=dark&device=android" + (still ? "&still=1" : ""), fit: room });
  dev.screen.querySelector(".screen-off").id = "screenOff";
  let cur = deviceParams(name);
  dev.apply(cur, "android");

  let tween = null;
  function show(next) {
    if (next === name) return;
    const from = cur, to = deviceParams(next), before = host.getBoundingClientRect();
    name = next;
    flow.classList.toggle("wide", next === "open");
    if (still || !window.gsap) { cur = to; dev.apply(cur, DEVICE_OF[next]); return; }
    // The device keeps its place while the layout around it changes, then moves and reshapes in one go.
    dev.apply(from, DEVICE_OF[next]);
    const after = host.getBoundingClientRect();
    const dx = before.left - after.left, dy = before.top - after.top, p = { t: 0 };
    tween?.kill();
    gsap.set(host, { x: dx, y: dy });
    tween = gsap.to(p, {
      t: 1, duration: 0.75, ease: "power3.inOut",
      onUpdate: () => { cur = mixParams(from, to, p.t); dev.apply(cur); gsap.set(host, { x: dx * (1 - p.t), y: dy * (1 - p.t) }); },
      onComplete: () => { gsap.set(host, { x: 0, y: 0 }); window.ScrollTrigger?.refresh(); },
    });
  }

  const picks = $$("[data-dv]"), folds = $$("[data-fold]"), foldRow = $(".dv-pick .fold");
  const press = (list, el) => list.forEach((b) => b.setAttribute("aria-pressed", String(b === el)));
  picks.forEach((b) => b.addEventListener("click", () => {
    press(picks, b);
    foldRow.hidden = b.dataset.dv !== "duo";
    if (b.dataset.dv !== "duo") return show(b.dataset.dv);
    press(folds, folds[0]);
    show("folded");
  }));
  folds.forEach((b) => b.addEventListener("click", () => { press(folds, b); show(b.dataset.fold); }));
  addEventListener("resize", () => dev.apply(cur));
})();

// What every page shares: the motion switch, copy buttons, and facts highlighted as they are read.
const $ = (q, r = document) => r.querySelector(q), $$ = (q, r = document) => [...r.querySelectorAll(q)];
const still = document.documentElement.classList.contains("still");
document.documentElement.classList.add("js");

$("#motion").setAttribute("aria-pressed", !still);
$("#motion b").textContent = still ? "off" : "on";
$("#motion").addEventListener("click", () => { try { localStorage.setItem("motion", still ? "on" : "off"); } catch {} location.reload(); });

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-copy]");
  if (!t) return;
  const el = $("#" + t.dataset.copy), was = t.textContent;
  const done = (word) => { t.textContent = word; setTimeout(() => (t.textContent = was), 1400); };
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(el.textContent).then(() => done("Copied"), () => done("Select it"));
  else { getSelection().selectAllChildren(el); done("Selected"); }
});

$$("main mark").forEach((m) => m.classList.add("pend"));
$$(".tr:not(.th), .wcard").forEach((r, i) => { r.classList.add("pend"); r.style.setProperty("--d", i * 120 + "ms"); });
const seen = new IntersectionObserver((es) => es.forEach((e) => {
  if (!e.isIntersecting) return;
  const el = e.target;
  seen.unobserve(el);
  if (el.matches("mark")) {
    const sibs = $$("mark", el.closest("p, .tr, span, li") || el.parentElement);
    el.style.setProperty("--d", Math.max(0, sibs.indexOf(el)) * 220 + "ms");
  }
  el.classList.replace("pend", "lit");
}), { rootMargin: "0px 0px -12% 0px" });
$$(".pend").forEach((el) => seen.observe(el));
document.addEventListener("toggle", () => window.ScrollTrigger?.refresh(), true);

function splitLetters(el) {
  if (/^H\d$/.test(el.tagName)) el.setAttribute("aria-label", el.textContent.replace(/\s+/g, " ").trim());
  const out = [];
  const walk = (node) => [...node.childNodes].forEach((n) => {
    if (n.nodeType === 1) return walk(n);
    const frag = document.createDocumentFragment();
    [...n.textContent].forEach((ch) => {
      const s = document.createElement("span");
      s.className = "ch";
      s.textContent = ch;
      out.push(s);
      frag.append(s);
    });
    n.replaceWith(frag);
  });
  walk(el);
  el.classList.add("typing");
  return out;
}
function showLetters(chars, p) {
  const n = Math.round(p * chars.length);
  chars.forEach((c, i) => { c.classList.toggle("on", i < n); c.classList.toggle("cur", i === n - 1 && n < chars.length); });
  chars[0]?.classList.toggle("pre", n === 0);
}

function typeIn(tl, el, duration, at) {
  const chars = splitLetters(el), p = { v: 0 };
  showLetters(chars, 0);
  tl.to(p, { v: 1, duration, ease: "none", onUpdate: () => showLetters(chars, p.v) }, at);
}

// Plays the timeline once, the first time its section reaches the top going down, with the scroll held until it ends.
function holdFor(section, tl, start) {
  ScrollTrigger.create({
    trigger: section, start, once: true,
    onEnter: () => {
      const lenis = window.dokkitScroll;
      lenis?.scrollTo(section, { immediate: true, force: true, offset: start === "top top" ? 0 : -innerHeight * 0.12 });
      lenis?.stop();
      document.documentElement.classList.add("held");
      tl.eventCallback("onComplete", () => { lenis?.start(); document.documentElement.classList.remove("held"); });
      tl.play();
    },
  });
}


// A rail beside a page's sections marks the one being read and fills as you go.
function railFor(sections, links) {
  const fill = $("#railFill");
  const where = () => {
    const mid = innerHeight * 0.4;
    let current = sections[0];
    sections.forEach((s) => { if (s.getBoundingClientRect().top < mid) current = s; });
    links.forEach((a) => a.toggleAttribute("aria-current", a.dataset.step === current.id));
    const first = sections[0].getBoundingClientRect().top, last = sections[sections.length - 1].getBoundingClientRect().bottom;
    if (fill) fill.style.transform = `scaleY(${Math.min(1, Math.max(0, (mid - first) / (last - first)))})`;
  };
  addEventListener("scroll", where, { passive: true });
  where();
}

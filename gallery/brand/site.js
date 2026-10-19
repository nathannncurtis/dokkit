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
}

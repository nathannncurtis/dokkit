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
$$(".tr:not(.th)").forEach((r, i) => { r.classList.add("pend"); r.style.setProperty("--d", i * 120 + "ms"); });
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

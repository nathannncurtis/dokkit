// The three issues reach their channels in turn, once, while the page waits.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  const rows = $$("[data-route]");
  rows.forEach((r) => r.classList.add("wait"));
  const tl = gsap.timeline({ paused: true });
  rows.forEach((r, i) => tl.call(() => r.classList.remove("wait"), null, 0.3 + i * 1.1));
  tl.to({}, { duration: 0.6 }, ">");
  holdFor("#routes", tl, "top 12%");
}

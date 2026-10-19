// Scroll-led motion for the home page. Without it, or with reduced motion, the page is complete and still.
(() => {
  if (document.documentElement.classList.contains("still") || !window.gsap || !window.ScrollTrigger || !window.Lenis) return;
  gsap.registerPlugin(ScrollTrigger);
  const $$ = (q, r = document) => [...r.querySelectorAll(q)];
  const phone = matchMedia("(max-width: 640px)").matches;

  const lenis = new Lenis({ lerp: 0.09 });
  lenis.on("scroll", ScrollTrigger.update);
  gsap.ticker.add((t) => lenis.raf(t * 1000));
  gsap.ticker.lagSmoothing(0);
  document.documentElement.style.scrollBehavior = "auto";
  document.addEventListener("click", (e) => {
    const a = e.target.closest('a[href^="#"]');
    if (!a || a.getAttribute("href").length < 2) return;
    e.preventDefault();
    lenis.scrollTo(a.getAttribute("href"), { offset: -72, duration: 1.3 });
  });

  // Typed by the scroll: each letter appears as you read down, and goes again as you scroll back.
  function letters(el) {
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
    return out;
  }
  $$(".watches h2, .door h3, .label").forEach((el) => {
    const chars = letters(el);
    el.classList.add("typing");
    let shown = -1;
    ScrollTrigger.create({
      trigger: el, start: "top 92%", end: el.matches("h2") ? "clamp(top 40%)" : "clamp(top 62%)", scrub: true,
      onUpdate: ({ progress }) => {
        const n = Math.round(progress * chars.length);
        if (n === shown) return;
        chars.forEach((c, i) => c.classList.toggle("on", i < n));
        chars[shown - 1]?.classList.remove("cur");
        chars[n - 1]?.classList.toggle("cur", n < chars.length);
        shown = n;
      },
    });
  });

  // Flown in from one side, held while it is read, and let go on the way out.
  function fly(el, from, out, opts = {}) {
    const tl = gsap.timeline({ scrollTrigger: { trigger: el, start: opts.start || "top 100%", end: opts.end || "bottom 0%", scrub: 0.7 } });
    tl.fromTo(el, from, { x: 0, y: 0, rotate: 0, scale: 1, rotateX: 0, opacity: 1, duration: 1, ease: "power3.out" })
      .to(el, { duration: opts.hold || 1.4 })
      .to(el, { ...out, duration: 0.8, ease: "power2.in" });
  }
  const side = phone ? 40 : 140;
  fly(document.querySelector(".cmd"), { x: -side, opacity: 0 }, { y: -30, opacity: 0.2 });
  gsap.set(".frame", { transformPerspective: 1600, transformOrigin: "50% 0%" });
  fly(document.querySelector(".frame"), { y: 140, rotateX: phone ? 0 : 16, scale: 0.9, opacity: 0.3 }, { scale: 0.95, opacity: 0.35, y: -40 }, { hold: 2.6 });
  $$(".tr:not(.th)").forEach((row, i) => fly(row, { x: (i % 2 ? -1 : 1) * side, opacity: 0 }, { x: (i % 2 ? 1 : -1) * side * 0.4, opacity: 0 }, { hold: 1.6 }));
  fly(document.querySelector(".foot"), { x: -side, opacity: 0 }, { opacity: 0.2 });
  $$(".door").forEach((door) => {
    fly(door.querySelector("p"), { y: 70, opacity: 0 }, { y: -30, opacity: 0.15 });
    $$("li", door).forEach((li, i) => fly(li, { x: side * 0.6 + i * 30, opacity: 0 }, { x: -side * 0.3, opacity: 0 }, { hold: 1.8 }));
  });
  fly(document.querySelector(".fl"), { y: 40, opacity: 0 }, { opacity: 1 }, { end: "bottom 100%", hold: 0.01 });

  addEventListener("load", () => ScrollTrigger.refresh());
})();
